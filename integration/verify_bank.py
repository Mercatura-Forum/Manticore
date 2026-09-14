#!/usr/bin/env python3
"""verify_bank.py; verify a bank-log entry without trusting the canister.

The same five-step check `verify_entry.py` performs on a journal entry, applied
to the bank log and its own subtree of the combined certified tree:

  1. the certificate's BLS signature against the network root key, through the
     subnet delegation (reused from verify_entry);
  2. the canister's `certified_data` equals the hash of the returned hash tree;
  3. the tree contains the bank's MMR root under `thebes_bank/mmr_root` and the
     journal's under `thebes_journal/mmr_root`; one certificate, both logs;
  4. the block's own stored bytes hash to the hash it carries, decoded by this
     file's own reader with its own SHA-256 calls;
  5. the inclusion proof bags its peaks to the certified root.

Nothing here imports the canister's code. It shares the certificate, hash-tree
and MMR primitives with the journal's verifier, which is itself independent of
the canister, and adds a decoder for the bank's own event vocabulary.
"""
import hashlib

import verify_entry as V

BLOCK_DOMAIN = b"THEBES-BANK-BLOCK-v2"
COMMAND_DOMAIN = b"THEBES-BANK-COMMAND-v1"
# The command encodings this verifier implements (the review of 12 September: frozen per version). A block
# whose recorded `commandEncoding` is not here is refused, never hashed under a version of ours.
SUPPORTED_COMMAND_ENCODINGS = (1, 2)
CURRENT_COMMAND_ENCODING = 2


def command_domain(version):
    return b"THEBES-BANK-COMMAND-v%d" % version
# block format 2 (block format 2): a proposal's body is the block's trailer
SUPPORTED_BLOCK_VERSIONS = (0x02,)

LABEL_BANK = b"thebes_bank"
LABEL_JOURNAL = b"thebes_journal"

ACTIONS = ["create", "read", "update", "delete", "approve", "reject", "activate",
           "close", "reverse", "waive", "release", "breakGlass"]
REFUSALS = ["noGrant", "outsideBook", "outsideCurrency", "overCeiling", "overDailyLimit",
            "notEligibleChecker", "selfApproval", "commandHashMismatch", "proposalExpired",
            "featureInactive", "bookClosed", "noWitness", "notAdmin"]
CATEGORIES = ["asset", "liability", "equity", "income", "expense"]
CONSTRAINTS = ["none", "debitsNotExceedCredits", "creditsNotExceedDebits"]
SHIFT_POLICIES = ["reject", "previous", "next", "nearest"]


def _domain_hash(domain, payload):
    h = hashlib.sha256()
    h.update(len(domain).to_bytes(2, "big"))
    h.update(domain)
    h.update(payload)
    return h.digest()


def block_hash(preimage):
    return _domain_hash(BLOCK_DOMAIN, preimage)


class Reader(V.Reader):
    """The journal verifier's reader plus the bank's own shapes."""

    def opt_texts(self):
        t = self.byte()
        if t == 0:
            return None
        assert t == 1, "bad option tag for a text list"
        return [self.text() for _ in range(self.len16())]

    def opt_money(self):
        t = self.byte()
        if t == 0:
            return None
        assert t == 1, "bad option tag for a money list"
        return [{"currency": self.text(), "amount": self.nat()} for _ in range(self.len16())]

    def scope(self):
        return {"books": self.opt_texts(), "currencies": self.opt_texts(),
                "ceiling": self.opt_money(), "dailyLimit": self.opt_money()}

    def policy(self):
        return {"permission": self.text(), "required": self.nat(),
                "eligibleRole": self.text(), "ttlSeconds": self.nat()}

    def texts(self):
        return [self.text() for _ in range(self.len16())]

    def nats(self):
        return [self.nat() for _ in range(self.len16())]

    def legs(self):
        return [self.leg() for _ in range(self.len16())]

    def category(self):
        return CATEGORIES[self.byte()]

    def constraint(self):
        return CONSTRAINTS[self.byte()]

    def bank_calendar(self):
        t = self.byte()
        if t == 0:
            return None
        assert t == 1
        rest = [self.nat() for _ in range(self.len16())]
        hol = [self.nat() for _ in range(self.len16())]
        return {"restDays": rest, "holidays": hol, "policy": SHIFT_POLICIES[self.byte()]}

    def manual_entry(self):
        return {"book": self.text(), "postingDate": self.nat(), "valueDate": self.nat(),
                "period": self.text(), "legs": self.legs(), "narration": self.text(),
                "idempotencyKey": self.blob(), "correctionOf": self.opt(self.nat)}


    # ── party and KYC party shapes ──
    PARTY_KINDS = ["natural", "legal"]
    LIFECYCLES = ["prospect", "pendingKyc", "active", "dormant", "blocked", "closed"]
    CDD = ["simplified", "standard", "enhanced"]
    RISK = ["low", "medium", "high"]
    RELATION = ["guarantor", "authorisedSignatory", "beneficialOwner", "director",
                "spouse", "parent", "child", "groupMember"]
    ASSURANCE = ["aal1", "aal2", "aal3"]

    def int_(self):
        sign = self.byte()
        assert sign in (0, 1), "bad sign byte"
        mag = self.nat()
        if sign == 1:
            assert mag != 0, "negative zero is not an encoding"
            return -mag
        return mag

    def party_kind(self):
        return self.PARTY_KINDS[self.byte()]

    def lifecycle(self):
        return self.LIFECYCLES[self.byte()]

    def cdd(self):
        return self.CDD[self.byte()]

    def risk(self):
        return self.RISK[self.byte()]

    def field_commits(self):
        return [{"name": self.text(), "commit": self.blob()} for _ in range(self.len16())]

    def opt_commit(self):
        return self.opt(self.blob)

    def document(self):
        return {"kind": self.text(), "commit": self.blob(), "issued": self.nat(),
                "expires": self.opt(self.nat)}

    def relation_kind(self):
        t = self.byte()
        if t == 8:
            return {"other": self.text()}
        return self.RELATION[t]

    def relationship(self):
        return {"kind": self.relation_kind(), "other": self.nat()}

    def field_type(self):
        t = self.byte()
        if t == 0:
            return {"text": {"maxBytes": self.nat()}}
        if t == 1:
            return {"integer": {"min": self.int_(), "max": self.int_()}}
        if t == 2:
            return "date"
        if t == 3:
            return {"enumerated": [self.text() for _ in range(self.len16())]}
        if t == 4:
            return "boolean"
        if t == 5:
            return "commitment"
        raise ValueError("unknown field type %d" % t)

    def field_value(self):
        t = self.byte()
        if t == 0:
            return {"text": self.text()}
        if t == 1:
            return {"integer": self.int_()}
        if t == 2:
            return {"date": self.nat()}
        if t == 3:
            return {"enumerated": self.text()}
        if t == 4:
            return {"boolean": self.byte() == 1}
        if t == 5:
            return {"commitment": self.blob()}
        raise ValueError("unknown field value %d" % t)

    def entity_kind(self):
        return ["party", "collateral"][self.byte()]

    def field_defs(self):
        return [{"name": self.text(), "fieldType": self.field_type(), "required": self.byte() == 1}
                for _ in range(self.len16())]

    def extension_values(self):
        return [{"schema": self.text(), "name": self.text(), "value": self.field_value()}
                for _ in range(self.len16())]

    def collateral_kind(self):
        t = self.byte()
        if t == 4:
            return {"tokenisedTitle": {"registry": self.principal(), "tokenId": self.nat()}}
        if t == 5:
            return {"other": self.text()}
        return ["cashDeposit", "property", "vehicle", "securities"][t]

    def valuation(self):
        return {"amount": self.nat(), "currency": self.text(), "asOf": self.nat(),
                "source": self.text(), "haircut": self.nat()}

    def adjacency_side(self):
        present = self.byte()
        if present == 0:
            return None
        assert present == 1, "bad adjacency option tag"
        return {"entry": self.blob(), "index": self.nat(),
                "path": [self.blob() for _ in range(self.len16())]}

    def adjacency(self):
        return {"lower": self.adjacency_side(), "upper": self.adjacency_side()}

    def screening_decision(self):
        party = self.nat()
        version = self.text()
        root = self.blob()
        t = self.byte()
        if t == 0:
            decision = "clear"
        elif t == 1:
            decision = {"hit": {"matches": self.nat()}}
        elif t == 2:
            decision = {"cleared": {"reason": self.text()}}
        elif t == 3:
            decision = "confirmed"
        else:
            raise ValueError("unknown screening decision %d" % t)
        return {"party": party, "listVersion": version, "listRoot": root, "decision": decision,
                "screener": self.principal(), "justificationCommit": self.blob()}

    def iban_format(self):
        return {"country": self.text(), "bank": self.text(), "branch": self.text(),
                "serialWidth": self.nat(), "prefix": self.text()}

    def jwks(self):
        issuer = self.text()
        keys = [{"kid": self.text(), "n": self.blob(), "e": self.blob()} for _ in range(self.len16())]
        return {"issuer": issuer, "keys": keys, "pinnedAtBlock": self.nat()}

    def credential(self):
        subject = self.principal()
        t = self.byte()
        if t == 0:
            kind = {"passkey": {"aaguid": self.blob()}}
        elif t == 1:
            kind = {"oidc": {"issuer": self.text(), "subjectCommit": self.blob()}}
        else:
            raise ValueError("unknown credential kind %d" % t)
        return {"subject": subject, "kind": kind, "assurance": self.ASSURANCE[self.byte()],
                "registeredAtBlock": self.nat(), "revokedAtBlock": self.opt(self.nat)}

    def party_event(self):
        t = self.byte()
        if t == 0x01:
            return {"partyCreated": {
                "kind": self.party_kind(), "salt": self.blob(), "identityCommit": self.blob(),
                "dedupCommit": self.opt_commit(), "attributes": self.field_commits(),
                "book": self.text(), "cddLevel": self.cdd(), "riskRating": self.risk(),
                "pep": self.byte() == 1, "reviewDue": self.nat()}}
        if t == 0x02:
            return {"partyAmended": {"party": self.nat(), "attributes": self.field_commits()}}
        if t == 0x03:
            return {"partyLifecycleSet": {"party": self.nat(), "to": self.lifecycle()}}
        if t == 0x04:
            return {"partyCddSet": {"party": self.nat(), "level": self.cdd(), "riskRating": self.risk(),
                                    "pep": self.byte() == 1, "reviewDue": self.nat()}}
        if t == 0x05:
            return {"partyDocumentAdded": {"party": self.nat(), "document": self.document()}}
        if t == 0x06:
            return {"partyRelationshipAdded": {"party": self.nat(), "relationship": self.relationship()}}
        if t == 0x07:
            return {"partyExtensionSet": {"party": self.nat(), "values": self.extension_values()}}
        if t == 0x08:
            return {"partyIdentifierIssued": {"party": self.nat(), "identifier": self.text()}}
        if t == 0x09:
            return {"screeningListCommitted": {"version": self.text(), "root": self.blob(),
                                               "count": self.nat(), "normalisation": self.text()}}
        if t == 0x0A:
            return {"screeningProven": {"party": self.nat(), "listVersion": self.text()}}
        if t == 0x0B:
            return {"screeningDecisionRecorded": self.screening_decision()}
        if t == 0x0C:
            return {"schemaRegistered": {"id": self.text(), "entity": self.entity_kind(),
                                         "fields": self.field_defs()}}
        if t == 0x0D:
            return {"collateralRegistered": {"party": self.nat(), "kind": self.collateral_kind(),
                                             "valuation": self.valuation(), "descriptionCommit": self.blob()}}
        if t == 0x0E:
            return {"collateralRevalued": {"collateral": self.nat(), "valuation": self.valuation()}}
        if t == 0x0F:
            return {"collateralAllocated": {"collateral": self.nat(), "facility": self.text(), "amount": self.nat()}}
        if t == 0x10:
            return {"collateralReleased": {"collateral": self.nat()}}
        if t == 0x11:
            return {"staffAdded": {"principal_": self.principal(), "book": self.text(), "title": self.text()}}
        if t == 0x12:
            return {"staffRemoved": {"principal_": self.principal()}}
        if t == 0x13:
            return {"accountFormatSet": self.iban_format()}
        if t == 0x14:
            return {"jwksPinned": self.jwks()}
        if t == 0x15:
            return {"credentialRegistered": self.credential()}
        if t == 0x16:
            return {"credentialRevoked": {"subject": self.principal()}}
        if t == 0x17:
            return {"reviewGraceSet": {"days": self.nat()}}
        raise ValueError("unknown party event tag %#x" % t)


    # ── the product engine product shapes ──
    PRODUCT_KINDS = {0x01: "currentAccount", 0x02: "savings", 0x03: "termDeposit",
                     0x04: "recurringDeposit", 0x05: "loan", 0x06: "shareAccount", 0x07: "till"}
    ROLES = {0x01: "principal", 0x02: "interestPayable", 0x03: "interestExpense",
             0x04: "interestReceivable", 0x05: "interestIncome", 0x06: "feeIncome",
             0x07: "penaltyIncome", 0x08: "feeReceivable", 0x09: "penaltyReceivable",
             0x0A: "taxPayable", 0x0B: "overdraftPortfolio", 0x0C: "writeOff",
             0x0D: "recovery", 0x0E: "allowance", 0x0F: "impairmentExpense",
             0x10: "suspense", 0x11: "cash", 0x12: "modificationAdjustment",
             0x13: "dueToParticipants", 0x14: "participantPayable", 0x15: "rentReceivable", 0x16: "rentalIncome",
             0x17: "purchasedReceivables", 0x18: "retentionPayable", 0x19: "unearnedDiscount", 0x1A: "discountIncome"}
    PERIODS = ["daily", "monthly", "quarterly", "semiAnnual", "annual", "atMaturity"]
    ROUNDING = ["halfEven", "halfUp", "down"]
    BASIS = ["dailyBalance", "averageDailyBalance"]
    ACCOUNT_STATUS = ["pending", "active", "dormant", "closed"]
    COMPONENTS = ["penalty", "fee", "interest", "principal"]
    # the day-count conventions of the product engine, by the encoder's byte (the value-date conventions of the close are
    # `VALUE_DATE_CONVENTIONS` below; the two tables carried one name until treasury, and the product decoder read the wrong one)
    DAY_COUNTS = {0x01: "A001", 0x03: "A003", 0x04: "A004", 0x05: "A005",
                  0x06: "A006", 0x07: "A007", 0x0B: "A011"}

    def p_rate(self):
        return {"numerator": self.nat(), "denominator": self.nat(), "negative": self.byte() == 1}

    def p_rounding(self):
        return self.ROUNDING[self.byte()]

    def p_convention(self):
        t = self.byte()
        code = self.DAY_COUNTS[t]
        if t == 0x01:
            return {"code": code, "couponsPerYear": self.nat()}
        return {"code": code}

    def p_period(self):
        return self.PERIODS[self.byte()]

    def p_role(self):
        return self.ROLES[self.byte()]

    def p_kind(self):
        return self.PRODUCT_KINDS[self.byte()]

    def p_component(self):
        return self.COMPONENTS[self.byte()]

    def p_components(self):
        return [self.p_component() for _ in range(self.len16())]

    def p_allocation(self):
        return {"penalty": self.nat(), "fee": self.nat(), "interest": self.nat(), "principal": self.nat()}

    def p_status(self):
        return self.ACCOUNT_STATUS[self.byte()]

    def p_difference(self):
        t = self.byte()
        if t == 0:
            return "balanced"
        if t == 1:
            return {"over": self.nat()}
        if t == 2:
            return {"short": self.nat()}
        raise ValueError("bad till difference tag %d" % t)

    def p_funding(self):
        t = self.byte()
        if t == 0:
            return {"till": self.text()}
        if t == 1:
            return {"glAccount": self.text()}
        raise ValueError("bad funding tag %d" % t)

    def p_charge_base(self):
        return {"amount": self.opt(self.nat), "interest": self.opt(self.nat),
                "outstanding": self.opt(self.nat)}

    def p_chart(self):
        bands = [{"from": self.nat(), "to": self.opt(self.nat), "rate": self.p_rate()}
                 for _ in range(self.len16())]
        by = ["balance", "termDays"][self.byte()]
        return {"bands": bands, "by": by}

    def p_interest(self):
        return {"chart": self.p_chart(), "convention": self.p_convention(),
                "basis": self.BASIS[self.byte()], "compounding": self.p_period(),
                "compoundingAlignment": ["anniversary", "calendar"][self.byte()],
                "posting": self.p_period(), "minimumBalance": self.nat(),
                "allowNegative": self.byte() == 1}

    def p_calculation(self):
        t = self.byte()
        if t == 0:
            return {"flat": {"amount": self.nat()}}
        if t == 1:
            return {"percentOfAmount": {"rate": self.p_rate()}}
        if t == 2:
            return {"percentOfInterest": {"rate": self.p_rate()}}
        if t == 3:
            return {"percentOfPrincipalOutstanding": {"rate": self.p_rate()}}
        raise ValueError("bad charge calculation tag %d" % t)

    def p_timing(self):
        t = self.byte()
        if t == 0:
            return "onActivation"
        if t == 1:
            return "onTransaction"
        if t == 2:
            return {"onDate": {"day": self.nat()}}
        if t == 3:
            return {"recurring": {"every": self.p_period()}}
        if t == 4:
            return {"overdue": {"afterDays": self.nat()}}
        if t == 5:
            return "onClosure"
        raise ValueError("bad charge timing tag %d" % t)

    def p_charges(self):
        return [{"id": self.text(), "calculation": self.p_calculation(), "timing": self.p_timing(),
                 "currency": self.text(), "role": self.p_role(), "waivable": self.byte() == 1}
                for _ in range(self.len16())]

    def p_amortisation(self):
        t = self.byte()
        if t == 0:
            return "equalInstalments"
        if t == 1:
            return "equalPrincipal"
        if t == 2:
            return "flat"
        if t == 3:
            return {"balloon": {"finalPrincipal": self.nat()}}
        raise ValueError("bad amortisation tag %d" % t)

    def p_schedule_terms(self):
        return {"amortisation": self.p_amortisation(), "instalments": self.nat(),
                "every": self.p_period(), "principalGrace": self.nat(),
                "interestGrace": self.nat(), "moratoriumDays": self.nat()}

    def p_instalments(self):
        return [{"number": self.nat(), "dueDate": self.nat(), "openingPrincipal": self.nat(),
                 "principal": self.nat(), "interest": self.nat(), "fees": self.nat(),
                 "closingPrincipal": self.nat()} for _ in range(self.len16())]

    def p_terms(self):
        kind = self.p_kind()
        currency = self.text()
        control = self.text()
        roles = [{"role": self.p_role(), "account": self.text()} for _ in range(self.len16())]
        interest = self.opt(self.p_interest)
        charges = self.p_charges()
        limits = {"overdraft": self.opt(self.nat), "minimumOperating": self.nat(),
                  "perOperation": self.opt(self.nat)}
        schedule = self.opt(self.p_schedule_terms)
        delinquency = [{"name": self.text(), "fromDays": self.nat(), "toDays": self.opt(self.nat)}
                       for _ in range(self.len16())]
        provisioning = [{"band": self.text(), "stage": self.nat(), "percentOfOutstanding": self.p_rate()}
                        for _ in range(self.len16())]
        accounting = ["cash", "accrualPeriodic"][self.byte()]
        withholdingTax = self.opt(self.p_rate)
        rounding = self.p_rounding()
        earlyRedemptionPenalty = self.opt(self.p_rate)
        valueDateConvention = self.c_convention()
        return {"kind": kind, "currency": currency, "control": control, "roles": roles,
                "interest": interest, "charges": charges, "limits": limits, "schedule": schedule,
                "delinquency": delinquency, "provisioning": provisioning, "accounting": accounting,
                "withholdingTax": withholdingTax, "rounding": rounding,
                "earlyRedemptionPenalty": earlyRedemptionPenalty,
                "valueDateConvention": valueDateConvention}

    def p_money_move(self):
        return {"account": self.nat(), "amount": self.nat(), "postingDate": self.nat(),
                "valueDate": self.nat(), "period": self.text(), "narration": self.text(),
                "funding": self.p_funding()}

    def product_event(self):
        t = self.byte()
        if t == 0x01:
            return {"productRegistered": {"id": self.text(), "version": self.nat(),
                                          "name": self.text(), "terms": self.p_terms()}}
        if t == 0x02:
            return {"productAmended": {"id": self.text(), "version": self.nat(),
                                       "supersedes": self.nat(), "name": self.text(),
                                       "terms": self.p_terms()}}
        if t == 0x03:
            return {"productClosedToNewAccounts": {"id": self.text(), "version": self.nat()}}
        if t == 0x04:
            return {"accountOpened": {
                "product": self.text(), "version": self.nat(), "party": self.nat(),
                "book": self.text(), "identifier": self.text(), "currency": self.text(),
                "opened": self.nat(), "maturity": self.opt(self.nat),
                "openingRate": self.opt(self.p_rate), "allocationOrder": self.p_components()}}
        if t == 0x05:
            return {"accountStatusSet": {"account": self.nat(), "to": self.p_status()}}
        if t == 0x06:
            return {"accountMigrated": {"account": self.nat(), "from": self.nat(), "to": self.nat()}}
        if t == 0x07:
            return {"facilityGranted": {"account": self.nat(), "limit": self.nat()}}
        if t == 0x08:
            return {"chargeApplied": {"account": self.nat(), "charge": self.text(),
                                      "amount": self.nat(), "day": self.nat()}}
        if t == 0x09:
            return {"chargeWaived": {"account": self.nat(), "charge": self.text(),
                                     "occurrence": self.nat(), "reversalOf": self.opt(self.nat),
                                     "reason": self.text()}}
        if t == 0x0A:
            return {"accrualPosted": {"product": self.text(), "currency": self.text(),
                                      "day": self.nat(), "amount": self.nat(), "accounts": self.nat()}}
        if t == 0x0B:
            return {"interestCapitalised": {
                "product": self.text(), "currency": self.text(), "from": self.nat(), "to": self.nat(),
                "examined": self.nat(), "posted": self.nat(), "zero": self.nat(), "total": self.nat(),
                "residueNumerator": self.nat(), "residueDenominator": self.nat(),
                "residueNegative": self.byte() == 1}}
        if t == 0x0C:
            return {"loanDisbursed": {"account": self.nat(), "amount": self.nat(),
                                      "day": self.nat(), "schedule": self.p_instalments()}}
        if t == 0x0D:
            return {"loanRescheduled": {"account": self.nat(), "version": self.nat(),
                                        "effective": self.nat(), "schedule": self.p_instalments()}}
        if t == 0x0E:
            return {"repaymentReceived": {"account": self.nat(), "day": self.nat(), "amount": self.nat(),
                                          "applied": self.p_allocation(), "overpayment": self.nat()}}
        if t == 0x0F:
            return {"provisionSet": {"account": self.nat(), "band": self.opt(self.text),
                                     "stage": self.opt(self.nat), "required": self.nat(),
                                     "previous": self.nat()}}
        if t == 0x10:
            return {"loanWrittenOff": {"account": self.nat(), "components": self.p_allocation(),
                                       "fromAllowance": self.nat(), "toExpense": self.nat(),
                                       "day": self.nat()}}
        if t == 0x11:
            return {"recoveryReceived": {"account": self.nat(), "amount": self.nat(), "day": self.nat()}}
        if t == 0x12:
            return {"termDepositRedeemed": {"account": self.nat(), "day": self.nat(),
                                            "entitled": self.nat(), "recoverable": self.nat(),
                                            "payable": self.nat(), "early": self.byte() == 1}}
        if t == 0x13:
            return {"tillOpened": {"till": self.text(), "book": self.text(), "currency": self.text(),
                                   "holder": self.principal(), "product": self.text()}}
        if t == 0x14:
            return {"tillAllocated": {"till": self.text(), "amount": self.nat(), "day": self.nat()}}
        if t == 0x15:
            return {"tillReturned": {"till": self.text(), "amount": self.nat(), "day": self.nat()}}
        if t == 0x16:
            return {"tillSettled": {"till": self.text(), "declared": self.nat(), "book": self.nat(),
                                    "difference": self.p_difference(), "day": self.nat()}}
        if t == 0x17:
            return {"tillClosed": {"till": self.text()}}
        if t == 0x18:
            return {"accountRateSet": {"account": self.nat(), "rate": self.p_rate(), "effective": self.nat()}}
        if t == 0x19:
            return {"productRedenominated": {"id": self.text(), "version": self.nat(), "supersedes": self.nat(), "from": self.text(), "to": self.text(), "terms": self.p_terms()}}
        if t == 0x1A:
            return {"accountRedenominated": {"account": self.nat(), "version": self.nat(), "from": self.text(), "to": self.text()}}
        if t == 0x1B:
            return {"scheduleTermsSet": {"account": self.nat(), "terms": self.p_schedule_terms(), "effective": self.nat()}}
        raise ValueError("unknown product event tag %#x" % t)


    # ── value dating and the close close shapes ──
    VALUE_DATE_CONVENTIONS = ["sameDay", "following", "modifiedFollowing", "preceding",
                   "modifiedPreceding", "endOfMonth"]
    FX_DIRECTION = ["gain", "loss", "unchanged"]
    ADJ_DIRECTION = ["increase", "decrease", "unchanged"]
    DEFERRAL_KIND = ["unearnedIncome", "prepaidExpense"]

    def c_convention(self):
        return self.VALUE_DATE_CONVENTIONS[self.byte()]

    def c_rate(self):
        return {"currency": self.text(), "functional": self.text(), "numerator": self.nat(),
                "denominator": self.nat(), "asOf": self.nat(), "source": self.text()}

    def c_pair(self):
        return {"currency": self.text(), "position": self.text(), "equivalent": self.text(),
                "unrealised": self.text(), "realised": self.text(), "monetary": self.byte() == 1}

    def c_window(self):
        return {"book": self.text(), "freeDays": self.nat(), "approvedDays": self.nat()}

    def c_direction(self):
        return self.FX_DIRECTION[self.byte()]

    def c_adj_direction(self):
        return self.ADJ_DIRECTION[self.byte()]

    def c_schedule(self):
        return {"id": self.text(), "kind": self.DEFERRAL_KIND[self.byte()], "currency": self.text(),
                "amount": self.nat(), "periods": self.nat(), "deferralAccount": self.text(),
                "recognitionAccount": self.text(), "book": self.text(), "openedOn": self.nat()}

    def c_endpoint(self):
        t = self.byte()
        if t == 0:
            return {"account": self.nat()}
        if t == 1:
            return {"glAccount": self.text()}
        raise ValueError("bad endpoint tag %d" % t)

    def close_event(self):
        t = self.byte()
        if t == 0x01:
            return {"functionalCurrencySet": {"currency": self.text()}}
        if t == 0x02:
            return {"fxPairSet": {"pair": self.c_pair()}}
        if t == 0x03:
            return {"fxRateSet": {"rate": self.c_rate()}}
        if t == 0x04:
            return {"backValueWindowSet": {"window": self.c_window()}}
        if t == 0x05:
            return {"backValueApproved": {"book": self.text(), "valueDate": self.nat(),
                                          "approver": self.principal(), "reason": self.text()}}
        if t == 0x06:
            return {"fxDealBooked": {"sell": self.text(), "sellAmount": self.nat(),
                                     "buy": self.text(), "buyAmount": self.nat(),
                                     "rateNumerator": self.nat(), "rateDenominator": self.nat(),
                                     "asOf": self.nat(), "day": self.nat()}}
        if t == 0x07:
            return {"fxRevalued": {"currency": self.text(), "position": self.nat(),
                                   "equivalent": self.nat(), "revalued": self.nat(),
                                   "movement": self.nat(), "direction": self.c_direction(),
                                   "rateNumerator": self.nat(), "rateDenominator": self.nat(),
                                   "rateAsOf": self.nat(), "day": self.nat()}}
        if t == 0x08:
            return {"fxRealised": {"currency": self.text(), "closedPosition": self.nat(),
                                   "bookedEquivalent": self.nat(), "proceeds": self.nat(),
                                   "movement": self.nat(), "direction": self.c_direction(),
                                   "day": self.nat()}}
        if t == 0x09:
            return {"accrualAdjusted": {"product": self.text(), "currency": self.text(),
                                        "from": self.nat(), "to": self.nat(),
                                        "recomputed": self.nat(), "booked": self.nat(),
                                        "movement": self.nat(), "direction": self.c_adj_direction(),
                                        "causedBy": self.nat(), "examined": self.nat()}}
        if t == 0x0A:
            return {"deferralScheduleOpened": {"schedule": self.c_schedule()}}
        if t == 0x0B:
            return {"deferralAmortised": {"schedule": self.text(), "period": self.text(),
                                          "sequence": self.nat(), "amount": self.nat(),
                                          "remaining": self.nat()}}
        if t == 0x10:
            return {"periodEndOpened": {"book": self.text(), "period": self.text(),
                                        "closingDate": self.nat()}}
        if t == 0x11:
            return {"periodEndRatesRecorded": {"book": self.text(), "period": self.text(),
                                               "currencies": self.nat()}}
        if t == 0x12:
            return {"periodEndAccrualComplete": {"book": self.text(), "period": self.text(),
                                                 "lastBusinessDay": self.nat()}}
        if t == 0x13:
            return {"periodEndRevalued": {"book": self.text(), "period": self.text(),
                                          "currencies": self.nat(), "posted": self.nat(),
                                          "total": self.nat()}}
        if t == 0x14:
            book = self.text()
            period = self.text()
            total = self.nat()
            rows = [{"schedule": self.text(), "sequence": self.nat(), "amount": self.nat(),
                     "remaining": self.nat()} for _ in range(self.len16())]
            return {"periodEndDeferralsAmortised": {"book": book, "period": period,
                                                    "total": total, "rows": rows}}
        if t == 0x15:
            return {"periodEndReconciled": {"book": self.text(), "period": self.text(),
                                            "controls": self.nat()}}
        if t == 0x16:
            return {"periodEndClosed": {"book": self.text(), "period": self.text()}}
        if t == 0x17:
            return {"bookClosedForPeriod": {"book": self.text(), "period": self.text()}}
        if t == 0x19:
            return {"currencyCalendarSet": {"currency": self.text(), "calendar": self.calendar()}}
        if t == 0x1A:
            rd = self.c_redenomination()
            return {"redenominationDeclared": {"redenomination": rd, "products": [self.text() for _ in range(self.len16())]}}
        if t == 0x1B:
            return {"balanceRedenominated": {"from": self.text(), "to": self.text(), "account": self.text(), "subledger": self.opt_blob_(),
                                            "productAccount": self.opt_nat(), "oldAmount": self.nat(), "newAmount": self.nat(),
                                            "creditBalance": self.bool(), "day": self.nat()}}
        if t == 0x1C:
            return {"redenominationCompleted": {"from": self.text(), "to": self.text(), "rows": self.nat(), "oldTotal": self.nat(),
                                               "newTotal": self.nat(), "roundingAmount": self.nat(), "roundingDebit": self.bool(), "day": self.nat()}}
        if t == 0x18:
            book = self.text()
            period = self.text()
            retained = self.text()
            closed = self.nat()
            results = [{"currency": self.text(), "profitCredits": self.nat(),
                        "lossDebits": self.nat()} for _ in range(self.len16())]
            return {"yearEndRolled": {"book": book, "period": period,
                                      "retainedEarnings": retained,
                                      "accountsClosed": closed, "results": results}}
        raise ValueError("unknown close event tag %#x" % t)

    def c_redenomination(self):
        return {"from": self.text(), "to": self.text(), "minorUnits": self.byte(), "ratioNumerator": self.nat(), "ratioDenominator": self.nat(),
                "bridgeAccount": self.text(), "roundingAccount": self.text(), "day": self.nat()}

    # ─── the end-of-day batch ──────────────────────────────────────────

    JOBS = {1: "accrual", 2: "charges", 3: "instalmentsDue", 4: "ageing", 5: "provisioning",
            6: "maturity", 7: "standingInstructions", 8: "statementCut", 9: "tillCheck", 10: "monitoring", 11: "offerExpiry", 12: "facilities", 13: "trade", 14: "sharia", 15: "treasury", 16: "cards", 17: "redenomination"}

    def b_job(self):
        rank = self.nat()
        if rank not in self.JOBS:
            raise ValueError("unknown batch job rank %d" % rank)
        return self.JOBS[rank]

    def b_failures(self):
        return [{"item": self.nat(), "job": self.b_job(), "entity": self.text(),
                 "error": self.text(), "attempts": self.nat()}
                for _ in range(self.len16())]

    def b_instruction(self):
        return {"id": self.text(), "book": self.text(), "from": self.nat(), "to": self.nat(),
                "amount": self.nat(), "currency": self.text(), "everyDays": self.nat(),
                "startDay": self.nat(), "endDay": self.opt(self.nat), "narration": self.text()}

    def b_cut(self):
        return {"account": self.nat(), "day": self.nat(), "currency": self.text(),
                "openingDebits": self.nat(), "openingCredits": self.nat(),
                "closingDebits": self.nat(), "closingCredits": self.nat(),
                "movements": self.nat()}

    def batch_event(self):
        t = self.byte()
        if t == 0x01:
            return {"retryPolicySet": {"policy": {"book": self.text(), "limit": self.nat()}}}
        if t == 0x02:
            return {"standingInstructionDefined": {"instruction": self.b_instruction()}}
        if t == 0x03:
            return {"standingInstructionCancelled": {"id": self.text()}}
        if t == 0x10:
            return {"eodOpened": {"book": self.text(), "businessDate": self.nat(),
                                  "shardSize": self.nat(), "openedAtHeight": self.nat(),
                                  "maxAccount": self.nat(), "planHash": self.blob(),
                                  "items": self.nat(), "entities": self.nat()}}
        if t == 0x11:
            return {"eodChunk": {"book": self.text(), "businessDate": self.nat(),
                                 "cursorFrom": self.nat(), "cursorTo": self.nat(),
                                 "posted": self.nat(), "examined": self.nat(),
                                 "zeroMovement": self.nat(), "failures": self.b_failures()}}
        if t == 0x12:
            return {"eodCompleted": {"book": self.text(), "businessDate": self.nat(),
                                     "posted": self.nat(), "examined": self.nat(),
                                     "zeroMovement": self.nat(), "failures": self.nat()}}
        if t == 0x13:
            return {"eodFailed": {"book": self.text(), "businessDate": self.nat(),
                                  "reason": self.text()}}
        if t == 0x14:
            book = self.text()
            businessDate = self.nat()
            resolved = [{"item": self.nat(), "entity": self.text()} for _ in range(self.nat())]
            return {"eodRetry": {"book": book, "businessDate": businessDate, "resolved": resolved,
                                 "failures": self.b_failures(), "posted": self.nat()}}
        if t == 0x15:
            return {"eodFailureResolved": {"book": self.text(), "businessDate": self.nat(),
                                           "item": self.nat(), "entity": self.text(),
                                           "justification": self.text()}}
        if t == 0x16:
            return {"eodItemCursor": {"book": self.text(), "businessDate": self.nat(),
                                      "item": self.nat(), "cursor": self.blob()}}
        if t == 0x20:
            return {"loanAged": {"account": self.nat(), "day": self.nat(),
                                 "band": (self.text() if self.byte() == 1 else None),
                                 "overdueDays": self.nat(), "overdueTotal": self.nat(),
                                 "instalmentsOverdue": self.nat()}}
        if t == 0x21:
            return {"statementCutRecorded": {"cut": self.b_cut()}}
        if t == 0x22:
            return {"standingInstructionExecuted": {"id": self.text(), "day": self.nat(),
                                                    "amount": self.nat()}}
        if t == 0x23:
            return {"depositMatured": {"account": self.nat(), "day": self.nat(),
                                       "entitled": self.nat()}}
        if t == 0x24:
            return {"instalmentDue": {"account": self.nat(), "day": self.nat(),
                                      "instalment": self.nat(), "interest": self.nat(),
                                      "principal": self.nat()}}
        raise ValueError(f"unknown batch event tag {t:#x}")

    # ─── regulatory reporting ──────────────────────────────────────────

    R_DIMENSIONS = {0x01: "account", 0x03: "leadsheet", 0x04: "category", 0x05: "currency",
                    0x06: "book", 0x07: "product"}

    def r_dimension(self):
        t = self.byte()
        if t in self.R_DIMENSIONS:
            return {self.R_DIMENSIONS[t]: None}
        if t == 0x02:
            return {"accountRange": {"lo": self.nat(), "hi": self.nat()}}
        if t == 0x08:
            return {"counterpartyClass": {"schema": self.text(), "field": self.text()}}
        raise ValueError(f"unknown report dimension tag {t:#x}")

    R_MEASURES = {0x11: "periodDebits", 0x12: "periodCredits", 0x13: "closingDebits",
                  0x14: "closingCredits", 0x15: "netMovement", 0x16: "closingBalance",
                  0x17: "entryCount"}

    def r_measure(self):
        t = self.byte()
        if t in self.R_MEASURES:
            return {self.R_MEASURES[t]: None}
        if t == 0x18:
            return {"balanceAsOf": self.nat()}
        if t == 0x19:
            return {"valueDatedBalance": self.nat()}
        raise ValueError(f"unknown report measure tag {t:#x}")

    def r_def(self):
        d = {"id": self.text(), "version": self.nat(), "title": self.text()}
        d["rows"] = [self.r_dimension() for _ in range(self.len16())]
        filters = []
        for _ in range(self.len16()):
            dim = self.r_dimension()
            t = self.byte()
            if t == 0x21:
                op = {"eq": self.text()}
            elif t == 0x22:
                op = {"inSet": [self.text() for _ in range(self.len16())]}
            elif t == 0x23:
                op = {"range": {"lo": self.nat(), "hi": self.nat()}}
            else:
                raise ValueError(f"unknown filter tag {t:#x}")
            filters.append({"dimension": dim, "op": op})
        d["filters"] = filters
        d["measures"] = [self.r_measure() for _ in range(self.len16())]
        t = self.byte()
        if t == 0x31:
            d["ordering"] = {"byRowKey": None}
        elif t == 0x32:
            d["ordering"] = {"byCategoryThenAccount": None}
        elif t == 0x33:
            d["ordering"] = {"byMeasureDescending": self.nat()}
        else:
            raise ValueError(f"unknown ordering tag {t:#x}")
        d["scale"] = ["minorUnits", "units", "thousands", "millions"][self.byte()]
        d["comparatives"] = ["none", "priorPeriod", "priorYear"][self.byte()]
        d["maxSlice"] = self.nat()
        return d

    def r_line_source(self):
        t = self.byte()
        if t == 0x01:
            return {"sumOfAccounts": {"accounts": [self.text() for _ in range(self.len16())],
                                      "measure": self.r_measure()}}
        if t == 0x02:
            ranges = [{"lo": self.nat(), "hi": self.nat()} for _ in range(self.len16())]
            return {"sumOfRanges": {"ranges": ranges, "measure": self.r_measure()}}
        if t == 0x03:
            return {"sumOfLines": {"lines": [self.text() for _ in range(self.len16())]}}
        if t == 0x04:
            return {"difference": {"minuend": self.text(), "subtrahend": self.text()}}
        if t == 0x05:
            return {"ratio": {"numerator": self.text(), "denominator": self.text(),
                              "scale": self.nat(),
                              "whenZero": ["reportZero", "reportUnmeasurable", "refuse"][self.byte()]}}
        if t == 0x06:
            return {"weighted": {"line": self.text(), "numerator": self.nat(),
                                 "denominator": self.nat()}}
        if t == 0x07:
            return {"declared": {"value": self.r_int()}}
        raise ValueError(f"unknown return line source tag {t:#x}")

    def r_int(self):
        sign = self.byte()
        n = self.nat()
        return -n if sign == 1 else n

    def r_template(self):
        t = {"id": self.text(), "version": self.nat(), "title": self.text(),
             "authority": self.text(), "currency": self.text()}
        t["taxonomy"] = self.opt(self.text)
        t["parameters"] = [{"name": self.text(), "numerator": self.nat(), "denominator": self.nat()}
                           for _ in range(self.len16())]
        lines = []
        for _ in range(self.len16()):
            code = self.text()
            caption = self.text()
            binding = self.opt(self.text)
            lines.append({"code": code, "caption": caption, "binding": binding,
                          "source": self.r_line_source()})
        t["lines"] = lines
        return t

    def r_statement_map(self):
        return {"cash": [self.text() for _ in range(self.len16())],
                "retainedEarnings": self.text(),
                "investing": [self.text() for _ in range(self.len16())],
                "financing": [self.text() for _ in range(self.len16())],
                "monetary": [self.text() for _ in range(self.len16())]}

    R_BALANCE_TYPES = {1: "OPBD", 2: "CLBD", 3: "ITBD", 4: "PRCD", 5: "CLAV"}

    def r_statement_kind(self):
        t = self.byte()
        if t == 0x53:
            return {"camt053": {"cut": self.nat()}}
        if t == 0x52:
            return {"camt052": {"asOf": self.nat()}}
        if t == 0x54:
            return {"camt054": {"movement": self.nat()}}
        raise ValueError(f"unknown statement kind tag {t:#x}")

    def r_statement(self):
        out = {"id": self.text(), "account": self.nat(), "kind": self.r_statement_kind(),
               "currency": self.text(), "period": self.text()}
        out["balances"] = [{"kind": self.R_BALANCE_TYPES[self.byte()], "debits": self.nat(),
                            "credits": self.nat(), "net": self.r_int()}
                           for _ in range(self.len16())]
        out["entryBlocks"] = [self.nat() for _ in range(self.len16())]
        out["issued"] = self.nat()
        out["contentHash"] = self.blob()
        out["atHeight"] = self.nat()
        return out

    def r_endpoint(self):
        return {"url": self.text(), "retries": [self.nat() for _ in range(self.len16())],
                "active": self.byte() == 1}

    def report_event(self):
        t = self.byte()
        if t == 0x01:
            return {"reportDefinitionRegistered": {"definition": self.r_def(), "hash": self.blob()}}
        if t == 0x02:
            return {"returnTemplateRegistered": {"template": self.r_template(), "hash": self.blob()}}
        if t == 0x03:
            return {"statementMapSet": {"book": self.text(), "map": self.r_statement_map()}}
        if t == 0x04:
            return {"reportCertified": {"kind": self.text(), "id": self.text(), "book": self.text(),
                                        "period": self.text(), "atHeight": self.nat(),
                                        "contentHash": self.blob(), "rows": self.nat()}}
        if t == 0x05:
            return {"statementIssued": {"statement": self.r_statement()}}
        if t == 0x06:
            return {"feedEndpointSet": {"endpoint": self.r_endpoint()}}
        if t == 0x07:
            return {"feedDeadLettered": {"letter": {"cursor": self.nat(), "endpoint": self.text(),
                                                    "attempts": self.nat(), "reason": self.text()}}}
        raise ValueError(f"unknown report event tag {t:#x}")

    def command(self, encoding=CURRENT_COMMAND_ENCODING):
        """A command under a recorded encoding version. Version 1 is every family's bytes before 2026-09-13;
        version 2 appends `application : ?Nat` to createCustomer and is otherwise version 1."""
        assert encoding in SUPPORTED_COMMAND_ENCODINGS, f"command encoding {encoding} is not one this verifier implements"
        tag = self.byte()
        if tag == 0x01:
            return {"defineRole": {"id": self.text(), "name": self.text(), "permissions": self.texts()}}
        if tag == 0x02:
            return {"grantRole": {"subject": self.principal(), "role": self.text(), "scope": self.scope()}}
        if tag == 0x03:
            return {"revokeRole": {"subject": self.principal(), "role": self.text()}}
        if tag == 0x04:
            return {"setDualPolicy": self.policy()}
        if tag == 0x05:
            return {"clearDualPolicy": {"permission": self.text()}}
        if tag == 0x06:
            return {"openBook": {"id": self.text(), "name": self.text(), "parent": self.opt(self.text)}}
        if tag == 0x07:
            return {"closeBook": {"id": self.text()}}
        if tag == 0x08:
            return {"transferBankAdmin": {"admin": self.principal()}}
        if tag == 0x09:
            return {"setFeatureActivation": {"feature": self.text(), "height": self.nat64()}}
        if tag == 0x20:
            return {"journalRegisterCurrency": {"code": self.text(), "minorUnits": self.byte()}}
        if tag == 0x21:
            return {"journalOpenAccount": {"code": self.text(), "name": self.text(), "normalSide": self.side(),
                                           "category": self.category(), "constraint": self.constraint()}}
        if tag == 0x22:
            return {"journalCloseAccount": {"code": self.text()}}
        if tag == 0x23:
            return {"journalOpenPeriod": {"id": self.text(), "start": self.nat(), "end": self.nat()}}
        if tag == 0x24:
            return {"journalClosePeriod": {"id": self.text()}}
        if tag == 0x25:
            return {"journalSetActivationHeight": {"height": self.nat64()}}
        if tag == 0x26:
            n = self.len16()
            return {"journalSetLeadsheetSchema": {"ranges": [
                {"lo": self.nat(), "hi": self.nat(), "leadsheet": self.text(), "name": self.text(),
                 "category": self.text(), "cycle": self.text()} for _ in range(n)]}}
        if tag == 0x27:
            return {"journalAddPoster": {"poster": self.principal()}}
        if tag == 0x28:
            return {"journalRemovePoster": {"poster": self.principal()}}
        if tag == 0x29:
            return {"journalSetPosterScope": {"poster": self.principal(), "accounts": self.opt_texts()}}
        if tag == 0x2A:
            return {"journalRollBusinessDate": {"day": self.nat()}}
        if tag == 0x2B:
            return {"journalSetCalendar": {"calendar": self.bank_calendar()}}
        if tag == 0x2C:
            return {"journalSetCalendarAuthority": {"authority": ["substrateClock", "businessDate"][self.byte()], "maxRollDays": self.nat(), "businessDate": self.opt(self.nat)}}
        if tag == 0x40:
            return {"postManualEntry": self.manual_entry()}
        if tag == 0x41:
            return {"reverseManualEntry": {"original": self.nat(), "book": self.text(), "postingDate": self.nat(),
                                           "valueDate": self.nat(), "period": self.text(),
                                           "narration": self.text(), "idempotencyKey": self.blob()}}
        if tag == 0x42:
            return {"postManualEntryForParty": {"party": self.nat(), "entry": self.manual_entry()}}
        if tag == 0x50:
            return {"createParty": {
                "kind": self.party_kind(), "salt": self.blob(), "identityCommit": self.blob(),
                "dedupCommit": self.opt_commit(), "attributes": self.field_commits(),
                "book": self.text(), "cddLevel": self.cdd(), "riskRating": self.risk(),
                "pep": self.byte() == 1, "reviewDue": self.nat()}}
        if tag == 0x19:
            # onboarding as one dual act (one dual act)
            party = {"kind": self.party_kind(), "salt": self.blob(), "identityCommit": self.blob(),
                     "dedupCommit": self.opt_commit(), "attributes": self.field_commits(),
                     "book": self.text(), "cddLevel": self.cdd(), "riskRating": self.risk(),
                     "pep": self.byte() == 1, "reviewDue": self.nat()}
            documents = [self.document() for _ in range(self.len16())]
            screening = None
            if self.byte() == 1:
                version, root, t = self.text(), self.blob(), self.byte()
                decision = "clear" if t == 0 else {"hit": {"matches": self.nat()}} if t == 1 else {"cleared": {"reason": self.text()}} if t == 2 else "confirmed"
                screening = {"listVersion": version, "listRoot": root, "decision": decision, "screener": self.principal(), "justificationCommit": self.blob()}
            lifecycle = self.lifecycle()
            extensions = self.extension_values()
            accounts = [{"product": self.text(), "currency": self.text(), "termDays": self.opt(self.nat), "allocationOrder": self.p_components(), "activate": self.byte() == 1} for _ in range(self.len16())]
            application = self.opt(self.nat) if encoding >= 2 else None
            return {"createCustomer": {"party": party, "documents": documents, "screening": screening, "lifecycle": lifecycle, "extensions": extensions, "accounts": accounts, "application": application}}
        if tag == 0x51:
            return {"amendParty": {"party": self.nat(), "attributes": self.field_commits()}}
        if tag == 0x52:
            return {"setPartyLifecycle": {"party": self.nat(), "to": self.lifecycle()}}
        if tag == 0x53:
            return {"setPartyCdd": {"party": self.nat(), "level": self.cdd(), "riskRating": self.risk(),
                                    "pep": self.byte() == 1, "reviewDue": self.nat()}}
        if tag == 0x54:
            return {"addPartyDocument": {"party": self.nat(), "document": self.document()}}
        if tag == 0x55:
            return {"addPartyRelationship": {"party": self.nat(), "relationship": self.relationship()}}
        if tag == 0x56:
            return {"setPartyExtension": {"party": self.nat(), "values": self.extension_values()}}
        if tag == 0x57:
            return {"issueIdentifier": {"party": self.nat()}}
        if tag == 0x58:
            return {"commitScreeningList": {"version": self.text(), "root": self.blob(),
                                            "count": self.nat(), "normalisation": self.text()}}
        if tag == 0x59:
            return {"proveScreeningClear": {"party": self.nat(), "listVersion": self.text(),
                                            "subject": self.blob(), "proof": self.adjacency()}}
        if tag == 0x5A:
            return {"recordScreeningDecision": self.screening_decision()}
        if tag == 0x5B:
            return {"registerSchema": {"id": self.text(), "entity": self.entity_kind(),
                                       "fields": self.field_defs()}}
        if tag == 0x5C:
            return {"registerCollateral": {"party": self.nat(), "kind": self.collateral_kind(),
                                           "valuation": self.valuation(), "descriptionCommit": self.blob()}}
        if tag == 0x5D:
            return {"revalueCollateral": {"collateral": self.nat(), "valuation": self.valuation()}}
        if tag == 0x5E:
            return {"allocateCollateral": {"collateral": self.nat(), "facility": self.text(), "amount": self.nat()}}
        if tag == 0x5F:
            return {"releaseCollateral": {"collateral": self.nat()}}
        if tag == 0x60:
            return {"addStaff": {"principal_": self.principal(), "book": self.text(), "title": self.text()}}
        if tag == 0x61:
            return {"removeStaff": {"principal_": self.principal()}}
        if tag == 0x62:
            return {"setAccountFormat": self.iban_format()}
        if tag == 0x63:
            return {"setReviewGrace": {"days": self.nat()}}
        if tag == 0x64:
            return {"pinJwks": self.jwks()}
        if tag == 0x65:
            return {"registerCredential": self.credential()}
        if tag == 0x66:
            return {"revokeCredential": {"subject": self.principal()}}
        if tag == 0x70:
            return {"registerProduct": {"id": self.text(), "name": self.text(), "terms": self.p_terms()}}
        if tag == 0x71:
            return {"amendProduct": {"id": self.text(), "name": self.text(), "terms": self.p_terms()}}
        if tag == 0x72:
            return {"closeProductToNewAccounts": {"id": self.text(), "version": self.nat()}}
        if tag == 0x73:
            return {"openAccount": {"product": self.text(), "party": self.nat(), "currency": self.text(),
                                    "termDays": self.opt(self.nat), "allocationOrder": self.p_components()}}
        if tag == 0x74:
            return {"setAccountStatus": {"account": self.nat(), "to": self.p_status()}}
        if tag == 0x75:
            return {"migrateAccount": {"account": self.nat(), "to": self.nat()}}
        if tag == 0x76:
            return {"openTill": {"till": self.text(), "book": self.text(), "currency": self.text(),
                                 "holder": self.principal(), "product": self.text()}}
        if tag == 0x77:
            return {"closeTill": {"till": self.text()}}
        if tag == 0x78:
            return {"grantFacility": {"account": self.nat(), "limit": self.nat()}}
        if tag == 0x79:
            return {"depositToAccount": self.p_money_move()}
        if tag == 0x7A:
            return {"withdrawFromAccount": self.p_money_move()}
        if tag == 0x7B:
            return {"transferBetweenAccounts": {"from": self.nat(), "to": self.nat(), "amount": self.nat(),
                                                "postingDate": self.nat(), "valueDate": self.nat(),
                                                "period": self.text(), "narration": self.text()}}
        if tag == 0x7C:
            return {"applyCharge": {"account": self.nat(), "charge": self.text(), "occurrence": self.nat(),
                                    "base": self.p_charge_base(), "postingDate": self.nat(),
                                    "valueDate": self.nat(), "period": self.text(), "narration": self.text()}}
        if tag == 0x7D:
            return {"waiveCharge": {"account": self.nat(), "charge": self.text(), "occurrence": self.nat(),
                                    "postingDate": self.nat(), "valueDate": self.nat(),
                                    "period": self.text(), "reason": self.text()}}
        if tag == 0x7E:
            return {"postAccrual": {"product": self.text(), "currency": self.text(), "day": self.nat(),
                                    "period": self.text(), "narration": self.text()}}
        if tag == 0x7F:
            return {"capitaliseInterest": {"product": self.text(), "currency": self.text(), "to": self.nat(),
                                           "postingDate": self.nat(), "period": self.text(),
                                           "narration": self.text()}}
        if tag == 0x80:
            return {"disburseLoan": self.p_money_move()}
        if tag == 0x81:
            return {"repayLoan": self.p_money_move()}
        if tag == 0x82:
            return {"rescheduleLoan": {"account": self.nat(), "effective": self.nat(),
                                       "terms": self.p_schedule_terms(), "rate": self.p_rate()}}
        if tag == 0x83:
            return {"setProvision": {"account": self.nat(), "asOf": self.nat(), "postingDate": self.nat(),
                                     "period": self.text(), "narration": self.text()}}
        if tag == 0x84:
            return {"writeOffLoan": {"account": self.nat(), "postingDate": self.nat(),
                                     "valueDate": self.nat(), "period": self.text(),
                                     "narration": self.text()}}
        if tag == 0x85:
            return {"recordRecovery": self.p_money_move()}
        if tag == 0x86:
            return {"redeemTermDeposit": self.p_money_move()}
        if tag == 0x87:
            return {"allocateCashToTill": {"till": self.text(), "amount": self.nat(),
                                           "postingDate": self.nat(), "valueDate": self.nat(),
                                           "period": self.text(), "narration": self.text()}}
        if tag == 0x88:
            return {"returnCashFromTill": {"till": self.text(), "amount": self.nat(),
                                           "postingDate": self.nat(), "valueDate": self.nat(),
                                           "period": self.text(), "narration": self.text()}}
        if tag == 0x89:
            return {"settleTill": {"till": self.text(), "declared": self.nat(),
                                   "postingDate": self.nat(), "valueDate": self.nat(),
                                   "period": self.text(), "narration": self.text()}}
        if tag == 0x90:
            return {"setFunctionalCurrency": {"currency": self.text()}}
        if tag == 0x91:
            return {"setFxPair": {"pair": self.c_pair()}}
        if tag == 0x92:
            return {"setFxRate": {"rate": self.c_rate()}}
        if tag == 0x93:
            return {"setBackValueWindow": {"window": self.c_window()}}
        if tag == 0x94:
            return {"approveBackValue": {"book": self.text(), "valueDate": self.nat(),
                                         "reason": self.text()}}
        if tag == 0x95:
            return {"openDeferralSchedule": {"schedule": self.c_schedule()}}
        if tag == 0x96:
            return {"bookFxDeal": {"sell": self.text(), "sellAmount": self.nat(),
                                   "sellFrom": self.c_endpoint(), "buy": self.text(),
                                   "buyAmount": self.nat(), "buyTo": self.c_endpoint(),
                                   "rateAsOf": self.nat(), "postingDate": self.nat(),
                                   "valueDate": self.nat(), "period": self.text(),
                                   "narration": self.text()}}
        if tag == 0x97:
            return {"realiseFxPosition": {"currency": self.text(), "closedPosition": self.nat(),
                                          "bookedEquivalent": self.nat(), "proceeds": self.nat(),
                                          "postingDate": self.nat(), "valueDate": self.nat(),
                                          "period": self.text(), "narration": self.text()}}
        if tag == 0x98:
            return {"adjustAccrual": {"product": self.text(), "currency": self.text(),
                                      "from": self.nat(), "to": self.nat(), "causedBy": self.nat(),
                                      "postingDate": self.nat(), "period": self.text(),
                                      "narration": self.text()}}
        if tag == 0x99:
            return {"amortiseDeferral": {"schedule": self.text(), "postingDate": self.nat(),
                                         "valueDate": self.nat(), "period": self.text(),
                                         "narration": self.text()}}
        if tag == 0x9A:
            return {"openPeriodEnd": {"book": self.text(), "period": self.text()}}
        if tag == 0x9B:
            return {"recordClosingRates": {"book": self.text(), "period": self.text()}}
        if tag == 0x9C:
            return {"markAccrualComplete": {"book": self.text(), "period": self.text()}}
        if tag == 0x9D:
            return {"revaluePositions": {"book": self.text(), "period": self.text(),
                                         "postingDate": self.nat(), "narration": self.text()}}
        if tag == 0x9E:
            return {"amortisePeriodDeferrals": {"book": self.text(), "period": self.text(),
                                               "postingDate": self.nat(), "narration": self.text()}}
        if tag == 0x9F:
            return {"reconcilePeriod": {"book": self.text(), "period": self.text()}}
        if tag == 0xA0:
            return {"closePeriodEnd": {"book": self.text(), "period": self.text()}}
        if tag == 0xA1:
            return {"rollYearEnd": {"book": self.text(), "period": self.text(),
                                    "retainedEarnings": self.text(), "narration": self.text()}}
        if tag == 0xB0:
            return {"setRetryPolicy": {"policy": {"book": self.text(), "limit": self.nat()}}}
        if tag == 0xB1:
            return {"defineStandingInstruction": {"instruction": self.b_instruction()}}
        if tag == 0xB2:
            return {"cancelStandingInstruction": {"id": self.text()}}
        if tag == 0xB3:
            return {"openEndOfDay": {"book": self.text(), "businessDate": self.nat(),
                                     "shardSize": self.nat()}}
        if tag == 0xB4:
            return {"resolveBatchFailure": {"book": self.text(), "businessDate": self.nat(),
                                            "item": self.nat(), "entity": self.text(),
                                            "justification": self.text()}}
        if tag == 0xC0:
            return {"registerReportDefinition": {"definition": self.r_def()}}
        if tag == 0xC1:
            return {"registerReturnTemplate": {"template": self.r_template()}}
        if tag == 0xC2:
            return {"setStatementMap": {"book": self.text(), "map": self.r_statement_map()}}
        if tag == 0xC3:
            return {"certifyReport": {
                "definition": self.text(), "version": self.nat(), "book": self.text(),
                "period": self.text(),
                "view": ["native", "functional"][self.byte()],
                "functional": self.opt(self.text)}}
        if tag == 0xC4:
            return {"certifyReturn": {"template": self.text(), "version": self.nat(),
                                      "book": self.text(), "period": self.text()}}
        if tag == 0xC5:
            return {"certifyExport": {
                "shape": {1: "safT", 2: "aicpaAds", 3: "normalisedTrialBalance"}[self.byte()],
                "book": self.text(), "period": self.text()}}
        if tag == 0xC6:
            return {"issueStatement": {"account": self.nat(), "kind": self.r_statement_kind(),
                                       "period": self.text()}}
        if tag == 0xC7:
            return {"setFeedEndpoint": {"endpoint": self.r_endpoint()}}
        if tag == 0xC8:
            return {"recordFeedDeadLetter": {"letter": {
                "cursor": self.nat(), "endpoint": self.text(), "attempts": self.nat(),
                "reason": self.text()}}}
        if tag == 0xC9:
            present = self.byte()
            if present == 0:
                return {"setCounterpartyClassDimension": {"dimension": None}}
            assert present == 1, "setCounterpartyClassDimension: bad option byte"
            return {"setCounterpartyClassDimension": {"dimension": {"schema": self.text(), "field": self.text()}}}
        if tag == 0xCA:
            return {"pinArchiveImage": {"sha256": self.blob(), "bytes": self.nat(), "name": self.text()}}
        if tag == 0xCB:
            return {"setArchiveControllers": {"controllers": self.principals()}}
        if tag == 0xCC:
            return {"spawnArchive": {"purpose": self.text()}}
        if tag == 0xCD:
            return {"abandonArchiveSpawn": {"spawn": self.nat(), "reason": self.text()}}
        if tag == 0xCE:
            return {"attachArchiveChild": {"spawn": self.nat(), "cid": self.nat64()}}
        if tag == 0xCF:
            return {"adoptArchiveChild": {"cid": self.nat64(), "moduleHash": self.blob(),
                                          "controllers": self.principals(), "purpose": self.text()}}
        if tag == 0xD0:
            return {"defineMonitoringRule": {"id": self.text(), "currency": self.opt_text(), "spec": self.rule_spec()}}
        if tag == 0xD1:
            return {"retireMonitoringRule": {"id": self.text()}}
        if tag == 0xD2:
            return {"clearAlert": {"alert": self.nat(), "reason": self.text()}}
        if tag == 0xD3:
            return {"escalateAlert": {"alert": self.nat(), "reportRef": self.text()}}
        # collections and recovery (collections and recovery)
        if tag == 0xF0:
            return {"setCollectionsPolicy": self.collections_policy()}
        if tag == 0xF1:
            return {"markUnlikelyToPay": {"account": self.nat(), "reason": self.text()}}
        if tag == 0xF2:
            return {"recordCollectionAction": {"account": self.nat(), "action": self.collection_action(), "outcome": self.text(), "next": self.opt(self.nat)}}
        if tag == 0xF3:
            return {"recordPromiseToPay": {"account": self.nat(), "amount": self.nat(), "by": self.nat()}}
        if tag == 0xF4:
            return {"assignCollector": {"account": self.nat(), "staff": self.principal()}}
        if tag == 0xF5:
            return {"closeRecovery": {"account": self.nat()}}
        # origination and underwriting (origination and underwriting)
        if tag == 0xA2:
            return {"setOriginationPolicy": self.origination_policy()}
        if tag == 0xA3:
            return {"setAffordabilityModel": self.affordability_model()}
        if tag == 0xA4:
            return {"setScorecard": self.scorecard()}
        if tag == 0xA5:
            return {"registerPasskey": {"party": self.nat(), "credentialId": self.blob(), "publicKeySpki": self.blob()}}
        if tag == 0xA6:
            return {"openApplication": {"party": self.opt_nat(), "book": self.text(), "request": self.credit_request(), "channel": self.text()}}
        if tag == 0xA7:
            return {"recordApplicationData": {"application": self.nat(), "facts": self.facts(), "commitments": self.commitments()}}
        if tag == 0xA8:
            return {"assessAffordability": {"application": self.nat()}}
        if tag == 0xA9:
            return {"requestBureauReport": {"application": self.nat(), "bureau": self.text(), "consentCommit": self.blob()}}
        if tag == 0xAA:
            return {"scoreApplication": {"application": self.nat()}}
        if tag == 0xAB:
            return {"underwrite": {"application": self.nat(), "decision": self.decision(), "rationale": self.text()}}
        if tag == 0xAC:
            return {"issueOffer": {"application": self.nat(), "terms": self.offer_terms()}}
        if tag == 0xAD:
            return {"acceptOffer": {"application": self.nat(), "assertion": self.assertion()}}
        if tag == 0xAE:
            return {"declineOffer": {"application": self.nat()}}
        if tag == 0xAF:
            return {"recordDocument": {"application": self.nat(), "kind": self.document_kind(), "sha256": self.blob(), "signed": self.opt(self.assertion)}}
        if tag == 0xB5:
            return {"recordConditionsMet": {"application": self.nat(), "conditions": self.texts()}}
        if tag == 0xB6:
            return {"fulfilApplication": {"application": self.nat()}}
        if tag == 0xB7:
            return {"withdrawApplication": {"application": self.nat(), "reason": self.text()}}
        # corporate lending (corporate lending)
        if tag == 0x30:
            return {"openFacility": self.facility_terms()}
        if tag == 0x31:
            return {"drawdown": self.facility_money()}
        if tag == 0x32:
            return {"transferParticipation": {"facility": self.nat(), "from": self.nat(), "to": self.nat(), "bps": self.nat()}}
        if tag == 0x33:
            return {"distributeToParticipants": {"facility": self.nat(), "funding": self.p_funding(), **self.dates()}}
        if tag == 0x34:
            return {"restructureFacility": {"facility": self.nat(), "effective": self.nat(), "terms": self.restructure_terms()}}
        if tag == 0x35:
            return {"recordCovenantTest": {"facility": self.nat(), "covenant": self.text(), "value": self.nat(), "statementHash": self.blob()}}
        if tag == 0x36:
            return {"blockDrawdowns": {"facility": self.nat(), "reason": self.text()}}
        if tag == 0x37:
            return {"unblockDrawdowns": {"facility": self.nat(), "reason": self.text()}}
        if tag == 0x38:
            return {"recordFacilityReview": {"facility": self.nat(), "note": self.text()}}
        if tag == 0x39:
            return {"recordRateFixing": {"index": self.text(), "day": self.nat(), "rateBps": self.nat()}}
        if tag == 0x3A:
            return {"receiveRental": self.facility_money()}
        if tag == 0x3B:
            return {"remeasureResidual": {"facility": self.nat(), "residual": self.nat(), **self.dates()}}
        if tag == 0x3C:
            return {"purchaseReceivables": {"facility": self.nat(), "receivables": self.receivables(), **self.dates()}}
        if tag == 0x3D:
            return {"collectReceivable": {"facility": self.nat(), "ref": self.blob(), "funding": self.p_funding(), **self.dates()}}
        if tag == 0x3E:
            return {"dishonourReceivable": {"facility": self.nat(), "ref": self.blob(), **self.dates()}}
        if tag == 0x3F:
            return {"writeOffReceivable": {"facility": self.nat(), "ref": self.blob(), **self.dates()}}
        if tag == 0x43:
            return {"closeFacility": {"facility": self.nat()}}
        # branch and teller (branch and teller)
        if tag == 0xF6:
            return {"setTellerPolicy": self.teller_policy()}
        if tag == 0xF7:
            return {"openTellerSession": {"till": self.text(), "teller": self.principal(), "opening": self.denominations()}}
        if tag == 0xF8:
            return {"closeTellerSession": {"till": self.text(), "closing": self.denominations()}}
        if tag == 0xF9:
            return {"resolveTillDifference": {"session": self.nat(), "note": self.text(), **self.dates()}}
        if tag == 0xFA:
            return {"cashDeposit": {"till": self.text(), "account": self.nat(), "amount": self.nat(), "tendered": self.denominations(), "change": self.denominations(), **self.dates()}}
        if tag == 0xFB:
            return {"cashWithdrawal": {"till": self.text(), "account": self.nat(), "amount": self.nat(), "paid": self.denominations(), **self.dates()}}
        if tag == 0xFC:
            return {"vaultToTill": {"till": self.text(), "amount": self.nat(), "denominations": self.denominations(), **self.dates()}}
        if tag == 0xFD:
            return {"tillToVault": {"till": self.text(), "amount": self.nat(), "denominations": self.denominations(), **self.dates()}}
        if tag == 0xFE:
            return {"dispatchCash": {"product": self.text(), "fromBook": self.text(), "toBook": self.text(), "currency": self.text(), "amount": self.nat(), "denominations": self.denominations(),
                                     "carrier": self.text(), "sealBag": self.text(), **self.dates()}}
        if tag == 0xFF:
            return {"receiveCash": {"movement": self.nat(), "denominations": self.denominations(), **self.dates()}}
        if tag == 0x13:
            return {"vaultToCentralBank": {"product": self.text(), "book": self.text(), "currency": self.text(), "amount": self.nat(), "denominations": self.denominations(), **self.dates()}}
        if tag == 0x14:
            return {"centralBankToVault": {"product": self.text(), "book": self.text(), "currency": self.text(), "amount": self.nat(), "denominations": self.denominations(), **self.dates()}}
        if tag == 0x15:
            return {"issueChequebook": {"account": self.nat(), "from": self.nat(), "to": self.nat()}}
        if tag == 0x16:
            return {"stopCheque": {"account": self.nat(), "serial": self.nat(), "reason": self.text()}}
        if tag == 0x17:
            return {"presentCheque": {"account": self.nat(), "serial": self.nat(), "amount": self.nat(), "payee": self.payee(), "chequeDate": self.nat(), "imageHash": self.blob(), **self.dates()}}
        if tag == 0x18:
            return {"clearCheque": {"account": self.nat(), "serial": self.nat(), **self.dates()}}
        if tag == 0x1A:
            return {"returnCheque": {"account": self.nat(), "serial": self.nat(), "reason": self.return_reason(), **self.dates()}}
        if tag == 0x1B:
            return {"issueDraft": {"serial": self.text(), "payeeCommit": self.blob(), "amount": self.nat(), "currency": self.text(), "source": self.cash_source(), **self.dates()}}
        if tag == 0x1C:
            return {"payDraft": {"serial": self.text(), "to": self.cash_source(), **self.dates()}}
        if tag == 0x1D:
            return {"cancelDraft": {"serial": self.text(), "refundTo": self.nat(), **self.dates()}}
        # trade finance (trade finance)
        if tag == 0x67:
            return {"setTradePolicy": self.trade_policy()}
        if tag == 0x68:
            return {"issueLetterOfCredit": {"lc": self.trade_lc(), "amount": self.nat(), "currency": self.text(), "expiry": self.nat(), "placeOfExpiry": self.text(), **self.dates()}}
        if tag == 0x69:
            return {"adviseLetterOfCredit": {"message": self.text(), "beneficiary": self.nat(), "beneficiaryAccount": self.nat(), "confirm": self.bool(),
                                             "checklist": [(self.document_kind(), self.texts()) for _ in range(self.len16())], "commissionBps": self.nat(), "facility": self.opt_nat(), **self.dates()}}
        if tag == 0x6A:
            return {"amendLetterOfCredit": {"instrument": self.nat(), "amendment": self.trade_amendment(), **self.dates()}}
        if tag == 0x6B:
            return {"presentDocuments": {"instrument": self.nat(), "documents": self.document_refs(), "amount": self.nat(), "shipmentDate": self.opt_nat(), "presentedOn": self.nat()}}
        if tag == 0x6C:
            return {"examinePresentation": {"instrument": self.nat(), "claim": self.nat(), "checks": self.trade_checks(), "decision": self.trade_decision()}}
        if tag == 0x6D:
            return {"waiveDiscrepancies": {"instrument": self.nat(), "claim": self.nat(), "applicantConsentHash": self.blob()}}
        if tag == 0x6E:
            return {"honourPresentation": {"instrument": self.nat(), "claim": self.nat(), "honour": self.trade_honour(), **self.dates()}}
        if tag == 0x6F:
            return {"settleAcceptance": {"instrument": self.nat(), "claim": self.nat(), **self.dates()}}
        if tag == 0x8A:
            return {"closeLetterOfCredit": {"instrument": self.nat(), "reason": self.text(), **self.dates()}}
        if tag == 0x8B:
            return {"issueGuarantee": {"guarantee": self.trade_guarantee(), "amount": self.nat(), "currency": self.text(), "expiry": self.nat(), "wordingText": self.text(), **self.dates()}}
        if tag == 0x8C:
            return {"amendGuarantee": {"instrument": self.nat(), "amendment": self.trade_amendment(), **self.dates()}}
        if tag == 0x8D:
            return {"recordDemand": {"instrument": self.nat(), "demand": self.document_ref(), "amount": self.nat(), "supportingStatement": self.bool(), "presentedOn": self.nat()}}
        if tag == 0x8E:
            return {"examineDemand": {"instrument": self.nat(), "claim": self.nat(), "checklist": self.texts(), "checks": self.trade_checks(), "decision": self.trade_decision()}}
        if tag == 0x8F:
            return {"payDemand": {"instrument": self.nat(), "claim": self.nat(), **self.dates()}}
        if tag == 0xB8:
            return {"reduceGuarantee": {"instrument": self.nat(), "to": self.nat(), **self.dates()}}
        if tag == 0xB9:
            return {"releaseGuarantee": {"instrument": self.nat(), "reason": self.text(), **self.dates()}}
        if tag == 0xBA:
            return {"registerCollection": {"collection": self.trade_collection(), "amount": self.nat(), "currency": self.text(), **self.dates()}}
        if tag == 0xBB:
            return {"presentCollection": {"instrument": self.nat(), "presentedOn": self.nat()}}
        if tag == 0xBC:
            return {"acceptCollection": {"instrument": self.nat()}}
        if tag == 0xBD:
            return {"payCollection": {"instrument": self.nat(), **self.dates()}}
        if tag == 0xBE:
            return {"protestCollection": {"instrument": self.nat(), "reason": self.text()}}
        if tag == 0xBF:
            return {"returnCollection": {"instrument": self.nat(), "reason": self.text(), **self.dates()}}
        if tag == 0x1E:
            return {"discountBill": {"bill": self.trade_bill(), "face": self.nat(), "currency": self.text(), "maturity": self.nat(), **self.dates()}}
        if tag == 0x1F:
            return {"rediscountBill": {"instrument": self.nat(), "to": self.text(), **self.dates()}}
        if tag == 0x2D:
            return {"settleBill": {"instrument": self.nat(), **self.dates()}}
        if tag == 0x2E:
            return {"dishonourBill": {"instrument": self.nat(), **self.dates()}}
        if tag == 0x2F:
            return {"recordTradeMessage": {"instrument": self.nat(), "kind": self.trade_message_kind(), "direction": ["outgoing", "incoming"][self.byte()], "hash": self.blob()}}
        # the extension tag 0xEF with a second byte: 0x01.. Islamic banking (Islamic banking), 0x20.. treasury (treasury)
        if tag == 0xEF:
            sub = self.byte()
            if sub >= 0x50:
                return self.currency_command(sub)
            if sub >= 0x30:
                return self.card_command(sub)
            if sub >= 0x20:
                return self.treasury_command(sub)
            return self.islamic_command(sub)
        if tag == 0xD4:
            return {"openPacking": {"period": self.text()}}
        if tag == 0xD5:
            return {"rollPackToArchive": {"pack": self.nat(), "cid": self.nat64(), "archive": self.principal()}}
        if tag == 0xD6:
            return {"declareShardRule": {"self": self.nat(), "shards": self.shards()}}
        if tag == 0xD7:
            return {"openShardTransfer": {"from": self.nat(), "toIdentifier": self.text(), "amount": self.nat(), "postingDate": self.nat(),
                                          "valueDate": self.nat(), "period": self.text(), "narration": self.text()}}
        if tag == 0xD8:
            return {"declareScheme": {"id": self.text(), "granularity": ["gross", "net"][self.byte()], "interchange": ["bilateral", "multilateral"][self.byte()],
                                      "delay": ["immediate", "deferred"][self.byte()], "reconciliation": self.text(), "feeIncome": self.text(),
                                      "interchangeBps": self.nat(), "hubFeeBps": self.nat(), "alarmPercent": self.nat()}}
        if tag == 0xD9:
            return {"registerParticipant": {"party": self.nat(), "bic": self.text(), "scheme": self.text(), "accounts": self.participant_accounts()}}
        if tag == 0xDA:
            return {"deactivateParticipant": {"participant": self.nat()}}
        if tag == 0xDB:
            return {"recordFunds": {"participant": self.nat(), "currency": self.text(), "amount": self.nat(), "direction": ["in", "out"][self.byte()],
                                    "postingDate": self.nat(), "valueDate": self.nat(), "period": self.text(), "narration": self.text()}}
        if tag == 0xDC:
            return {"prepareTransfer": {"scheme": self.text(), "payer": self.nat(), "payee": self.nat(), "currency": self.text(), "amount": self.nat(),
                                        "reference": self.text(), "ttlSeconds": self.nat()}}
        if tag == 0xDD:
            return {"fulfilTransfer": {"transfer": self.nat()}}
        if tag == 0xDE:
            return {"rejectTransfer": {"transfer": self.nat(), "reason": self.text()}}
        if tag == 0xDF:
            return {"errorTransfer": {"transfer": self.nat(), "reason": self.text()}}
        if tag == 0xE0:
            return {"openSettlementWindow": {"scheme": self.text(), "businessDate": self.nat()}}
        if tag == 0xE1:
            return {"closeSettlementWindow": {"window": self.nat()}}
        if tag == 0xE2:
            return {"openSettlement": {"window": self.nat()}}
        if tag == 0xE3:
            return {"abortSettlement": {"settlement": self.nat(), "reason": self.text()}}
        if tag == 0xE4:
            scheme, payer, reference, ttl = self.text(), self.nat(), self.text(), self.nat()
            n = self.len16()
            return {"receiveBulk": {"scheme": scheme, "payer": payer, "reference": reference, "ttlSeconds": ttl,
                                    "requests": [{"payee": self.nat(), "currency": self.text(), "amount": self.nat(), "reference": self.text()} for _ in range(n)]}}
        if tag == 0xE5:
            return {"fulfilBulk": {"bulk": self.nat()}}
        if tag == 0xE6:
            return {"rejectBulk": {"bulk": self.nat(), "reason": self.text()}}
        # ISO 20022 messaging: 0xE7–0xEA
        if tag == 0xE7:
            return {"declareRail": {"id": self.text(), "scheme": self.text(), "ttlSeconds": self.nat(), "hold": self.hold_rules(), "signatures": self.sig_scheme()}}
        if tag == 0xE8:
            return {"registerConnectorKey": {"rail": self.text(), "bic": self.text(), "scheme": self.sig_scheme(), "publicKey": self.blob()}}
        if tag == 0xE9:
            return {"releaseHold": {"transfer": self.nat(), "reason": self.text()}}
        if tag == 0xEA:
            return {"rejectHold": {"transfer": self.nat(), "reason": self.text()}}
        # FSPIOP interoperability: 0xEB
        if tag == 0xEB:
            return {"declareFspiopParticipant": {"rail": self.text(), "participant": self.nat(), "fspId": self.text(), "endpoints": self.text_pairs()}}
        # the declared the extended target list list: 0xEC–0xEE
        if tag == 0xEC:
            return {"grantDebitAuthority": {"rail": self.text(), "debtor": self.nat(), "creditorBic": self.text(), "currency": self.text(), "maxAmount": self.nat()}}
        if tag == 0xED:
            return {"revokeDebitAuthority": {"rail": self.text(), "debtor": self.nat(), "creditorBic": self.text(), "currency": self.text()}}
        if tag == 0xEE:
            return {"decideMandate": {"rail": self.text(), "mandateId": self.text(), "accepted": self.bool(), "reason": self.opt_text()}}
        raise ValueError(f"unknown command tag {tag:#x}")

    SIG_SCHEMES = ["none", "mayo2", "mldsa44"]
    FAMILIES = {0: "unknown", 1: "pacs.008.001.08", 2: "pacs.009.001.08", 3: "pacs.002.001.10", 4: "pacs.004.001.09", 5: "camt.053.001.08", 6: "camt.054.001.08", 7: "head.001.001.02",
                8: "pacs.003.001.08", 9: "pacs.007.001.10", 10: "pacs.010.001.04", 11: "pacs.029.001.02", 12: "pain.007.001.10", 13: "pain.009.001.07", 14: "pain.010.001.07", 15: "pain.011.001.07", 16: "pain.012.001.07",
                17: "camt.052.001.08", 18: "camt.057.001.06", 19: "camt.060.001.05", 20: "camt.050.001.05", 21: "camt.025.001.05", 22: "camt.026.001.07", 23: "camt.027.001.07", 24: "camt.028.001.09", 25: "camt.087.001.06",
                26: "admi.006.001.01", 27: "admi.007.001.01", 28: "admi.017.001.01", 29: "head.002.001.01"}
    VERDICTS = {1: "accepted", 2: "refused", 3: "held"}

    def sig_scheme(self):
        return self.SIG_SCHEMES[self.byte()]

    def bool(self):
        b = self.byte()
        assert b in (0, 1), f"bad boolean byte {b}"
        return b == 1

    def hold_rules(self):
        n = self.len16()
        above = [(self.text(), self.nat()) for _ in range(n)]
        return {"holdAbove": above, "blockedBics": self.texts(), "blockedNameFragments": self.texts()}

    def issues(self):
        n = self.nat()
        return [{"rule": self.text(), "path": self.text(), "detail": self.text()} for _ in range(n)]

    def outcomes(self):
        out = []
        for _ in range(self.nat()):
            t = self.byte()
            if t == 1:
                out.append({"prepared": {"uetr": self.text(), "transfer": self.nat(), "reserved": self.bool()}})
            elif t == 2:
                out.append({"held": {"uetr": self.text(), "transfer": self.nat(), "rule": self.text()}})
            elif t == 3:
                out.append({"fulfilled": {"uetr": self.text(), "transfer": self.nat()}})
            elif t == 4:
                out.append({"rejected": {"uetr": self.text(), "transfer": self.nat(), "reason": self.text()}})
            elif t == 5:
                out.append({"acknowledged": {"uetr": self.text(), "transfer": self.nat(), "status": self.text()}})
            elif t == 6:
                out.append({"returned": {"uetr": self.text(), "original": self.nat(), "transfer": self.nat(), "reserved": self.bool(), "committed": self.bool()}})
            elif t == 7:
                has = self.byte()
                uetr = self.text() if has == 1 else None
                out.append({"refused": {"uetr": uetr, "rule": self.text(), "detail": self.text()}})
            # the extended target list: tags 8–22
            elif t == 8:
                out.append({"reversed": {"uetr": self.text(), "original": self.nat(), "transfer": self.nat(), "reserved": self.bool(), "committed": self.bool(), "reason": self.text()}})
            elif t == 9:
                out.append({"mandateInitiated": {"mandate": self.nat(), "mandateId": self.text(), "creditorAgent": self.text(), "debtorAgent": self.text(), "debtorAccount": self.text(), "sequence": self.text(), "maxAmount": self.opt_nat(), "currency": self.opt_text()}})
            elif t == 10:
                out.append({"mandateAmended": {"mandate": self.nat(), "mandateId": self.text(), "maxAmount": self.opt_nat(), "currency": self.opt_text(), "debtorAccount": self.text(), "reason": self.text()}})
            elif t == 11:
                out.append({"mandateCancelled": {"mandate": self.nat(), "mandateId": self.text(), "reason": self.text()}})
            elif t == 12:
                out.append({"mandateAccepted": {"mandate": self.nat(), "mandateId": self.text(), "accepted": self.bool(), "reason": self.opt_text()}})
            elif t == 13:
                out.append({"collected": {"uetr": self.text(), "transfer": self.nat(), "reserved": self.bool(), "authority": self.nat(), "final": self.bool()}})
            elif t == 14:
                window, settlement, cycle = self.nat(), self.nat(), self.text()
                n = self.len16()
                out.append({"settlementRequested": {"window": window, "settlement": settlement, "cycle": cycle, "movements": [{"participantBic": self.text(), "currency": self.text(), "amount": self.nat(), "debit": self.bool()} for _ in range(n)]}})
            elif t == 15:
                out.append({"reportRequested": {"requestId": self.text(), "kind": self.text(), "account": self.opt_nat(), "fromDay": self.opt_nat(), "toDay": self.opt_nat()}})
            elif t == 16:
                out.append({"receiptExpected": {"notificationId": self.text(), "itemId": self.text(), "reference": self.text(), "amount": self.nat(), "currency": self.text(), "account": self.opt_nat()}})
            elif t == 17:
                out.append({"receiptMatched": {"notification": self.nat(), "itemId": self.text(), "transfer": self.nat()}})
            elif t == 18:
                out.append({"liquidityTransferred": {"endToEndId": self.text(), "participant": self.nat(), "currency": self.text(), "amount": self.nat(), "toPosition": self.bool(), "posting": self.nat()}})
            elif t == 19:
                out.append({"caseRecorded": {"caseId": self.text(), "assignmentId": self.text(), "kind": self.text(), "uetr": self.opt_text(), "transfer": self.opt_nat()}})
            elif t == 20:
                out.append({"resendRequested": {"reference": self.text(), "messageName": self.opt_text(), "message": self.opt_nat()}})
            elif t == 21:
                out.append({"processingRequested": {"requestType": self.text(), "session": self.opt_text()}})
            elif t == 22:
                out.append({"fileReceived": {"payloadId": self.text(), "declared": self.nat(), "messages": self.nat_list()}})
            else:
                raise ValueError(f"unknown outcome tag {t}")
        return out

    def payments_event(self):
        sub = self.byte()
        if sub == 0x01:
            return {"railDeclared": {"id": self.text(), "scheme": self.text(), "ttlSeconds": self.nat(), "hold": self.hold_rules(), "signatures": self.sig_scheme()}}
        if sub == 0x02:
            return {"connectorKeyRegistered": {"rail": self.text(), "bic": self.text(), "scheme": self.sig_scheme(), "publicKey": self.blob()}}
        if sub == 0x03:
            rail, family, message_id, h, nbytes = self.text(), self.FAMILIES[self.byte()], self.text(), self.blob(), self.nat()
            signer = self.text() if self.byte() == 1 else None
            verdict = self.VERDICTS[self.byte()]
            return {"messageReceived": {"rail": rail, "family": family, "messageId": message_id, "hash": h, "bytes": nbytes, "signer": signer,
                                        "verdict": verdict, "issues": self.issues(), "outcomes": self.outcomes()}}
        if sub == 0x04:
            return {"holdReleased": {"transfer": self.nat(), "reason": self.text()}}
        if sub == 0x05:
            return {"holdRejected": {"transfer": self.nat(), "reason": self.text()}}
        # the extended target list
        if sub == 0x06:
            return {"debitAuthorityGranted": {"rail": self.text(), "debtor": self.nat(), "creditorBic": self.text(), "currency": self.text(), "maxAmount": self.nat()}}
        if sub == 0x07:
            return {"debitAuthorityRevoked": {"rail": self.text(), "debtor": self.nat(), "creditorBic": self.text(), "currency": self.text()}}
        if sub == 0x08:
            return {"mandateDecided": {"rail": self.text(), "mandateId": self.text(), "accepted": self.bool(), "reason": self.opt_text()}}
        if sub == 0x09:
            return {"settlementRequestJudged": {"settlement": self.nat(), "matched": self.bool(), "detail": self.text()}}
        raise ValueError(f"unknown payments event sub-tag {sub:#x}")

    def finding(self):
        return {"rule": self.text(), "version": self.nat(), "account": self.nat(), "day": self.nat(),
                "postings": self.nats(), "detail": self.text()}

    # ── collections and recovery (collections and recovery) ──
    STAGES = ["current", "overdue", "delinquent", "default", "collections", "restructuring", "writeOff", "recovery", "closed"]
    REASONS = ["daysPastDue", "unlikelyToPay", "collectionAction", "restructured", "writtenOff", "recovery", "cured", "closed"]

    def stage(self):
        return self.STAGES[self.byte()]

    def collections_policy(self):
        return {"delinquentDpd": self.nat(), "defaultDpd": self.nat(), "suspendInterestFrom": self.stage(), "recogniseModificationLoss": self.byte() == 1}

    def collection_action(self):
        t = self.byte()
        if t == 5:
            return {"other": self.text()}
        return ["call", "letter", "visit", "legalNotice", "fieldAgent"][t]

    def collections_event(self):
        t = self.byte()
        if t == 0x01:
            return {"policySet": self.collections_policy()}
        if t == 0x02:
            return {"stageDerived": {"account": self.nat(), "from": self.stage(), "to": self.stage(), "dpd": self.nat(), "day": self.nat(),
                                     "reason": self.REASONS[self.byte()], "note": self.text()}}
        if t == 0x03:
            return {"actionRecorded": {"account": self.nat(), "action": self.collection_action(), "outcome": self.text(), "next": self.opt(self.nat), "day": self.nat()}}
        if t == 0x04:
            return {"promiseRecorded": {"account": self.nat(), "amount": self.nat(), "by": self.nat(), "day": self.nat(), "baseline": self.nat()}}
        if t == 0x05:
            return {"promiseJudged": {"account": self.nat(), "amount": self.nat(), "by": self.nat(), "kept": self.byte() == 1, "day": self.nat()}}
        if t == 0x06:
            return {"collectorAssigned": {"account": self.nat(), "staff": self.principal()}}
        if t == 0x07:
            return {"interestSuspended": {"account": self.nat(), "amount": self.nat(), "day": self.nat()}}
        if t == 0x08:
            return {"suspenseReleased": {"account": self.nat(), "amount": self.nat(), "day": self.nat()}}
        raise ValueError(f"unknown collections event tag {t:#x}")

    # ── origination and underwriting (origination and underwriting) ──
    APPLICATION_STAGES = ["capture", "assessed", "scored", "underwritten", "offered", "accepted", "documented", "fulfilled", "declined", "withdrawn", "expired"]
    SCHEMES = ["none", "mayo2", "mldsa44"]
    ATTRIBUTES = ["income", "obligationsRatioBps", "bureauScore", "bureauFlags", "termDays", "amount"]
    BANDS = ["approve", "refer", "decline"]

    def origination_policy(self):
        rp, origin, validity = self.text(), self.text(), self.nat()
        n = self.len16()
        bureaus = [(self.text(), self.SCHEMES[self.byte()], self.blob()) for _ in range(n)]
        return {"rpId": rp, "origin": origin, "offerValidityDays": validity, "bureaus": bureaus}

    def affordability_model(self):
        mid, version, n = self.text(), self.nat(), self.len16()
        rules = []
        for _ in range(n):
            rid = self.text()
            kind = ["maxDebtServiceRatioBps", "minResidualIncome", "maxTermDays", "maxAmount", "minIncome"][self.byte()]
            value = self.nat()
            rules.append({"id": rid, "kind": {kind: value}, "onFail": ["fail", "refer"][self.byte()]})
        return {"id": mid, "version": version, "rules": rules}

    def scorecard(self):
        cid, version, n = self.text(), self.nat(), self.len16()
        attributes = []
        for _ in range(n):
            attr = self.ATTRIBUTES[self.byte()]
            m = self.len16()
            bands = [{"lo": self.nat(), "hi": self.opt_nat(), "points": self.nat()} for _ in range(m)]
            attributes.append((attr, bands))
        return {"id": cid, "version": version, "attributes": attributes, "declineBelow": self.nat(), "referBelow": self.nat()}

    def credit_request(self):
        return {"product": self.text(), "amount": self.nat(), "currency": self.text(), "termDays": self.nat(), "purpose": self.text()}

    def facts(self):
        return {"income": self.nat(), "obligations": self.nat(), "proposedInstalment": self.nat(), "dependants": self.nat()}

    def commitments(self):
        n = self.len16()
        return [(self.text(), self.blob()) for _ in range(n)]

    def verdict(self):
        t = self.byte()
        if t == 0:
            return "pass"
        return {["fail", "refer"][t - 1]: self.texts()}

    def bureau_report(self):
        return {"bureau": self.text(), "score": self.nat(), "flags": self.texts(), "reportHash": self.blob(), "reportedOn": self.nat()}

    def decision(self):
        t = self.byte()
        if t == 0:
            return {"approve": {"amount": self.nat(), "termDays": self.nat(), "rateBps": self.nat(), "conditions": self.texts()}}
        if t == 1:
            return {"decline": {"reasons": self.texts()}}
        if t == 2:
            return {"refer": {"to": self.text()}}
        raise ValueError(f"unknown decision tag {t}")

    def offer_terms(self):
        return {"amount": self.nat(), "termDays": self.nat(), "rateBps": self.nat(), "product": self.text(), "currency": self.text(), "conditions": self.texts()}

    def assertion(self):
        return {"credentialId": self.blob(), "authenticatorData": self.blob(), "clientDataJSON": self.blob(), "signature": self.blob()}

    def document_kind(self):
        t = self.byte()
        if t == 4:
            return {"other": self.text()}
        return ["facilityAgreement", "collateralPledge", "insurance", "guarantee"][t]

    def origination_event(self):
        t = self.byte()
        if t == 0x01:
            return {"policySet": self.origination_policy()}
        if t == 0x02:
            return {"affordabilityModelSet": self.affordability_model()}
        if t == 0x03:
            return {"scorecardSet": self.scorecard()}
        if t == 0x04:
            return {"passkeyRegistered": {"party": self.nat(), "credentialId": self.blob(), "publicKeySpki": self.blob()}}
        if t == 0x05:
            return {"applicationOpened": {"party": self.opt_nat(), "book": self.text(), "request": self.credit_request(), "channel": self.text(), "day": self.nat()}}
        if t == 0x06:
            return {"dataRecorded": {"application": self.nat(), "facts": self.facts(), "commitments": self.commitments()}}
        if t == 0x07:
            return {"affordabilityAssessed": {"application": self.nat(), "model": self.text(), "version": self.nat(), "verdict": self.verdict()}}
        if t == 0x08:
            return {"bureauRequested": {"application": self.nat(), "bureau": self.text(), "consentCommit": self.blob(), "day": self.nat()}}
        if t == 0x09:
            return {"bureauRecorded": {"application": self.nat(), "report": self.bureau_report()}}
        if t == 0x0A:
            return {"scored": {"application": self.nat(), "scorecard": self.text(), "version": self.nat(), "points": self.nat(), "band": self.BANDS[self.byte()]}}
        if t == 0x0B:
            return {"underwritten": {"application": self.nat(), "decision": self.decision(), "rationale": self.text(), "overrode": self.byte() == 1}}
        if t == 0x0C:
            return {"offerIssued": {"application": self.nat(), "terms": self.offer_terms(), "offerHash": self.blob(), "expiresAt": self.nat()}}
        if t == 0x0D:
            return {"offerAccepted": {"application": self.nat(), "credentialId": self.blob(), "assertionHash": self.blob(), "day": self.nat()}}
        if t == 0x0E:
            return {"offerDeclined": {"application": self.nat(), "day": self.nat()}}
        if t == 0x0F:
            return {"offerExpired": {"application": self.nat(), "day": self.nat()}}
        if t == 0x10:
            return {"documentRecorded": {"application": self.nat(), "kind": self.document_kind(), "sha256": self.blob(), "signed": self.byte() == 1}}
        if t == 0x11:
            return {"conditionsMet": {"application": self.nat(), "conditions": self.texts(), "outstanding": self.nat()}}
        if t == 0x12:
            return {"documentationComplete": {"application": self.nat(), "day": self.nat()}}
        if t == 0x13:
            return {"prospectOnboarded": {"application": self.nat(), "party": self.nat()}}
        if t == 0x14:
            return {"fulfilled": {"application": self.nat(), "party": self.nat(), "account": self.nat(), "day": self.nat()}}
        if t == 0x15:
            return {"withdrawn": {"application": self.nat(), "reason": self.text(), "day": self.nat()}}
        raise ValueError(f"unknown origination event tag {t:#x}")

    # ── corporate lending (corporate lending) ──
    FACILITY_KINDS = ["bilateralTerm", "revolving", "syndicatedAgent", "syndicatedParticipant", "financeLease", "operatingLease", "factoring", "forfaiting"]

    def dates(self):
        return {"postingDate": self.nat(), "valueDate": self.nat(), "period": self.text(), "narration": self.text()}

    def facility_money(self):
        return {"facility": self.nat(), "amount": self.nat(), "funding": self.p_funding(), **self.dates()}

    def pricing(self):
        t = self.byte()
        if t == 0:
            return {"fixed": self.nat()}
        return {"floating": {"index": self.text(), "spreadBps": self.nat(), "resetDays": self.nat()}}

    def shares(self):
        n = self.len16()
        return [{"participant": self.nat(), "bps": self.nat()} for _ in range(n)]

    def facility_kind(self):
        t = self.byte()
        k = self.FACILITY_KINDS[t]
        if k == "bilateralTerm":
            return {"bilateralTerm": None}
        if k == "revolving":
            fee = self.nat()
            clean = None if self.byte() == 0 else {"everyDays": self.nat(), "forDays": self.nat()}
            return {"revolving": {"commitmentFeeBps": fee, "cleanDown": clean}}
        if k == "syndicatedAgent":
            return {"syndicatedAgent": {"shares": self.shares(), "agentFeeBps": self.nat()}}
        if k == "syndicatedParticipant":
            return {"syndicatedParticipant": {"agent": self.text(), "agentScheme": self.SCHEMES[self.byte()], "agentKey": self.blob(), "agentAccount": self.text(), "ourBps": self.nat()}}
        if k == "financeLease":
            return {"financeLease": {"assetAccount": self.text(), "residual": self.nat()}}
        if k == "operatingLease":
            return {"operatingLease": {"rentalPerPeriod": self.nat(), "every": self.p_period(), "periods": self.nat()}}
        if k == "factoring":
            return {"factoring": {"advanceBps": self.nat(), "discountBps": self.nat(), "recourse": self.byte() == 1, "clientAccount": self.nat()}}
        return {"forfaiting": {"discountBps": self.nat(), "clientAccount": self.nat()}}

    def covenants(self):
        n = self.len16()
        out = []
        for _ in range(n):
            cid = self.text()
            t = self.byte()
            if t == 0:
                kind = {"financialRatio": {"name": self.text(), "op": ["atMost", "atLeast"][self.byte()], "thresholdBps": self.nat()}}
            elif t == 1:
                kind = {"reporting": {"due": self.nat()}}
            else:
                kind = "negativePledge"
            out.append({"id": cid, "kind": kind})
        return out

    def facility_terms(self):
        return {"party": self.nat(), "book": self.text(), "product": self.text(), "kind": self.facility_kind(), "currency": self.text(), "limit": self.nat(),
                "availabilityFrom": self.nat(), "availabilityTo": self.nat(), "pricing": self.pricing(), "covenants": self.covenants(),
                "collateral": self.nats(), "reviewEvery": self.opt_nat()}

    def receivables(self):
        n = self.len16()
        return [{"ref": self.blob(), "debtorCommit": self.blob(), "face": self.nat(), "due": self.nat()} for _ in range(n)]

    def agent_notice(self):
        t = self.byte()
        body = {"drawing": self.text(), "total": self.nat(), "ourShare": self.nat(), "valueDate": self.nat()}
        return {["drawdown", "repayment", "interestDistribution"][t]: body}

    def restructure_terms(self):
        return {"schedule": self.p_schedule_terms(), "rateBps": self.nat()}

    def pairs(self):
        n = self.len16()
        return [(self.nat(), self.nat()) for _ in range(n)]

    def facility_event(self):
        t = self.byte()
        if t == 0x01:
            return {"facilityOpened": {"terms": self.facility_terms(), "day": self.nat()}}
        if t == 0x02:
            return {"drawn": {"facility": self.nat(), "account": self.nat(), "amount": self.nat(), "rateBps": self.nat(), "day": self.nat(), "splits": self.pairs()}}
        if t == 0x03:
            return {"drawingRepaid": {"facility": self.nat(), "account": self.nat(), "amount": self.nat(), "day": self.nat(), "interestShared": self.pairs()}}
        if t == 0x04:
            return {"commitmentFeeAccrued": {"facility": self.nat(), "day": self.nat(), "undrawn": self.nat(), "amount": self.nat()}}
        if t == 0x05:
            return {"cleanDownJudged": {"facility": self.nat(), "windowEnd": self.nat(), "cleanDays": self.nat(), "required": self.nat(), "met": self.byte() == 1}}
        if t == 0x06:
            return {"participationTransferred": {"facility": self.nat(), "from": self.nat(), "to": self.nat(), "bps": self.nat(), "moved": self.nat()}}
        if t == 0x07:
            return {"distributedToParticipants": {"facility": self.nat(), "day": self.nat(), "amounts": self.pairs()}}
        if t == 0x08:
            return {"agentNoticeRecorded": {"facility": self.nat(), "notice": self.agent_notice(), "noticeHash": self.blob(), "account": self.opt_nat()}}
        if t == 0x09:
            return {"facilityRestructured": {"facility": self.nat(), "terms": self.restructure_terms(), "effective": self.nat(), "drawings": self.nats()}}
        if t == 0x0A:
            return {"drawingRepriced": {"facility": self.nat(), "account": self.nat(), "day": self.nat(), "rateBps": self.nat(), "fixing": self.nat()}}
        if t == 0x0B:
            return {"covenantTested": {"facility": self.nat(), "covenant": self.text(), "value": self.nat(), "met": self.byte() == 1, "statementHash": self.blob(), "day": self.nat()}}
        if t == 0x0C:
            return {"drawdownsBlocked": {"facility": self.nat(), "reason": self.text(), "day": self.nat()}}
        if t == 0x0D:
            return {"drawdownsUnblocked": {"facility": self.nat(), "reason": self.text(), "day": self.nat()}}
        if t == 0x0E:
            return {"reviewRecorded": {"facility": self.nat(), "day": self.nat(), "nextDue": self.opt_nat(), "note": self.text()}}
        if t == 0x0F:
            return {"reviewOverdue": {"facility": self.nat(), "due": self.nat(), "day": self.nat()}}
        if t == 0x10:
            return {"leaseRentalAccrued": {"facility": self.nat(), "day": self.nat(), "amount": self.nat()}}
        if t == 0x11:
            return {"rentalReceived": {"facility": self.nat(), "amount": self.nat(), "day": self.nat()}}
        if t == 0x12:
            return {"residualRemeasured": {"facility": self.nat(), "from": self.nat(), "to": self.nat(), "day": self.nat()}}
        if t == 0x13:
            return {"receivablesPurchased": {"facility": self.nat(), "receivables": self.receivables(), "face": self.nat(), "advance": self.nat(), "discount": self.nat(), "retention": self.nat(), "day": self.nat()}}
        if t == 0x14:
            f, d, amount = self.nat(), self.nat(), self.nat()
            n = self.len16()
            return {"discountUnwound": {"facility": f, "day": d, "amount": amount, "items": [(self.blob(), self.nat()) for _ in range(n)]}}
        if t == 0x15:
            return {"receivableCollected": {"facility": self.nat(), "ref": self.blob(), "amount": self.nat(), "retentionReleased": self.nat(), "day": self.nat()}}
        if t == 0x16:
            return {"receivableDishonoured": {"facility": self.nat(), "ref": self.blob(), "face": self.nat(), "chargedBack": self.byte() == 1, "day": self.nat()}}
        if t == 0x17:
            return {"receivableWrittenOff": {"facility": self.nat(), "ref": self.blob(), "amount": self.nat(), "day": self.nat()}}
        if t == 0x18:
            return {"drawingClosed": {"facility": self.nat(), "account": self.nat(), "day": self.nat()}}
        if t == 0x19:
            return {"rateFixingRecorded": {"index": self.text(), "day": self.nat(), "rateBps": self.nat()}}
        if t == 0x1A:
            return {"facilityClosed": {"facility": self.nat(), "day": self.nat()}}
        raise ValueError(f"unknown facility event tag {t:#x}")

    # ── Islamic banking (Islamic banking) ──
    ISLAMIC_POLICY = ["murabahaInventory", "murabahaReceivable", "deferredProfit", "murabahaIncome", "securityDeposits", "ijarahAssets", "accumulatedDepreciation", "depreciationExpense",
                      "rentalReceivable", "ijarahIncome", "musharakahInvestment", "musharakahIncome", "mudarabahInvestment", "mudarabahIncome", "investmentLosses", "salamReceivable",
                      "salamInventory", "salamIncome", "istisnaWip", "istisnaReceivable", "istisnaRevenue", "istisnaCosts", "iahEquity", "profitEqualisationReserve", "investmentRiskReserve",
                      "profitPayableToHolders", "mudaribShareIncome", "profitAttributableToHolders", "charityPayable", "nostro"]

    def islamic_policy(self):
        out = {n: self.text() for n in self.ISLAMIC_POLICY}
        out["perCeilingBps"] = self.nat(); out["irrCeilingBps"] = self.nat()
        return out

    def islamic_approval(self):
        return {"ref": self.text(), "sha256": self.blob()}

    def islamic_counterparty(self):
        t = self.byte()
        if t == 0:
            return {"party": {"party": self.nat(), "account": self.nat()}}
        return {"external": {"name": self.text(), "reference": self.text()}}

    def period_(self):
        return ["daily", "monthly", "quarterly", "semiAnnual", "annual", "atMaturity"][self.byte()]

    def islamic_transfer_opt(self):
        t = self.byte()
        if t == 0:
            return None
        if t == 1:
            return "gift"
        if t == 2:
            return {"sale": {"price": self.nat()}}
        return {"gradual": {"units": self.nat()}}

    def islamic_kind(self):
        t = self.byte()
        if t == 1:
            out = {"customer": self.nat(), "account": self.nat(), "asset": self.text(), "supplier": self.islamic_counterparty(), "costPrice": self.nat(), "markup": self.nat(), "instalments": self.nat(), "every": self.period_()}
            out["method"] = ["proportionate", "effectiveRate"][self.byte()]; out["promise"] = ["nonBinding", "binding"][self.byte()]
            out.update({"securityDeposit": self.nat(), "latePaymentCharityBps": self.nat(), "reference": self.text()})
            return {"murabaha": out}
        if t == 2:
            return {"ijarah": {"lessee": self.nat(), "account": self.nat(), "asset": self.text(), "cost": self.nat(), "usefulLifeMonths": self.nat(), "residual": self.nat(), "rental": self.nat(), "every": self.period_(),
                               "periods": self.nat(), "transfer": self.islamic_transfer_opt(), "reference": self.text()}}
        if t == 3:
            partners = [{"party": self.nat(), "account": self.nat(), "capital": self.nat(), "profitBps": self.nat()} for _ in range(self.len16())]
            out = {"partners": partners, "bankCapital": self.nat(), "bankProfitBps": self.nat()}
            d = self.byte()
            out["diminishing"] = None if d == 0 else {"units": self.nat(), "unitPrice": self.nat(), "every": self.period_(), "rentalBps": self.nat()}
            out["reference"] = self.text()
            return {"musharakah": out}
        if t == 4:
            return {"mudarabah": {"mudarib": self.nat(), "account": self.nat(), "capital": self.nat(), "bankProfitBps": self.nat(), "term": self.nat(), "reference": self.text()}}
        if t == 5:
            return {"salam": {"seller": self.nat(), "account": self.nat(), "commodity": self.text(), "quantity": self.nat(), "unit": self.text(), "delivery": self.nat(), "priceAdvanced": self.nat(), "reference": self.text()}}
        if t == 6:
            return {"istisna": {"customer": self.nat(), "account": self.nat(), "specification": self.blob(), "price": self.nat(), "estimatedCost": self.nat(), "milestones": self.pairs(), "contractor": self.islamic_counterparty(), "reference": self.text()}}
        raise ValueError(f"unknown contract kind {t}")

    def islamic_pool(self):
        return {"id": self.text(), "currency": self.text(), "mudaribBps": self.nat(), "perBps": self.nat(), "irrBps": self.nat(), "product": self.text(), "incomeAccounts": self.texts()}

    def islamic_distribution(self):
        return {"pool": self.text(), "period": self.text(), "from": self.nat(), "to": self.nat(), "income": self.nat(), "per": self.nat(), "distributable": self.nat(), "mudaribShare": self.nat(),
                "holdersShare": self.nat(), "irr": self.nat(), "paid": self.nat(), "weightedBalances": self.pairs(), "allocations": self.pairs()}

    def islamic_command(self, sub):
        D = self.dates
        if sub == 0x01:
            return {"setIslamicPolicy": self.islamic_policy()}
        if sub == 0x02:
            return {"approveShariaProduct": {"product": self.text(), "approval": self.islamic_approval()}}
        if sub == 0x03:
            return {"flagShariaBook": {"book": self.text(), "sharia": self.bool()}}
        if sub == 0x04:
            return {"openShariaContract": {"kind": self.islamic_kind(), "currency": self.text(), **D()}}
        simple = {0x05: "acquireMurabahaAsset", 0x06: "sellMurabaha", 0x07: "collectInstalment", 0x09: "commenceIjarah", 0x0A: "collectRental", 0x0B: "transferIjarahOwnership",
                  0x0C: "contributeCapital", 0x15: "collectIstisnaBilling", 0x16: "settleShariaContract"}
        if sub in simple:
            return {simple[sub]: {"contract": self.nat(), **D()}}
        if sub == 0x08:
            return {"grantRebate": {"contract": self.nat(), "amount": self.nat(), "reason": self.text(), **D()}}
        if sub == 0x0D:
            return {"distributeMusharakahProfit": {"contract": self.nat(), "profit": self.nat(), **D()}}
        if sub == 0x0E:
            c = self.nat(); loss = self.nat(); f = self.byte()
            offered = None if f == 0 else self.pairs()
            return {"allocateMusharakahLoss": {"contract": c, "loss": loss, "offered": offered, **D()}}
        if sub == 0x0F:
            return {"buyMusharakahUnit": {"contract": self.nat(), "units": self.nat(), **D()}}
        if sub == 0x10:
            return {"recordMudarabahResult": {"contract": self.nat(), "profit": self.nat(), "loss": self.nat(), **D()}}
        if sub == 0x11:
            return {"deliverSalam": {"contract": self.nat(), "quantity": self.nat(), **D()}}
        if sub == 0x12:
            return {"sellSalamCommodity": {"contract": self.nat(), "proceeds": self.nat(), **D()}}
        if sub == 0x13:
            return {"recordSalamFailure": {"contract": self.nat(), "recourse": self.text(), **D()}}
        if sub == 0x14:
            return {"recordIstisnaMilestone": {"contract": self.nat(), "certificate": self.blob(), "percentBps": self.nat(), **D()}}
        if sub == 0x17:
            return {"closeShariaContract": {"contract": self.nat(), "reason": self.text()}}
        if sub == 0x18:
            return {"recordNonCompliance": {"contract": self.opt_nat(), "amount": self.nat(), "account": self.text(), "reason": self.text(), **D()}}
        if sub == 0x19:
            return {"openInvestmentPool": {"pool": self.islamic_pool()}}
        if sub == 0x1A:
            return {"updatePoolReserves": {"pool": self.text(), "per": self.opt_nat(), "irr": self.opt_nat()}}
        if sub == 0x1B:
            return {"distributePool": {"pool": self.text(), "month": self.text(), "from": self.nat(), "to": self.nat(), **D()}}
        raise ValueError(f"unknown Islamic command sub-tag {sub:#x}")

    # ── treasury (treasury) ──
    TREASURY_POLICY = ["mmPlacements", "mmTakings", "mmInterestReceivable", "mmInterestPayable", "mmInterestIncome", "mmInterestExpense", "fxForwardMark", "irsMark", "fxOptionValue",
                       "unrealisedTradingGain", "unrealisedTradingLoss", "realisedTradingGain", "realisedTradingLoss", "securitiesAmortisedCost", "securitiesFvoci", "securitiesFvtpl", "fvociReserve",
                       "couponReceivable", "couponIncome", "amortisationIncome", "amortisationExpense", "nostroSuspense"]
    CURVE_KINDS = ["zeroRates", "forwardPoints", "volatility", "securityPrice"]
    LIMIT_KINDS = ["counterpartyExposure", "openFxPosition", "tenorBucket", "dv01", "stopLoss", "issuerConcentration"]

    def t_policy(self):
        out = {k: self.text() for k in self.TREASURY_POLICY}
        out["lotMethod"] = ["fifo", "averageCost"][self.byte()]
        out["confirmationDueDays"] = self.nat(); out["breakAgeAlertDays"] = self.nat(); out["maxCurvePoints"] = self.nat()
        return out

    def t_points(self):
        n = self.len16()
        return [(self.nat(), self.int_()) for _ in range(n)]

    def t_nats(self):
        n = self.len16()
        return [self.nat() for _ in range(n)]

    def t_opt_text(self):
        b = self.byte()
        assert b in (0, 1)
        return self.text() if b == 1 else None

    def t_opt_principal(self):
        b = self.byte()
        assert b in (0, 1)
        return self.principal() if b == 1 else None

    def t_counterparty(self):
        return {"party": self.opt_nat(), "name": self.text(), "bic": self.text(), "lei": self.text()}

    def t_cash(self):
        return {"account": self.text(), "sub": self.t_opt_text()}

    def t_security_terms(self):
        return {"isin": self.text(), "issuer": self.text(), "currency": self.text(), "couponBps": self.nat(), "couponsPerYear": self.nat(), "dayCount": self.p_convention(), "issue": self.nat(), "maturity": self.nat()}

    def t_curve(self):
        return {"id": self.text(), "kind": self.CURVE_KINDS[self.byte()], "currency": self.text(), "day": self.nat(), "points": self.t_points(), "source": self.blob()}

    def t_limit(self):
        return {"book": self.text(), "kind": self.LIMIT_KINDS[self.byte()], "currency": self.text(), "subject": self.text(), "value": self.nat()}

    def t_nostro(self):
        return {"id": self.text(), "account": self.text(), "sub": self.t_opt_text(), "currency": self.text(), "correspondent": self.t_counterparty(), "iban": self.text(), "valueDateToleranceDays": self.nat()}

    def t_forward(self):
        return {"base": self.text(), "quote": self.text(), "direction": ["buy", "sell"][self.byte()], "baseAmount": self.nat(), "rateMicro": self.nat(), "valueDate": self.nat(), "spotMicro": self.nat(),
                "forwardPointsMicro": self.int_(), "baseAccount": self.t_cash(), "quoteAccount": self.t_cash(), "pointsCurve": self.text(), "discountCurve": self.text()}

    def t_kind(self):
        k = self.byte()
        if k == 1:
            return {"moneyMarket": {"placement": self.bool(), "currency": self.text(), "principal": self.nat(), "rateBps": self.nat(), "dayCount": self.p_convention(), "start": self.nat(), "maturity": self.nat(), "cash": self.t_cash()}}
        if k == 2:
            return {"fxForward": self.t_forward()}
        if k == 3:
            return {"fxSwap": {"near": self.t_forward(), "far": self.t_forward()}}
        if k == 4:
            return {"security": {"isin": self.text(), "direction": ["buy", "sell"][self.byte()], "nominal": self.nat(), "priceMicro": self.nat(), "settlement": self.nat(),
                                 "classification": ["amortisedCost", "fvoci", "fvtpl"][self.byte()], "cash": self.t_cash(), "priceCurve": self.text(), "venue": self.t_opt_text()}}
        if k == 5:
            return {"irs": {"currency": self.text(), "notional": self.nat(), "payFixed": self.bool(), "fixedBps": self.nat(), "floatingIndex": self.text(), "spreadBps": self.int_(), "start": self.nat(),
                            "maturity": self.nat(), "paymentMonths": self.nat(), "dayCount": self.p_convention(), "cash": self.t_cash(), "discountCurve": self.text()}}
        if k == 6:
            return {"fxOption": {"base": self.text(), "quote": self.text(), "call": self.bool(), "bought": self.bool(), "baseAmount": self.nat(), "strikeMicro": self.nat(), "expiry": self.nat(), "premium": self.nat(),
                                 "start": self.nat(), "cash": self.t_cash(), "domesticCurve": self.text(), "foreignCurve": self.text(), "volCurve": self.text()}}
        raise ValueError(f"unknown deal kind {k}")

    def t_entries(self):
        n = self.len16()
        return [{"reference": self.text(), "amount": self.nat(), "credit": self.bool(), "valueDay": self.nat(), "bookingDay": self.nat(), "counterparty": self.text()} for _ in range(n)]

    def t_fields(self):
        return {"kind": self.text(), "amount1": self.nat(), "currency1": self.text(), "amount2": self.nat(), "currency2": self.text(), "valueDate": self.nat(), "rateMicro": self.nat(), "counterparty": self.text()}

    def t_opt_fields(self):
        b = self.byte()
        assert b in (0, 1)
        return self.t_fields() if b == 1 else None

    def t_opt_correction(self):
        b = self.byte()
        assert b in (0, 1)
        return {"account": self.text(), "sub": self.t_opt_text(), "debit": self.bool(), "amount": self.nat(), "currency": self.text()} if b == 1 else None

    def opt_blob_(self):
        b = self.byte()
        assert b in (0, 1)
        return self.blob() if b == 1 else None

    def treasury_command(self, sub):
        D = self.dates
        if sub == 0x20:
            return {"setTreasuryPolicy": self.t_policy()}
        if sub == 0x21:
            return {"registerSecurity": {"terms": self.t_security_terms()}}
        if sub == 0x22:
            return {"publishCurve": {"curve": self.t_curve()}}
        if sub == 0x23:
            return {"setTreasuryLimit": {"limit": self.t_limit()}}
        if sub == 0x24:
            return {"registerNostro": {"nostro": self.t_nostro()}}
        if sub == 0x25:
            return {"captureDeal": {"book": self.text(), "counterparty": self.t_counterparty(), "kind": self.t_kind(), "reference": self.text(), "approver": self.t_opt_principal()}}
        if sub == 0x26:
            return {"confirmDeal": {"deal": self.nat(), "confirmation": self.blob(), "fields": self.t_opt_fields(), "document": self.opt_blob_()}}
        if sub == 0x27:
            return {"amendDeal": {"deal": self.nat(), "kind": self.t_kind(), "reason": self.text()}}
        if sub == 0x28:
            return {"cancelDeal": {"deal": self.nat(), "reason": self.text()}}
        if sub == 0x29:
            return {"settleDealLeg": {"deal": self.nat(), "leg": self.nat(), **D()}}
        if sub == 0x2A:
            return {"markDeal": {"deal": self.nat(), **D()}}
        if sub == 0x2B:
            return {"recordNostroStatement": {"nostro": self.text(), "statement": self.blob(), "from": self.nat(), "to": self.nat(), "entries": self.t_entries(), "document": self.opt_blob_()}}
        if sub == 0x2C:
            return {"resolveNostroBreak": {"breakId": self.nat(), "resolution": self.text(), "correction": self.t_opt_correction(), **D()}}
        raise ValueError(f"unknown treasury command byte {sub:#x}")

    def treasury_event(self):
        t = self.byte()
        if t == 0x01:
            return {"policySet": self.t_policy()}
        if t == 0x02:
            return {"securityRegistered": {"terms": self.t_security_terms(), "day": self.nat()}}
        if t == 0x03:
            return {"curvePublished": {"curve": self.t_curve()}}
        if t == 0x04:
            return {"limitSet": {"limit": self.t_limit(), "day": self.nat()}}
        if t == 0x05:
            return {"nostroRegistered": {"nostro": self.t_nostro(), "day": self.nat()}}
        if t == 0x06:
            return {"dealCaptured": {"book": self.text(), "counterparty": self.t_counterparty(), "kind": self.t_kind(), "reference": self.text(), "trader": self.principal(), "day": self.nat(),
                                     "withinLimits": self.bool(), "approver": self.t_opt_principal(), "secondAmount": self.nat()}}
        if t == 0x07:
            return {"limitBreached": {"limit": self.t_limit(), "measured": self.nat(), "deal": self.nat(), "approver": self.principal(), "day": self.nat()}}
        if t == 0x08:
            return {"dealConfirmed": {"deal": self.nat(), "confirmation": self.blob(), "day": self.nat()}}
        if t == 0x09:
            return {"confirmationMismatch": {"deal": self.nat(), "confirmation": self.blob(), "field": self.text(), "ours": self.text(), "theirs": self.text(), "day": self.nat()}}
        if t == 0x0A:
            return {"dealAmended": {"deal": self.nat(), "kind": self.t_kind(), "reason": self.text(), "day": self.nat(), "secondAmount": self.nat()}}
        if t == 0x0B:
            return {"dealCancelled": {"deal": self.nat(), "reason": self.text(), "day": self.nat()}}
        if t == 0x0C:
            return {"legSettled": {"deal": self.nat(), "leg": self.nat(), "amount": self.nat(), "currency": self.text(), "realised": self.int_(), "day": self.nat(), "accrual": self.int_(),
                                   "amortisation": self.int_(), "fv": self.int_(), "nominal": self.nat(), "cost": self.nat()}}
        if t == 0x0D:
            return {"lotConsumed": {"lot": self.nat(), "by": self.nat(), "nominal": self.nat(), "cost": self.nat(), "amortisation": self.int_(), "fv": self.int_(), "accrual": self.int_(), "day": self.nat()}}
        if t == 0x0E:
            return {"accrued": {"deal": self.nat(), "interest": self.int_(), "amortisation": self.int_(), "day": self.nat()}}
        if t == 0x0F:
            return {"marked": {"deal": self.nat(), "value": self.int_(), "previous": self.int_(), "day": self.nat()}}
        if t == 0x10:
            return {"couponPaid": {"deal": self.nat(), "amount": self.nat(), "day": self.nat()}}
        if t == 0x11:
            return {"statementRecorded": {"nostro": self.text(), "statement": self.blob(), "from": self.nat(), "to": self.nat(), "entries": self.nat(), "matches": self.t_nats(), "breaks": self.nat(), "day": self.nat()}}
        if t == 0x12:
            return {"nostroBreak": {"nostro": self.text(), "statement": self.blob(), "side": ["onStatementOnly", "inOurBooksOnly"][self.byte()], "amount": self.nat(), "credit": self.bool(), "valueDay": self.nat(),
                                    "reference": self.text(), "posting": self.opt_nat(), "day": self.nat()}}
        if t == 0x13:
            return {"breakResolved": {"breakId": self.nat(), "resolution": self.text(), "corrected": self.bool(), "day": self.nat()}}
        if t == 0x14:
            return {"breakAged": {"breakId": self.nat(), "ageDays": self.nat(), "day": self.nat()}}
        if t == 0x15:
            return {"confirmationOverdue": {"deal": self.nat(), "ageDays": self.nat(), "day": self.nat()}}
        raise ValueError(f"unknown treasury event tag {t:#x}")

    # ── cards (cards) ──
    CARD_POLICY = ["disputeSuspense", "interchangeIncome", "schemeFees", "fraudLosses", "cardFeeIncome"]
    CARD_DECLINES = [None, "unknownCard", "cardNotActive", "cardBlocked", "cardExpired", "mccDenied", "channelDenied", "internationalDenied", "overPerTransaction", "overDailyLimit", "velocity",
                     "insufficientFunds", "cryptogramInvalid", "pinFailed", "duplicate", "unknownOriginal", "originalNotOpen", "amountExceedsOriginal", "currencyMismatch", "schemeMismatch"]
    CARD_STAGES = ["opened", "provisionalCredit", "chargeback", "representment", "preArbitration", "resolved"]

    def c_policy(self):
        out = {k: self.text() for k in self.CARD_POLICY}
        out["provisionalCreditCeiling"] = self.nat(); out["clearingTolerance"] = self.nat(); out["stanReplayDays"] = self.nat()
        return out

    def c_rules(self):
        source = self.text()
        n = self.len16()
        bands = [{"mccFrom": self.nat(), "mccTo": self.nat(), "bps": self.nat(), "fixed": self.nat()} for _ in range(n)]
        floor = self.nat(); hold = self.nat()
        n = self.len16()
        reasons = [{"code": self.text(), "description": self.text(), "chargebackDays": self.nat(), "representmentDays": self.nat(), "preArbitrationDays": self.nat()} for _ in range(n)]
        return {"source": source, "interchange": bands, "floorLimit": floor, "holdDays": hold, "reasons": reasons, "feeBps": self.nat()}

    def c_sig_scheme(self):
        return ["none", "mayo2", "mldsa44"][self.byte()]

    def c_scheme(self):
        return {"id": self.text(), "name": self.text(), "settlementAccount": self.text(), "settlementCurrency": self.text(), "rules": self.c_rules(), "connectorScheme": self.c_sig_scheme(), "connectorKey": self.blob()}

    def c_channels(self):
        return {"pos": self.bool(), "atm": self.bool(), "ecom": self.bool(), "contactless": self.bool(), "international": self.bool()}

    def c_controls(self):
        return {"dailyLimit": self.nat(), "perTransactionLimit": self.nat(), "mccAllow": self.t_nats(), "mccDeny": self.t_nats(), "channels": self.c_channels(), "velocityCount": self.nat(), "velocityWindowMinutes": self.nat()}

    def c_product(self):
        out = {"id": self.text(), "name": self.text()}
        k = self.byte()
        if k == 0:
            out["kind"] = "debit"
        else:
            out["kind"] = {"credit": {"statementDay": self.nat(), "minimumDueBps": self.nat(), "minimumDueFloor": self.nat(), "graceDays": self.nat()}}
        out.update({"scheme": self.text(), "bounds": self.c_controls(), "issueFee": self.nat(), "replacementFee": self.nat(), "expiryMonths": self.nat()})
        return out

    def c_form(self):
        return ["physical", "virtual"][self.byte()]

    def c_block_reason(self):
        b = self.byte()
        if b == 4:
            return {"bank": self.text()}
        return ["customer", "lost", "stolen", "fraud"][b]

    def c_replace_reason(self):
        return ["lost", "stolen", "damaged", "expired"][self.byte()]

    def c_kind(self):
        k = self.byte()
        if k in (2, 3, 5):
            return {["incremental", "completion", "reversal"][[2, 3, 5].index(k)]: {"of": self.nat()}}
        return ["purchase", "preAuthorization", None, None, "refund"][k]

    def c_request(self):
        domain = self.text()
        assert domain == "THEBES-BANK-CARD-AUTH-v1", domain
        out = {"token": self.blob(), "kind": self.c_kind(), "amount": self.nat(), "currency": self.text(), "mcc": self.nat(), "merchantHash": self.blob(), "merchantCountry": self.text(), "acquirer": self.text(),
               "channel": ["pos", "atm", "ecom", "contactless"][self.byte()], "cryptogramValid": self.bool()}
        b = self.byte()
        out["pinVerified"] = None if b == 0 else (b == 1)
        out["stan"] = self.text(); out["rrn"] = self.text(); out["localTime"] = self.nat64()
        return out

    def c_decision(self):
        b = self.byte()
        if b == 0:
            return {"approved": {"authCode": self.text(), "hold": self.opt_nat(), "amount": self.nat()}}
        return {"declined": self.CARD_DECLINES[self.byte()]}

    def c_item(self):
        return {"authCode": self.t_opt_text(), "token": self.blob(), "amount": self.nat(), "currency": self.text(), "mcc": self.nat(), "merchantHash": self.blob(), "acquirer": self.text(), "stan": self.text(), "rrn": self.text(), "day": self.nat(), "refund": self.bool()}

    def c_outcome(self):
        b = self.byte()
        if b == 0:
            return {"postedAgainstHold": {"auth": self.nat(), "hold": self.nat(), "difference": self.int_()}}
        if b == 1:
            return {"postedDirect": {"belowFloor": self.bool()}}
        return {"exception": {"reason": self.text()}}

    def currency_command(self, sub):
        if sub == 0x50:
            return {"setCurrencyCalendar": {"currency": self.text(), "calendar": self.calendar()}}
        if sub == 0x51:
            return {"redenominateCurrency": self.c_redenomination()}
        raise ValueError(f"unknown currency command sub-tag {sub:#x}")

    def card_command(self, sub):
        D = self.dates
        if sub == 0x30:
            return {"setCardPolicy": self.c_policy()}
        if sub == 0x31:
            return {"declareCardScheme": {"scheme": self.c_scheme()}}
        if sub == 0x32:
            return {"defineCardProduct": {"product": self.c_product()}}
        if sub == 0x33:
            return {"issueCard": {"token": self.blob(), "account": self.nat(), "product": self.text(), "form": self.c_form(), "controls": self.c_controls(), **D()}}
        if sub == 0x34:
            return {"activateCard": {"card": self.nat()}}
        if sub == 0x35:
            return {"blockCard": {"card": self.nat(), "reason": self.c_block_reason()}}
        if sub == 0x36:
            return {"unblockCard": {"card": self.nat()}}
        if sub == 0x37:
            return {"replaceCard": {"card": self.nat(), "newToken": self.blob(), "reason": self.c_replace_reason(), **D()}}
        if sub == 0x38:
            return {"closeCard": {"card": self.nat(), "reason": self.text()}}
        if sub == 0x39:
            return {"setCardControls": {"card": self.nat(), "controls": self.c_controls(), "byCustomer": self.bool()}}
        if sub == 0x3A:
            return {"openDispute": {"transaction": self.nat(), "reason": self.text(), "amount": self.nat()}}
        if sub == 0x3B:
            return {"grantProvisionalCredit": {"dispute": self.nat(), **D()}}
        if sub == 0x3C:
            return {"raiseChargeback": {"dispute": self.nat(), "schemeRef": self.text(), **D()}}
        if sub == 0x3D:
            return {"recordRepresentment": {"dispute": self.nat(), **D()}}
        if sub == 0x3E:
            return {"recordPreArbitration": {"dispute": self.nat()}}
        if sub == 0x3F:
            return {"resolveDispute": {"dispute": self.nat(), "outcome": ["cardholder", "merchant"][self.byte()], "finalAmount": self.nat(), **D()}}
        if sub == 0x40:
            return {"markFraud": {"transaction": self.nat(), "blockCard": self.bool()}}
        raise ValueError(f"unknown card command byte {sub:#x}")

    def card_event(self):
        t = self.byte()
        if t == 0x01:
            return {"policySet": self.c_policy()}
        if t == 0x02:
            return {"schemeDeclared": {"scheme": self.c_scheme(), "day": self.nat()}}
        if t == 0x03:
            return {"productDefined": {"product": self.c_product(), "day": self.nat()}}
        if t == 0x04:
            return {"cardIssued": {"tokenHash": self.blob(), "account": self.nat(), "party": self.nat(), "product": self.text(), "form": self.c_form(), "expiryMonth": self.nat(), "controls": self.c_controls(), "day": self.nat(), "replaces": self.opt_nat()}}
        if t == 0x05:
            return {"cardActivated": {"card": self.nat(), "day": self.nat()}}
        if t == 0x06:
            return {"cardBlocked": {"card": self.nat(), "reason": self.c_block_reason(), "day": self.nat()}}
        if t == 0x07:
            return {"cardUnblocked": {"card": self.nat(), "day": self.nat()}}
        if t == 0x08:
            return {"cardClosed": {"card": self.nat(), "reason": self.text(), "day": self.nat()}}
        if t == 0x09:
            return {"controlsSet": {"card": self.nat(), "controls": self.c_controls(), "byCustomer": self.bool(), "day": self.nat()}}
        if t == 0x0A:
            return {"authorised": {"card": self.opt_nat(), "request": self.c_request(), "decision": self.c_decision(), "day": self.nat()}}
        if t == 0x0B:
            return {"holdAdjusted": {"auth": self.nat(), "from": self.nat(), "to": self.nat(), "hold": self.opt_nat(), "kind": self.text(), "day": self.nat()}}
        if t == 0x0C:
            return {"holdExpired": {"auth": self.nat(), "hold": self.nat(), "day": self.nat()}}
        if t == 0x0D:
            return {"clearingRecorded": {"scheme": self.text(), "batch": self.blob(), "items": self.nat(), "posted": self.nat(), "exceptions": self.nat(), "interchange": self.nat(), "fees": self.nat(), "day": self.nat()}}
        if t == 0x0E:
            return {"cleared": {"scheme": self.text(), "batch": self.blob(), "card": self.opt_nat(), "item": self.c_item(), "outcome": self.c_outcome(), "interchange": self.nat(), "fee": self.nat(), "posting": self.opt_nat(), "day": self.nat()}}
        if t == 0x0F:
            return {"disputeOpened": {"transaction": self.nat(), "card": self.nat(), "reason": self.text(), "amount": self.nat(), "dueDay": self.nat(), "day": self.nat()}}
        if t == 0x10:
            return {"provisionalCredited": {"dispute": self.nat(), "amount": self.nat(), "day": self.nat()}}
        if t == 0x11:
            return {"chargebackRaised": {"dispute": self.nat(), "schemeRef": self.text(), "dueDay": self.nat(), "day": self.nat()}}
        if t == 0x12:
            return {"representmentRecorded": {"dispute": self.nat(), "dueDay": self.nat(), "day": self.nat()}}
        if t == 0x13:
            return {"preArbitrationRecorded": {"dispute": self.nat(), "dueDay": self.nat(), "day": self.nat()}}
        if t == 0x14:
            return {"disputeResolved": {"dispute": self.nat(), "outcome": ["cardholder", "merchant"][self.byte()], "finalAmount": self.nat(), "day": self.nat()}}
        if t == 0x15:
            return {"disputeStepDue": {"dispute": self.nat(), "stage": self.CARD_STAGES[self.byte()], "dueDay": self.nat(), "day": self.nat()}}
        if t == 0x16:
            return {"fraudMarked": {"transaction": self.nat(), "card": self.nat(), "blocked": self.bool(), "day": self.nat()}}
        if t == 0x17:
            return {"statementCut": {"card": self.nat(), "cycleEnd": self.nat(), "balance": self.int_(), "minimumDue": self.nat(), "dueDay": self.nat(), "purchases": self.nat(), "payments": self.nat(), "interest": self.nat(), "day": self.nat()}}
        raise ValueError(f"unknown card event tag {t:#x}")

    def islamic_event(self):
        t = self.byte()
        if t == 0x01:
            return {"policySet": self.islamic_policy()}
        if t == 0x02:
            return {"productApproved": {"product": self.text(), "approval": self.islamic_approval(), "day": self.nat()}}
        if t == 0x03:
            return {"bookFlagged": {"book": self.text(), "sharia": self.bool(), "day": self.nat()}}
        if t == 0x04:
            return {"contractOpened": {"kind": self.islamic_kind(), "currency": self.text(), "book": self.text(), "day": self.nat()}}
        if t == 0x05:
            return {"assetAcquired": {"contract": self.nat(), "cost": self.nat(), "day": self.nat()}}
        if t == 0x06:
            return {"murabahaSold": {"contract": self.nat(), "sellingPrice": self.nat(), "deferredProfit": self.nat(), "schedule": self.pairs(), "day": self.nat()}}
        if t == 0x07:
            return {"instalmentCollected": {"contract": self.nat(), "amount": self.nat(), "principal": self.nat(), "profit": self.nat(), "day": self.nat()}}
        if t == 0x08:
            return {"profitRecognised": {"contract": self.nat(), "amount": self.nat(), "cumulative": self.nat(), "day": self.nat()}}
        if t == 0x09:
            return {"rebateGranted": {"contract": self.nat(), "amount": self.nat(), "reason": self.text(), "day": self.nat()}}
        if t == 0x0A:
            return {"latePaymentToCharity": {"contract": self.nat(), "instalment": self.nat(), "amount": self.nat(), "cumulative": self.nat(), "day": self.nat()}}
        if t == 0x0B:
            return {"leaseCommenced": {"contract": self.nat(), "day": self.nat()}}
        if t == 0x0C:
            return {"rentalAccrued": {"contract": self.nat(), "amount": self.nat(), "period": self.nat(), "day": self.nat()}}
        if t == 0x0D:
            return {"rentalCollected": {"contract": self.nat(), "amount": self.nat(), "day": self.nat()}}
        if t == 0x0E:
            return {"depreciationPosted": {"contract": self.nat(), "amount": self.nat(), "cumulative": self.nat(), "day": self.nat()}}
        if t == 0x0F:
            c = self.nat(); how = self.islamic_transfer_opt()
            return {"ownershipTransferred": {"contract": c, "how": how, "consideration": self.nat(), "day": self.nat()}}
        if t == 0x10:
            return {"capitalContributed": {"contract": self.nat(), "party": self.opt_nat(), "amount": self.nat(), "day": self.nat()}}
        if t in (0x11, 0x12):
            name = "profitDistributed" if t == 0x11 else "lossAllocated"; k = "profit" if t == 0x11 else "loss"
            return {name: {"contract": self.nat(), k: self.nat(), "bankShare": self.nat(), "partnerShares": self.pairs(), "day": self.nat()}}
        if t == 0x13:
            return {"unitBought": {"contract": self.nat(), "units": self.nat(), "price": self.nat(), "bankUnitsLeft": self.nat(), "day": self.nat()}}
        if t == 0x14:
            return {"commodityDelivered": {"contract": self.nat(), "quantity": self.nat(), "day": self.nat()}}
        if t == 0x15:
            return {"commoditySold": {"contract": self.nat(), "proceeds": self.nat(), "day": self.nat()}}
        if t == 0x16:
            return {"deliveryFailed": {"contract": self.nat(), "recourse": self.text(), "day": self.nat()}}
        if t == 0x17:
            return {"milestoneRecorded": {"contract": self.nat(), "certificate": self.blob(), "percentBps": self.nat(), "revenue": self.nat(), "cost": self.nat(), "day": self.nat()}}
        if t == 0x18:
            return {"contractSettled": {"contract": self.nat(), "day": self.nat()}}
        if t == 0x19:
            return {"contractClosed": {"contract": self.nat(), "reason": self.text(), "day": self.nat()}}
        if t == 0x1A:
            return {"nonComplianceRecorded": {"contract": self.opt_nat(), "amount": self.nat(), "account": self.text(), "reason": self.text(), "day": self.nat()}}
        if t == 0x1B:
            return {"poolOpened": {"pool": self.islamic_pool(), "day": self.nat()}}
        if t == 0x1C:
            return {"poolDistributed": {"distribution": self.islamic_distribution(), "day": self.nat()}}
        if t == 0x1D:
            return {"reserveUpdated": {"pool": self.text(), "per": self.opt_nat(), "irr": self.opt_nat(), "day": self.nat()}}
        raise ValueError(f"unknown Islamic event tag {t:#x}")

    # ── trade finance (trade finance) ──
    def trade_policy(self):
        names = ["bic", "contingentLcs", "contingentGuarantees", "contingentCollections", "contingentContra", "marginDeposits", "unearnedCommission", "commissionIncome",
                 "acceptancesPayable", "customersLiabilityAcceptances", "billsNegotiated", "billsDiscounted", "unearnedDiscount", "discountIncome", "billsRediscounted", "billLosses", "nostro", "claimProduct"]
        out = {n: self.text() for n in names}
        out["examinationDays"] = self.nat()
        return out

    def trade_rules(self):
        return ["UCP600", "ISP98", "URDG758", "URC522"][self.byte()]

    def document_kind(self):
        t = self.byte()
        if t == 7:
            return {"other": self.text()}
        return ["invoice", "transport", "insurance", "origin", "packing", "inspection", "draft"][t]

    def document_ref(self):
        return {"kind": self.document_kind(), "hash": self.blob()}

    def document_refs(self):
        return [self.document_ref() for _ in range(self.len16())]

    def trade_availability(self):
        t = self.byte()
        if t == 0:
            return "sight"
        if t == 3:
            return "negotiation"
        return {["deferred", "acceptance"][t - 1]: {"days": self.nat()}}

    def trade_terms(self):
        docs = [{"kind": self.document_kind(), "copies": self.nat(), "checks": self.texts()} for _ in range(self.len16())]
        return {"documents": docs, "latestShipment": self.opt_nat(), "presentationDays": self.nat(), "partialShipments": self.bool(), "transhipment": self.bool(),
                "incoterm": self.opt_text(), "availableBy": self.trade_availability(), "portOfLoading": self.text(), "portOfDischarge": self.text(), "goods": self.text()}

    def counterparty(self):
        t = self.byte()
        if t == 0:
            return {"party": {"party": self.nat(), "account": self.nat()}}
        return {"external": {"name": self.text(), "bic": self.text(), "account": self.text()}}

    def trade_lc(self):
        return {"role": ["issuing", "advising", "confirming"][self.byte()], "applicant": self.counterparty(), "beneficiary": self.counterparty(), "counterpartyBank": self.text(),
                "terms": self.trade_terms(), "tolerance": self.opt_nat(), "marginBps": self.nat(), "facility": self.opt_nat(), "commissionBps": self.nat(), "reference": self.text()}

    def trade_guarantee(self):
        kind = ["standby", "demandGuarantee", "counterGuarantee"][self.byte()]
        rules = self.trade_rules()
        out = {"kind": kind, "rules": rules, "principal": self.nat(), "principalAccount": self.nat(), "beneficiary": self.counterparty(), "counterpartyBank": self.text(),
               "wording": self.blob(), "statementRequired": self.bool()}
        out["reductions"] = self.pairs()
        out.update({"marginBps": self.nat(), "facility": self.opt_nat(), "commissionBps": self.nat(), "reference": self.text()})
        return out

    def trade_collection(self):
        role = ["remitting", "collecting"][self.byte()]
        t = self.byte()
        terms = "DP" if t == 0 else {"DA": {"tenorDays": self.nat()}}
        return {"role": role, "terms": terms, "drawer": self.counterparty(), "drawee": self.counterparty(), "counterpartyBank": self.text(),
                "documents": self.document_refs(), "instructions": self.text(), "commissionBps": self.nat(), "reference": self.text()}

    def trade_bill(self):
        out = {"customer": self.nat(), "customerAccount": self.nat(), "acceptor": self.counterparty()}
        t = self.byte()
        out["source"] = None if t == 0 else {"instrument": self.nat(), "claim": self.nat()}
        out.update({"discountBps": self.nat(), "recourse": self.bool(), "reference": self.text()})
        return out

    def trade_checks(self):
        return [{"document": self.document_kind(), "check": self.text(), "passed": self.bool(), "finding": self.text()} for _ in range(self.len16())]

    def trade_decision(self):
        t = self.byte()
        if t == 0:
            return "complying"
        disc = self.texts()
        return {"refuse": {"discrepancies": disc, "disposal": ["held", "returned", "heldPendingWaiver", "actingOnInstructions"][self.byte()]}}

    def trade_honour(self):
        t = self.byte()
        if t == 0:
            return "sight"
        return {["deferred", "acceptance", "negotiation"][t - 1]: {"due": self.nat()}}

    def trade_amendment(self):
        out = {"amount": self.opt_nat(), "expiry": self.opt_nat(), "latestShipment": self.opt_nat(), "other": self.text()}
        out["consents"] = [["beneficiary", "confirmingBank", "applicant", "issuingBank"][self.byte()] for _ in range(self.len16())]
        return out

    def trade_message_kind(self):
        t = self.byte()
        return {["mt", "tsrv"][t]: self.nat()}

    def trade_event(self):
        t = self.byte()
        if t == 0x01:
            return {"policySet": self.trade_policy()}
        if t == 0x02:
            return {"lcIssued": {"lc": self.trade_lc(), "amount": self.nat(), "currency": self.text(), "expiry": self.nat(), "placeOfExpiry": self.text(), "margin": self.nat(), "commission": self.nat(), "book": self.text(), "day": self.nat()}}
        if t == 0x03:
            return {"lcAdvised": {"lc": self.trade_lc(), "amount": self.nat(), "currency": self.text(), "expiry": self.nat(), "placeOfExpiry": self.text(), "messageHash": self.blob(), "confirmed": self.bool(), "commission": self.nat(), "book": self.text(), "day": self.nat()}}
        if t in (0x04, 0x0D):
            return {["lcAmended", "guaranteeAmended"][t == 0x0D]: {"instrument": self.nat(), "amendment": self.trade_amendment(), "number": self.nat(), "amount": self.nat(), "expiry": self.nat(), "day": self.nat()}}
        if t == 0x05:
            return {"documentsPresented": {"instrument": self.nat(), "claim": self.nat(), "documents": self.document_refs(), "amount": self.nat(), "shipmentDate": self.opt_nat(), "presentedOn": self.nat(), "deadline": self.nat(), "day": self.nat()}}
        if t in (0x06, 0x0F):
            return {["presentationExamined", "demandExamined"][t == 0x0F]: {"instrument": self.nat(), "claim": self.nat(), "checks": self.trade_checks(), "decision": self.trade_decision(), "day": self.nat()}}
        if t == 0x07:
            return {"discrepanciesWaived": {"instrument": self.nat(), "claim": self.nat(), "applicantConsentHash": self.blob(), "day": self.nat()}}
        if t == 0x08:
            return {"presentationHonoured": {"instrument": self.nat(), "claim": self.nat(), "amount": self.nat(), "honour": self.trade_honour(), "fromMargin": self.nat(), "day": self.nat()}}
        if t == 0x09:
            return {"acceptanceMatured": {"instrument": self.nat(), "claim": self.nat(), "amount": self.nat(), "fromMargin": self.nat(), "day": self.nat()}}
        if t in (0x0A, 0x12):
            return {["lcClosed", "guaranteeReleased"][t == 0x12]: {"instrument": self.nat(), "reason": self.text(), "marginReleased": self.nat(), "day": self.nat()}}
        if t in (0x0B, 0x13):
            return {["lcExpired", "guaranteeExpired"][t == 0x13]: {"instrument": self.nat(), "expiry": self.nat(), "marginReleased": self.nat(), "day": self.nat()}}
        if t == 0x0C:
            return {"guaranteeIssued": {"guarantee": self.trade_guarantee(), "wordingText": self.text(), "amount": self.nat(), "currency": self.text(), "expiry": self.nat(), "margin": self.nat(), "commission": self.nat(), "book": self.text(), "day": self.nat()}}
        if t == 0x0E:
            return {"demandRecorded": {"instrument": self.nat(), "claim": self.nat(), "demand": self.document_ref(), "amount": self.nat(), "supportingStatement": self.bool(), "presentedOn": self.nat(), "deadline": self.nat(), "day": self.nat()}}
        if t == 0x10:
            return {"demandPaid": {"instrument": self.nat(), "claim": self.nat(), "amount": self.nat(), "fromMargin": self.nat(), "fromAccount": self.nat(), "claimAccount": self.opt_nat(), "day": self.nat()}}
        if t == 0x11:
            return {"guaranteeReduced": {"instrument": self.nat(), "from": self.nat(), "to": self.nat(), "day": self.nat()}}
        if t == 0x14:
            return {"collectionRegistered": {"collection": self.trade_collection(), "amount": self.nat(), "currency": self.text(), "book": self.text(), "day": self.nat()}}
        if t == 0x15:
            return {"collectionPresented": {"instrument": self.nat(), "claim": self.nat(), "presentedOn": self.nat(), "day": self.nat()}}
        if t == 0x16:
            return {"collectionAccepted": {"instrument": self.nat(), "claim": self.nat(), "maturity": self.nat(), "day": self.nat()}}
        if t == 0x17:
            return {"collectionPaid": {"instrument": self.nat(), "claim": self.nat(), "amount": self.nat(), "commission": self.nat(), "day": self.nat()}}
        if t == 0x18:
            return {"collectionProtested": {"instrument": self.nat(), "claim": self.nat(), "reason": self.text(), "day": self.nat()}}
        if t == 0x19:
            return {"collectionReturned": {"instrument": self.nat(), "reason": self.text(), "day": self.nat()}}
        if t == 0x1A:
            return {"billDiscounted": {"bill": self.trade_bill(), "face": self.nat(), "currency": self.text(), "maturity": self.nat(), "discount": self.nat(), "proceeds": self.nat(), "book": self.text(), "day": self.nat()}}
        if t == 0x1B:
            return {"billRediscounted": {"instrument": self.nat(), "to": self.text(), "amount": self.nat(), "day": self.nat()}}
        if t == 0x1C:
            return {"billMatured": {"instrument": self.nat(), "face": self.nat(), "day": self.nat()}}
        if t == 0x1D:
            return {"billDishonoured": {"instrument": self.nat(), "face": self.nat(), "chargedBack": self.nat(), "day": self.nat()}}
        if t == 0x1E:
            return {"tradeMessageRecorded": {"instrument": self.nat(), "seq": self.nat(), "kind": self.trade_message_kind(), "direction": ["outgoing", "incoming"][self.byte()], "hash": self.blob(), "day": self.nat()}}
        if t in (0x1F, 0x20):
            return {["commissionEarned", "discountEarned"][t == 0x20]: {"instrument": self.nat(), "amount": self.nat(), "cumulative": self.nat(), "day": self.nat()}}
        raise ValueError(f"unknown trade event tag {t:#x}")

    # ── branch and teller (branch and teller) ──
    def denominations(self):
        return {"notes": self.pairs(), "coins": self.pairs()}

    def teller_policy(self):
        return {"overShort": self.text(), "cashInTransit": self.text(), "centralBank": self.text(), "draftsPayable": self.text(), "clearing": self.text(), "staleDays": self.nat(), "clearingWindowDays": self.nat()}

    def difference(self):
        t = self.byte()
        if t == 0:
            return "balanced"
        return {["over", "short"][t - 1]: self.nat()}

    def payee(self):
        t = self.byte()
        if t == 0:
            return {"inBranch": {"till": self.text()}}
        return {"clearing": {"house": self.text(), "batch": self.text()}}

    def return_reason(self):
        t = self.byte()
        if t == 5:
            return {"other": self.text()}
        return ["insufficientFunds", "stopped", "signature", "stale", "postDated"][t]

    def cash_source(self):
        t = self.byte()
        return {"till": self.text()} if t == 0 else {"account": self.nat()}

    def teller_event(self):
        t = self.byte()
        if t == 0x01:
            return {"policySet": self.teller_policy()}
        if t == 0x02:
            return {"sessionOpened": {"till": self.text(), "teller": self.principal(), "opening": self.denominations(), "counted": self.nat(), "book": self.nat(), "day": self.nat()}}
        if t == 0x03:
            return {"sessionClosed": {"session": self.nat(), "till": self.text(), "closing": self.denominations(), "counted": self.nat(), "book": self.nat(), "difference": self.difference(), "day": self.nat()}}
        if t == 0x04:
            return {"differenceResolved": {"session": self.nat(), "till": self.text(), "difference": self.difference(), "account": self.text(), "note": self.text(), "day": self.nat()}}
        if t == 0x05:
            return {"cashTaken": {"till": self.text(), "account": self.nat(), "amount": self.nat(), "tendered": self.denominations(), "change": self.denominations(), "day": self.nat()}}
        if t == 0x06:
            return {"cashPaid": {"till": self.text(), "account": self.nat(), "amount": self.nat(), "paid": self.denominations(), "day": self.nat()}}
        if t == 0x07:
            return {"vaultToTill": {"till": self.text(), "book": self.text(), "currency": self.text(), "amount": self.nat(), "denominations": self.denominations(), "day": self.nat()}}
        if t == 0x08:
            return {"tillToVault": {"till": self.text(), "book": self.text(), "currency": self.text(), "amount": self.nat(), "denominations": self.denominations(), "day": self.nat()}}
        if t == 0x09:
            return {"cashDispatched": {"product": self.text(), "fromBook": self.text(), "toBook": self.text(), "currency": self.text(), "amount": self.nat(), "denominations": self.denominations(),
                                       "carrier": self.text(), "sealBag": self.text(), "day": self.nat()}}
        if t == 0x0A:
            return {"cashReceived": {"movement": self.nat(), "denominations": self.denominations(), "day": self.nat()}}
        if t == 0x0B:
            return {"vaultToCentralBank": {"product": self.text(), "book": self.text(), "currency": self.text(), "amount": self.nat(), "denominations": self.denominations(), "day": self.nat()}}
        if t == 0x0C:
            return {"centralBankToVault": {"product": self.text(), "book": self.text(), "currency": self.text(), "amount": self.nat(), "denominations": self.denominations(), "day": self.nat()}}
        if t == 0x0D:
            return {"chequebookIssued": {"account": self.nat(), "from": self.nat(), "to": self.nat(), "day": self.nat()}}
        if t == 0x0E:
            return {"chequeStopped": {"account": self.nat(), "serial": self.nat(), "reason": self.text(), "day": self.nat()}}
        if t == 0x0F:
            return {"chequePresented": {"account": self.nat(), "serial": self.nat(), "amount": self.nat(), "payee": self.payee(), "chequeDate": self.nat(), "imageHash": self.blob(), "hold": self.nat(), "expiresAt": self.nat(), "day": self.nat()}}
        if t == 0x10:
            return {"chequeCleared": {"account": self.nat(), "serial": self.nat(), "amount": self.nat(), "day": self.nat()}}
        if t == 0x11:
            return {"chequeReturned": {"account": self.nat(), "serial": self.nat(), "amount": self.nat(), "reason": self.return_reason(), "day": self.nat()}}
        if t == 0x12:
            return {"draftIssued": {"serial": self.text(), "payeeCommit": self.blob(), "amount": self.nat(), "currency": self.text(), "source": self.cash_source(), "day": self.nat()}}
        if t == 0x13:
            return {"draftPaid": {"serial": self.text(), "amount": self.nat(), "to": self.cash_source(), "day": self.nat()}}
        if t == 0x14:
            return {"draftCancelled": {"serial": self.text(), "amount": self.nat(), "refundTo": self.nat(), "day": self.nat()}}
        raise ValueError(f"unknown teller event tag {t:#x}")

    def alert_event(self):
        sub = self.byte()
        if sub == 0x01:
            finding = self.finding()
            return {"alertOpened": {"finding": finding, "source": {0: "posting", 1: "endOfDay"}[self.byte()]}}
        if sub == 0x02:
            return {"alertCleared": {"alert": self.nat(), "reason": self.text()}}
        if sub == 0x03:
            return {"alertEscalated": {"alert": self.nat(), "reportRef": self.text()}}
        raise ValueError(f"unknown alert event sub-tag {sub:#x}")

    def packing_event(self):
        sub = self.byte()
        if sub == 0x01:
            return {"packOpened": {"pack": self.nat(), "period": self.text(), "periodEnd": self.nat(),
                                   "lo": self.nat(), "hi": self.nat(), "bankLo": self.nat(), "bankHi": self.nat()}}
        if sub == 0x0B:
            return {"bankSegmentPacked": {"pack": self.nat(), "seq": self.nat(), "lo": self.nat(), "hi": self.nat(),
                                          "bytes": self.nat(), "rawBytes": self.nat(), "dropped": self.nat(), "kept": self.nat(),
                                          "sha256": self.blob()}}
        if sub == 0x02:
            return {"segmentPacked": {"pack": self.nat(), "seq": self.nat(), "lo": self.nat(), "hi": self.nat(),
                                      "bytes": self.nat(), "rawBytes": self.nat(), "postings": self.nat(),
                                      "sha256": self.blob()}}
        if sub == 0x03:
            return {"packAdvanced": {"pack": self.nat(), "phase": self.text(), "work": self.nat()}}
        if sub == 0x04:
            return {"packSealed": {"pack": self.nat(), "segments": self.nat(), "postings": self.nat(),
                                   "accounts": self.nat(), "packedBytes": self.nat(), "rawBytes": self.nat(),
                                   "sha256": self.blob(), "hi": self.nat(), "periodEnd": self.nat(),
                                   "bankHi": self.nat(), "bankSegments": self.nat(), "bankPackedBytes": self.nat(),
                                   "bankRawBytes": self.nat(), "bankDropped": self.nat(), "bankKept": self.nat()}}
        if sub == 0x05:
            return {"rollAuthorised": {"pack": self.nat(), "cid": self.nat64(), "archive": self.principal(),
                                       "hi": self.nat(), "periodEnd": self.nat()}}
        if sub == 0x06:
            return {"rollAdvanced": {"pack": self.nat(), "phase": self.text(), "work": self.nat()}}
        if sub == 0x07:
            return {"checkpointWritten": {"pack": self.nat(), "through": self.nat(), "first": self.nat(), "last": self.nat()}}
        if sub == 0x08:
            return {"segmentSent": {"pack": self.nat(), "seq": self.nat(), "attempt": self.nat()}}
        if sub == 0x09:
            return {"segmentArchived": {"pack": self.nat(), "seq": self.nat(), "sha256": self.blob()}}
        if sub == 0x0A:
            return {"packArchived": {"pack": self.nat(), "cid": self.nat64(), "archive": self.principal(),
                                     "hi": self.nat(), "journalBase": self.nat(), "segments": self.nat()}}
        raise ValueError(f"unknown packing event sub-tag {sub:#x}")

    def shards(self):
        n = self.len16()
        return [{"index": self.nat(), "principal": self.principal(), "settlement": self.text()} for _ in range(n)]

    def shard_event(self):
        sub = self.byte()
        if sub == 0x01:
            return {"ruleDeclared": {"version": self.nat(), "self": self.nat(), "shards": self.shards()}}
        if sub == 0x02:
            return {"outboundOpened": {"from": self.nat(), "toIdentifier": self.text(), "toShard": self.nat(), "amount": self.nat(),
                                       "currency": self.text(), "valueDay": self.nat(), "period": self.text(), "narration": self.text(),
                                       "pendingIndex": self.nat()}}
        if sub == 0x03:
            return {"outboundSent": {"transfer": self.nat(), "attempt": self.nat()}}
        if sub == 0x04:
            return {"outboundSettled": {"transfer": self.nat(), "receiverPosting": self.nat()}}
        if sub == 0x05:
            return {"outboundReturned": {"transfer": self.nat(), "reason": self.text()}}
        if sub == 0x06:
            return {"inboundPosted": {"fromShard": self.nat(), "transfer": self.nat(), "toAccount": self.nat(), "amount": self.nat(), "posting": self.nat()}}
        if sub == 0x07:
            return {"inboundRefused": {"fromShard": self.nat(), "transfer": self.nat(), "toIdentifier": self.text(), "reason": self.text()}}
        raise ValueError(f"unknown shard event sub-tag {sub:#x}")

    def participant_accounts(self):
        n = self.len16()
        return [{"currency": self.text(), "position": self.nat(), "settlement": self.nat(), "feeReceivable": self.nat()} for _ in range(n)]

    def nat_list(self):
        n = self.nat()
        return [self.nat() for _ in range(n)]

    WINDOW_STATES = ["open", "closed", "pendingSettlement", "processing", "settled", "aborted", "failed"]
    SETTLEMENT_STATES = ["pendingSettlement", "psTransfersRecorded", "psTransfersReserved", "psTransfersCommitted", "settling", "settled", "aborted"]
    BULK_STATES = ["received", "pendingPrepare", "accepted", "processing", "pendingFulfil", "completed", "rejected", "invalid", "expired", "aborting", "expiring", "pendingInvalid"]
    BULK_PROCESSING = ["received", "receivedDuplicate", "receivedInvalid", "accepted", "processing", "fulfilDuplicate", "fulfilInvalid", "completed", "rejected", "expired", "aborting"]

    def settlement_event(self):
        sub = self.byte()
        if sub == 0x01:
            return {"schemeDeclared": {"id": self.text(), "granularity": ["gross", "net"][self.byte()], "interchange": ["bilateral", "multilateral"][self.byte()],
                                       "delay": ["immediate", "deferred"][self.byte()], "reconciliation": self.text(), "feeIncome": self.text(),
                                       "interchangeBps": self.nat(), "hubFeeBps": self.nat(), "alarmPercent": self.nat()}}
        if sub == 0x02:
            return {"participantRegistered": {"party": self.nat(), "bic": self.text(), "scheme": self.text(), "accounts": self.participant_accounts()}}
        if sub == 0x03:
            return {"participantDeactivated": {"participant": self.nat()}}
        if sub == 0x04:
            return {"fundsRecorded": {"participant": self.nat(), "currency": self.text(), "amount": self.nat(), "direction": ["in", "out"][self.byte()], "posting": self.nat()}}
        if sub == 0x05:
            return {"capAlarm": {"participant": self.nat(), "currency": self.text(), "exposure": self.nat(), "cap": self.nat(), "alarmPercent": self.nat()}}
        if sub == 0x06:
            return {"transferPrepared": {"scheme": self.text(), "payer": self.nat(), "payee": self.nat(), "currency": self.text(), "amount": self.nat(),
                                         "reference": self.text(), "expiresAt": self.nat64(), "bulk": self.opt(self.nat), "correctionOf": self.opt(self.nat)}}
        if sub == 0x07:
            return {"transferReserved": {"transfer": self.nat(), "reservation": self.nat(), "forwarded": self.byte() == 1}}
        if sub == 0x08:
            return {"transferFailed": {"transfer": self.nat(), "reason": self.text()}}
        if sub == 0x09:
            return {"transferFulfilDependent": {"transfer": self.nat()}}
        if sub == 0x0A:
            return {"transferCommitted": {"transfer": self.nat(), "posting": self.nat(), "window": self.nat(), "interchangeFee": self.nat(), "hubFee": self.nat(), "feePostings": self.nat_list()}}
        if sub == 0x0B:
            return {"transferAborted": {"transfer": self.nat(), "how": ["rejected", "error", "expired"][self.byte()], "reason": self.text()}}
        if sub == 0x0C:
            return {"transfersSettled": {"settlement": self.nat(), "transfers": self.nat_list()}}
        if sub == 0x0D:
            return {"windowOpened": {"scheme": self.text(), "businessDate": self.nat()}}
        if sub == 0x0E:
            return {"windowStateChanged": {"window": self.nat(), "to": self.WINDOW_STATES[self.byte()], "reason": self.text()}}
        if sub == 0x0F:
            return {"settlementOpened": {"window": self.nat()}}
        if sub == 0x10:
            settlement, to = self.nat(), self.SETTLEMENT_STATES[self.byte()]
            n = self.nat()
            nets = [{"participant": self.nat(), "currency": self.text(), "debits": self.nat(), "credits": self.nat()} for _ in range(n)]
            return {"settlementStateChanged": {"settlement": settlement, "to": to, "nets": nets, "postings": self.nat_list(), "reason": self.text()}}
        if sub == 0x11:
            scheme, payer, reference, ttl = self.text(), self.nat(), self.text(), self.nat()
            n = self.len16()
            return {"bulkReceived": {"scheme": scheme, "payer": payer, "reference": reference, "ttlSeconds": ttl,
                                     "requests": [{"payee": self.nat(), "currency": self.text(), "amount": self.nat(), "reference": self.text()} for _ in range(n)]}}
        if sub == 0x12:
            bulk, to, processing = self.nat(), self.BULK_STATES[self.byte()], self.BULK_PROCESSING[self.byte()]
            prepared, done = self.nat(), self.nat()
            n = self.nat()
            return {"bulkStateChanged": {"bulk": bulk, "to": to, "processing": processing, "prepared": prepared, "done": done, "failures": [(self.nat(), self.text()) for _ in range(n)]}}
        raise ValueError(f"unknown settlement event sub-tag {sub:#x}")

    def text_pairs(self):
        n = self.len16()
        return [(self.text(), self.text()) for _ in range(n)]

    def fspiop_event(self):
        sub = self.byte()
        if sub == 0x01:
            return {"participantDeclared": {"rail": self.text(), "participant": self.nat(), "fspId": self.text(), "endpoints": self.text_pairs()}}
        if sub == 0x02:
            return {"partyRegistered": {"rail": self.text(), "idType": self.text(), "id": self.text(), "subId": self.opt_text(), "fspId": self.text(), "currency": self.opt_text()}}
        if sub == 0x03:
            return {"partyDeregistered": {"rail": self.text(), "idType": self.text(), "id": self.text(), "subId": self.opt_text()}}
        if sub == 0x04:
            return {"quoteReceived": {"rail": self.text(), "quoteId": self.text(), "transactionId": self.text(), "payerFsp": self.text(), "payeeFsp": self.text(),
                                      "amount": self.nat(), "currency": self.text(), "amountType": self.text(), "expiration": self.opt_text()}}
        if sub == 0x05:
            return {"quoteAnswered": {"rail": self.text(), "quoteId": self.text(), "transferAmount": self.nat(), "currency": self.text(), "condition": self.blob(),
                                      "ilpPacketHash": self.blob(), "expiration": self.text()}}
        if sub == 0x06:
            return {"transferPrepared": {"rail": self.text(), "transferId": self.text(), "transfer": self.nat(), "condition": self.blob(), "expiration": self.text(), "ilpPacketHash": self.blob()}}
        if sub == 0x07:
            return {"transferFulfilled": {"rail": self.text(), "transferId": self.text(), "transfer": self.nat(), "fulfilment": self.blob(), "completedAt": self.text()}}
        if sub == 0x08:
            return {"transferAborted": {"rail": self.text(), "transferId": self.text(), "transfer": self.nat(), "errorCode": self.text(), "reason": self.text()}}
        if sub == 0x09:
            return {"requestHandled": {"rail": self.text(), "method": self.text(), "path": self.text(), "source": self.opt_text(), "destination": self.opt_text(),
                                       "hash": self.blob(), "status": self.nat(), "errorCode": self.opt_text(), "callbacks": self.nat()}}
        raise ValueError(f"unknown fspiop event sub-tag {sub:#x}")

    def opt_nat(self):
        return self.opt(self.nat)

    def opt_text(self):
        present = self.byte()
        if present == 0:
            return None
        assert present == 1, "bad option byte"
        return self.text()

    def rule_spec(self):
        """Mirrors BankCanonical.writeRuleSpec: a type tag, then the parameters in declaration order."""
        tag = self.byte()
        if tag == 1:
            return {"velocity": {"count": self.nat(), "windowDays": self.nat()}}
        if tag == 2:
            return {"structuring": {"threshold": self.nat(), "bandPercent": self.nat(), "count": self.nat(),
                                    "windowDays": self.nat(), "maxScan": self.nat()}}
        if tag == 3:
            return {"roundTrip": {"windowDays": self.nat(), "minAmount": self.nat()}}
        if tag == 4:
            return {"fanOut": {"distinct": self.nat(), "windowDays": self.nat()}}
        if tag == 5:
            return {"fanIn": {"distinct": self.nat(), "windowDays": self.nat()}}
        if tag == 6:
            return {"dormantThenActive": {"dormantDays": self.nat(), "amount": self.nat()}}
        if tag == 7:
            return {"passThrough": {"inOutPercent": self.nat(), "windowDays": self.nat(), "minAmount": self.nat()}}
        if tag == 8:
            return {"largeCash": {"threshold": self.nat(), "channels": self.texts()}}
        raise ValueError(f"unknown rule spec tag {tag:#x}")

    def monitoring_event(self):
        sub = self.byte()
        if sub == 0x01:
            return {"ruleDefined": {"id": self.text(), "version": self.nat(), "currency": self.opt_text(), "spec": self.rule_spec()}}
        if sub == 0x02:
            return {"ruleRetired": {"id": self.text(), "version": self.nat()}}
        raise ValueError(f"unknown monitoring event sub-tag {sub:#x}")

    def principals(self):
        return [self.principal() for _ in range(self.len16())]

    def archive_event(self):
        """Tag 0x46. Sub-tags and layouts mirror BankCanonical.writeArchiveEvent."""
        sub = self.byte()
        if sub == 0x01:
            return {"imagePinned": {"sha256": self.blob(), "bytes": self.nat(), "name": self.text()}}
        if sub == 0x02:
            return {"imageSealed": {"sha256": self.blob(), "bytes": self.nat()}}
        if sub == 0x03:
            return {"controllersSet": {"controllers": self.principals()}}
        if sub == 0x04:
            return {"spawnAuthorised": {"purpose": self.text()}}
        if sub == 0x05:
            return {"createIssued": {"spawn": self.nat(), "attempt": self.nat()}}
        if sub == 0x06:
            return {"childRemembered": {"spawn": self.nat(), "cid": self.nat64()}}
        if sub == 0x07:
            return {"installIssued": {"spawn": self.nat(), "cid": self.nat64(), "image": self.blob(), "attempt": self.nat()}}
        if sub == 0x08:
            return {"childConfirmed": {"spawn": self.nat(), "cid": self.nat64(), "image": self.blob()}}
        if sub == 0x09:
            return {"confirmRefused": {"spawn": self.nat(), "cid": self.nat64(), "offered": self.blob()}}
        if sub == 0x0A:
            return {"controllersIssued": {"spawn": self.nat(), "cid": self.nat64(),
                                          "controllers": self.principals(), "attempt": self.nat()}}
        if sub == 0x0B:
            return {"childReady": {"spawn": self.nat(), "cid": self.nat64()}}
        if sub == 0x0C:
            return {"spawnAbandoned": {"spawn": self.nat(), "reason": self.text()}}
        if sub == 0x0D:
            return {"childAdopted": {"cid": self.nat64(), "image": self.blob(),
                                     "controllers": self.principals(), "purpose": self.text()}}
        raise ValueError(f"unknown archive event sub-tag {sub:#x}")

    def bank_event(self):
        tag = self.byte()
        if tag == 0x10:
            return {"bookOpened": {"id": self.text(), "name": self.text(), "parent": self.opt(self.text)}}
        if tag == 0x11:
            return {"bookClosed": {"id": self.text()}}
        if tag == 0x12:
            return {"roleDefined": {"id": self.text(), "name": self.text(), "permissions": self.texts()}}
        if tag == 0x13:
            return {"roleGranted": {"subject": self.principal(), "role": self.text(), "scope": self.scope()}}
        if tag == 0x14:
            return {"roleRevoked": {"subject": self.principal(), "role": self.text()}}
        if tag == 0x15:
            return {"dualPolicySet": self.policy()}
        if tag == 0x16:
            return {"dualPolicyCleared": {"permission": self.text()}}
        if tag == 0x17:
            return {"bankAdminTransferred": {"admin": self.principal()}}
        if tag == 0x18:
            return {"featureActivationSet": {"feature": self.text(), "height": self.nat64()}}
        if tag == 0x30:
            # the body is not in the preimage: _decode_block reads it from the trailer and fills "command"
            return {"commandProposed": {"command": None, "commandHash": self.blob(), "commandEncoding": self.byte(), "permission": self.text(), "book": self.opt(self.text),
                                        "maker": self.principal(), "required": self.nat(),
                                        "eligibleRole": self.text(), "expiresAt": self.nat64(),
                                        "justification": self.text()}}
        if tag == 0x31:
            return {"commandApproved": {"proposal": self.nat(), "commandHash": self.blob(), "checker": self.principal()}}
        if tag == 0x32:
            return {"commandRejected": {"proposal": self.nat(), "checker": self.principal(), "reason": self.text()}}
        if tag == 0x33:
            out = {"proposal": self.nat(), "commandHash": self.blob(), "postings": self.nats()}
            flag = self.byte()
            if flag == 1:
                day = self.nat()
                out["charge"] = {"day": day, "totals": [(self.text(), self.nat()) for _ in range(self.len16())]}
            elif flag == 0:
                out["charge"] = None
            else:
                raise ValueError("bad charge flag %d" % flag)
            return {"commandExecuted": out}
        if tag == 0x34:
            return {"commandExpired": {"proposal": self.nat()}}
        if tag == 0x35:
            enc = self.byte()
            return {"emergencyOverride": {"commandEncoding": enc, "command": self.command(enc), "commandHash": self.blob(),
                                          "actor_": self.principal(), "witness": self.principal(),
                                          "justification": self.text()}}
        if tag == 0x36:
            return {"overrideReviewed": {"override_": self.nat(), "reviewer": self.principal(), "disposition": self.text()}}
        if tag == 0x50:
            return {"operationRefused": {"subject": self.principal(), "permission": self.text(),
                                         "reason": REFUSALS[self.byte()], "detail": self.text()}}
        if tag == 0x40:
            return {"party": self.party_event()}
        if tag == 0x41:
            return {"product": self.product_event()}
        if tag == 0x42:
            return {"close": self.close_event()}
        if tag == 0x43:
            return {"batch": self.batch_event()}
        if tag == 0x44:
            return {"report": self.report_event()}
        if tag == 0x45:
            sub = self.byte()
            assert sub == 0x01, f"unknown index event sub-tag {sub:#x}"
            present = self.byte()
            if present == 0:
                return {"index": {"counterpartyClassDimensionSet": {"dimension": None}}}
            assert present == 1, "counterpartyClassDimensionSet: bad option byte"
            return {"index": {"counterpartyClassDimensionSet": {"dimension": {"schema": self.text(), "field": self.text()}}}}
        if tag == 0x46:
            return {"archive": self.archive_event()}
        if tag == 0x47:
            return {"monitoring": self.monitoring_event()}
        if tag == 0x48:
            return {"alert": self.alert_event()}
        if tag == 0x4E:
            return {"collections": self.collections_event()}
        if tag == 0x4F:
            return {"origination": self.origination_event()}
        if tag == 0x51:
            return {"facility": self.facility_event()}
        if tag == 0x52:
            return {"teller": self.teller_event()}
        if tag == 0x53:
            return {"trade": self.trade_event()}
        if tag == 0x54:
            return {"islamic": self.islamic_event()}
        if tag == 0x55:
            return {"treasury": self.treasury_event()}
        if tag == 0x56:
            return {"card": self.card_event()}
        if tag == 0x49:
            return {"packing": self.packing_event()}
        if tag == 0x4A:
            return {"shard": self.shard_event()}
        if tag == 0x4B:
            return {"settlement": self.settlement_event()}
        if tag == 0x4C:
            return {"payments": self.payments_event()}
        if tag == 0x4D:
            return {"fspiop": self.fspiop_event()}
        if tag == 0x57:
            k = self.byte()
            if k == 0x01:
                return {"rebuild": {"started": {"layoutFrom": self.nat(), "layoutTo": self.nat(), "journalLayoutFrom": self.nat(),
                                               "journalLayoutTo": self.nat(), "bankBlocks": self.nat(), "journalBlocks": self.nat()}}}
            if k == 0x02:
                return {"rebuild": {"chunk": {"bankFrom": self.nat(), "bankTo": self.nat(), "journalFrom": self.nat(), "journalTo": self.nat()}}}
            if k == 0x03:
                return {"rebuild": {"completed": {"layout": self.nat(), "journalLayout": self.nat(), "bankBlocks": self.nat(), "journalBlocks": self.nat(),
                                                 "bankFingerprint": self.blob(), "journalFingerprint": self.blob()}}}
            raise ValueError(f"unknown rebuild event kind {k:#x}")
        raise ValueError(f"unknown bank event tag {tag:#x}")


def command_hash(command_bytes, version=CURRENT_COMMAND_ENCODING):
    """The hash a checker approves, over the canonical command bytes under the recorded encoding version;
    the domain names the version, so a body hashed under another version never matches."""
    assert version in SUPPORTED_COMMAND_ENCODINGS, f"command encoding {version} is not one this verifier implements"
    return _domain_hash(command_domain(version), command_bytes)


def decode_block(raw):
    """Decode raw bank block bytes; verify the embedded hash; return (fields, hash).
    Any malformed input is a verification failure, never a crash."""
    try:
        return _decode_block(raw)
    except (IndexError, ValueError, KeyError, UnicodeDecodeError, AssertionError) as e:
        raise AssertionError(f"malformed bank block bytes: {e}") from None


def _decode_block(raw):
    r = Reader(raw)
    version = r.byte()
    assert version in SUPPORTED_BLOCK_VERSIONS, f"bank block version {version}"
    index = r.nat()
    timestamp = r.nat64()
    caller = r.principal()
    parent = r.opt(r.blob)
    event = r.bank_event()
    preimage_len = r.p
    stored = r.take(32)
    # the trailer: a proposal block's body, bound to the preimage by its commandHash, or 0 once a pack dropped it
    if "commandProposed" in event:
        enc = event["commandProposed"]["commandEncoding"]
        assert enc in SUPPORTED_COMMAND_ENCODINGS, f"proposal block records command encoding {enc}, which this verifier does not implement"
        flag = r.byte()
        if flag == 1:
            start = r.p
            body = r.command(enc)
            assert command_hash(raw[start:r.p], enc) == event["commandProposed"]["commandHash"], "the trailer's body does not hash to the preimage's commandHash under its recorded encoding"
            event["commandProposed"]["command"] = body
        elif flag != 0:
            raise ValueError("bad trailer flag %d" % flag)
    assert r.p == len(raw), "trailing bytes"
    computed = block_hash(raw[:preimage_len])
    assert computed == stored, "embedded hash does not match recomputed hash"
    return {"index": index, "timestamp": timestamp, "caller": caller, "parentHash": parent, "event": event}, stored


def split_trailer(raw):
    """A stored block's bytes as (head, trailer): the preimage and its hash, then whatever follows;
    a proposal's body behind a 1, or the single 0 a pack leaves once the body is dropped. What a
    bank segment keeps of a settled proposal is exactly head + b"\x00"."""
    r = Reader(raw)
    version = r.byte()
    assert version in SUPPORTED_BLOCK_VERSIONS
    r.nat(); r.nat64(); r.principal(); r.opt(r.blob)
    r.bank_event()
    r.take(32)
    return raw[:r.p], raw[r.p:]


def command_bytes_of(raw):
    """Extract the canonical command bytes from a proposal or override block, so the command hash can be
    recomputed from the block rather than taken from it, with the encoding version the block recorded;
    this is what makes 'the approved bytes execute' checkable from outside. Returns (bytes, version), or
    None for a proposal whose body a pack dropped."""
    r = Reader(raw)
    version = r.byte()
    assert version in SUPPORTED_BLOCK_VERSIONS
    r.nat(); r.nat64(); r.principal(); r.opt(r.blob)
    tag = r.byte()
    assert tag in (0x30, 0x35), f"block {tag:#x} carries no command"
    if tag == 0x35:
        enc = r.byte()
        start = r.p
        r.command(enc)
        return raw[start:r.p], enc
    # a proposal: the body is the trailer behind the hash; None once a pack dropped it
    r.p -= 1
    ev = r.bank_event()["commandProposed"]
    r.take(32)
    if r.byte() != 1:
        return None
    start = r.p
    r.command(ev["commandEncoding"])
    return raw[start:r.p], ev["commandEncoding"]


def certified_roots(tip, root_key_der, canister_id_bytes):
    """Steps 1-3: verify the certificate, tie the returned tree to `certified_data`,
    and return both MMR roots out of the one tree. A tree that carries only one of
    them fails here, which is the property that makes a posting and the authority
    behind it provable against the same certificate."""
    tree = V.verify_certificate(tip["certificate"], root_key_der, canister_id_bytes)
    certified = V.lookup(tree, [b"canister", canister_id_bytes, b"certified_data"])
    assert certified is not None, "certificate has no certified_data for this canister"
    ht = V.cbor2.loads(bytes(tip["hash_tree"]))
    assert V.hash_tree(ht) == certified, "hash tree root != certified_data"
    bank = V.lookup(ht, [LABEL_BANK, b"mmr_root"])
    journal = V.lookup(ht, [LABEL_JOURNAL, b"mmr_root"])
    assert bank is not None, "certified tree has no thebes_bank/mmr_root"
    assert journal is not None, "certified tree has no thebes_journal/mmr_root"
    return {
        "bank": bank,
        "journal": journal,
        "bank_index": V.lookup(ht, [LABEL_BANK, b"last_block_index"]),
        "bank_hash": V.lookup(ht, [LABEL_BANK, b"last_block_hash"]),
        "journal_index": V.lookup(ht, [LABEL_JOURNAL, b"last_block_index"]),
        "journal_hash": V.lookup(ht, [LABEL_JOURNAL, b"last_block_hash"]),
    }


def verify_bank_entry(raw_block, proof, tip, root_key_der, canister_id_bytes, expect_index=None):
    """The five-step check for a bank block. Returns the decoded fields."""
    roots = certified_roots(tip, root_key_der, canister_id_bytes)
    fields, h = decode_block(bytes(raw_block))
    if expect_index is not None:
        assert fields["index"] == expect_index, "bank block index mismatch"
    assert V.mmr_verify(h, fields["index"], [bytes(s) for s in proof["siblings"]],
                        [bytes(p) for p in proof["peaks"]], proof["peakIndex"], roots["bank"]), \
        "bank inclusion proof does not bag to the certified root"
    return fields


def verify_journal_entry(raw_block, proof, tip, root_key_der, canister_id_bytes, expect_index=None):
    """The same check for a journal block, against the journal root inside the
    same certificate; so one certificate proves both."""
    roots = certified_roots(tip, root_key_der, canister_id_bytes)
    fields, h = V.decode_block(bytes(raw_block))
    if expect_index is not None:
        assert fields["index"] == expect_index, "journal block index mismatch"
    assert V.mmr_verify(h, fields["index"], [bytes(s) for s in proof["siblings"]],
                        [bytes(p) for p in proof["peaks"]], proof["peakIndex"], roots["journal"]), \
        "journal inclusion proof does not bag to the certified root"
    return fields
