/// IsoBreadth.mo — the extended ISO 20022 target list: the twenty families added to the compact profile, each read from the tree the
/// vendored parser (Xml.mo) produced and the official schema profile (IsoSchema.mo over IsoProfiles.mo) validated
/// into a typed record, and the ones the hub answers with written schema-valid.
///
/// The readers and emitters are those of thebes-banking-core (src/bank/IsoMessages.mo, commit f7e3563), carried
/// here with the bank's journal types replaced by the hub's: a message kind is its text ("pacs.007"), dates are
/// ISO 8601 text, an issue is {rule; path; detail}. Every `read*` presumes `IsoSchema.validate` passed, so the
/// required elements are there; what this layer still refuses is business content the schema cannot see, under
/// its own rule ids (`ISO-BIZ-…`). Everything written here validates under `xmllint --schema` against the
/// official XSD (the integration kit's runner asserts it) and parses under Prowide.

import Array "mo:core/Array";
import Char "mo:core/Char";
import Iter "mo:core/Iter";
import List "mo:core/List";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Nat32 "mo:core/Nat32";
import Result "mo:core/Result";
import Text "mo:core/Text";

import Xml "Xml";
import IsoSchema "IsoSchema";
import P "IsoProfiles";

module {

  /// A business-tier issue: the rule that refused, the element path, and what was found.
  public type Issue = { rule : Text; path : Text; detail : Text };

  public type Amount = { currency : Text; minor : Nat };

  /// One movement of a multilateral settlement request (camt.050 / pacs.029).
  public type Movement = { participantBic : Text; currency : Text; amount : Nat; debit : Bool };

  /// The families this module reads and writes, by message definition identifier.
  public let FAMILIES : [Text] = [
    "pacs.007.001.10", "pacs.010.001.04", "pacs.029.001.02",
    "pain.007.001.10", "pain.009.001.07", "pain.010.001.07", "pain.011.001.07", "pain.012.001.07",
    "camt.052.001.08", "camt.057.001.06", "camt.060.001.05", "camt.050.001.05", "camt.025.001.05",
    "camt.026.001.07", "camt.027.001.07", "camt.028.001.09", "camt.087.001.06",
    "admi.006.001.01", "admi.017.001.01", "head.002.001.01",
  ];

  // ─── reading: the helpers ───

  func t(e : Xml.Element, names : [Text]) : ?Text { switch (Xml.textAt(e, names)) { case (?x) ?Xml.trim(x); case null null } };
  func need(e : Xml.Element, names : [Text], path : Text, issues : List.List<Issue>) : Text {
    switch (t(e, names)) { case (?x) x; case null { List.add(issues, { rule = "ISO-BIZ-REQUIRED"; path; detail = "required element missing" }); "" } }
  };

  /// A decimal amount text into minor units of its currency. Refuses more fraction digits than the
  /// currency has, a sign, or anything that is not a decimal: the schema admits five fraction digits
  /// for any currency; the journal holds minor units, and an amount it cannot hold exactly is refused.
  public func amountMinor(text : Text, minorUnits : Nat8) : ?Nat {
    let s = Xml.trim(text);
    let parts = Array.fromIter<Text>(Text.split(s, #char '.'));
    if (parts.size() == 0 or parts.size() > 2) return null;
    let intPart = parts[0];
    let frac = if (parts.size() == 2) parts[1] else "";
    if (Text.size(intPart) == 0 and Text.size(frac) == 0) return null;
    var v : Nat = 0;
    for (c in intPart.chars()) { if (not Char.isDigit(c)) return null; v := v * 10 + Nat32.toNat(Char.toNat32(c) - 48) };
    var fd = 0;
    let mu = Nat8.toNat(minorUnits);
    for (c in frac.chars()) {
      if (not Char.isDigit(c)) return null;
      fd += 1;
      if (fd > mu) { if (c != '0') return null } else v := v * 10 + Nat32.toNat(Char.toNat32(c) - 48);
    };
    while (fd < mu) { v *= 10; fd += 1 };
    ?v
  };

  /// Minor units back to the decimal text of a currency.
  public func amountText(minor : Nat, minorUnits : Nat8) : Text {
    let mu = Nat8.toNat(minorUnits);
    if (mu == 0) return Nat.toText(minor);
    var scale = 1;
    var i = 0;
    while (i < mu) { scale *= 10; i += 1 };
    var frac = Nat.toText(minor % scale);
    while (Text.size(frac) < mu) frac := "0" # frac;
    Nat.toText(minor / scale) # "." # frac
  };

  func readAmount(e : Xml.Element, names : [Text], path : Text, minorUnitsOf : Text -> ?Nat8, issues : List.List<Issue>) : Amount {
    switch (Xml.path(e, names)) {
      case null { List.add(issues, { rule = "ISO-BIZ-REQUIRED"; path; detail = "amount missing" }); { currency = ""; minor = 0 } };
      case (?a) {
        let ccy = switch (Xml.attribute(a, "Ccy")) { case (?c) c; case null "" };
        switch (minorUnitsOf(ccy)) {
          case null { List.add(issues, { rule = "ISO-BIZ-CURRENCY"; path; detail = "currency " # ccy # " is not registered on the journal" }); { currency = ccy; minor = 0 } };
          case (?mu) {
            switch (amountMinor(a.text, mu)) {
              case (?m) { if (m == 0) List.add(issues, { rule = "ISO-BIZ-AMOUNT"; path; detail = "an amount of zero moves nothing" }); { currency = ccy; minor = m } };
              case null { List.add(issues, { rule = "ISO-BIZ-AMOUNT"; path; detail = "'" # a.text # "' is not an amount the journal can hold in " # ccy # " (" # Nat8.toText(mu) # " minor units)" }); { currency = ccy; minor = 0 } };
            }
          };
        }
      };
    }
  };

  func agentBic(e : Xml.Element, names : [Text], path : Text, issues : List.List<Issue>) : Text {
    switch (t(e, Array.concat(names, ["FinInstnId", "BICFI"]))) {
      case (?b) b;
      case null { List.add(issues, { rule = "ISO-BIZ-AGENT-BIC"; path; detail = "the agent is not identified by a BICFI" }); "" }
    }
  };

  func uetrOf(tx : Xml.Element, path : Text, issues : List.List<Issue>) : Text {
    switch (t(tx, ["PmtId", "UETR"])) {
      case (?u) u;
      case null { List.add(issues, { rule = "ISO-BIZ-UETR-REQUIRED"; path = path # "/PmtId/UETR"; detail = "every transaction carries its UETR on this rail" }); "" }
    }
  };

  func countOf(text : Text) : Nat { var v = 0; for (c in text.chars()) { if (Char.isDigit(c)) v := v * 10 + Nat32.toNat(Char.toNat32(c) - 48) }; v };
  func reason(e : Xml.Element, wrapper : Text) : (?Text, ?Text) {
    switch (Xml.child(e, wrapper)) {
      case (?r) (t(r, ["Rsn", "Cd"]), t(r, ["Rsn", "Prtry"]));
      case null (null, null);
    }
  };

  /// One booked movement of an account, as a camt.053/054 entry: the schema's `Ntry` with
  /// `NtryDtls/TxDtls` carrying the UETR in `Refs` and the journal block as the account servicer
  /// reference, so a line still names its proof.
  public type Entry = { reference : Text; amount : Amount; credit : Bool; bookingDate : Text; valueDate : Text; uetr : ?Text; endToEndId : ?Text; block : Nat; counterparty : ?Text; remittance : [Text] };

  public type Balance = { code : Text; amount : Amount; credit : Bool; date : Text };

  // ═══════════════════════════════════════════════════════════════════════════════
  // Reading: the declared target list — reversals, direct debits, the mandate cycle, the multilateral
  // settlement request, cash management and liquidity, the exceptions-and-investigations set, system
  // administration, the business file header.
  // ═══════════════════════════════════════════════════════════════════════════════

  public type DirectDebit = {
    uetr : Text;
    endToEndId : Text;
    instructionId : ?Text;
    amount : Amount;
    creditorAgent : Text;
    debtorAgent : Text;
    mandateId : ?Text;
    sequence : ?Text;           // FRST | RCUR | OOFF | FNAL
    debtorAccount : ?Text;
    debtorName : ?Text;
    creditorName : ?Text;
  };
  public type DirectDebitMessage = { family : Text; messageId : Text; creationDateTime : Text; declaredCount : Nat; transactions : [DirectDebit] };

  func accountIdOf(e : Xml.Element, names : [Text]) : ?Text {
    switch (Xml.path(e, names)) {
      case (?acct) { switch (t(acct, ["Id", "IBAN"])) { case (?i) ?i; case null t(acct, ["Id", "Othr", "Id"]) } };
      case null null;
    }
  };

  /// pacs.003.001.08 — FIToFICstmrDrctDbt: the ACH's customer direct-debit collections.
  public func readPacs003(doc : Xml.Element, minorUnitsOf : Text -> ?Nat8) : Result.Result<DirectDebitMessage, [Issue]> {
    let issues = List.empty<Issue>();
    let ?body = Xml.child(doc, "FIToFICstmrDrctDbt") else return #err([{ rule = "ISO-BIZ-REQUIRED"; path = "/Document/FIToFICstmrDrctDbt"; detail = "missing" }]);
    let messageId = need(body, ["GrpHdr", "MsgId"], "/Document/FIToFICstmrDrctDbt/GrpHdr/MsgId", issues);
    let creationDateTime = need(body, ["GrpHdr", "CreDtTm"], "/Document/FIToFICstmrDrctDbt/GrpHdr/CreDtTm", issues);
    let declaredCount = countOf(need(body, ["GrpHdr", "NbOfTxs"], "/Document/FIToFICstmrDrctDbt/GrpHdr/NbOfTxs", issues));
    let txs = List.empty<DirectDebit>();
    var i = 0;
    for (tx in Xml.children(body, "DrctDbtTxInf").vals()) {
      i += 1;
      let p = "/Document/FIToFICstmrDrctDbt/DrctDbtTxInf[" # Nat.toText(i) # "]";
      List.add(txs, {
        uetr = uetrOf(tx, p, issues);
        endToEndId = need(tx, ["PmtId", "EndToEndId"], p # "/PmtId/EndToEndId", issues);
        instructionId = t(tx, ["PmtId", "InstrId"]);
        amount = readAmount(tx, ["IntrBkSttlmAmt"], p # "/IntrBkSttlmAmt", minorUnitsOf, issues);
        creditorAgent = agentBic(tx, ["CdtrAgt"], p # "/CdtrAgt", issues);
        debtorAgent = agentBic(tx, ["DbtrAgt"], p # "/DbtrAgt", issues);
        mandateId = t(tx, ["DrctDbtTx", "MndtRltdInf", "MndtId"]);
        sequence = t(tx, ["PmtTpInf", "SeqTp"]);
        debtorAccount = accountIdOf(tx, ["DbtrAcct"]);
        debtorName = t(tx, ["Dbtr", "Nm"]);
        creditorName = t(tx, ["Cdtr", "Nm"]);
      });
    };
    if (declaredCount != List.size(txs)) List.add(issues, { rule = "ISO-BIZ-COUNT"; path = "/Document/FIToFICstmrDrctDbt/GrpHdr/NbOfTxs"; detail = "NbOfTxs says " # Nat.toText(declaredCount) # ", the message carries " # Nat.toText(List.size(txs)) });
    if (List.size(issues) > 0) return #err(List.toArray(issues));
    #ok({ family = "pacs.003"; messageId; creationDateTime; declaredCount; transactions = List.toArray(txs) })
  };

  /// pacs.010.001.04 — FIDrctDbt: an institution (the creditor, itself the participant paid) debiting
  /// other institutions; the debtor institution is the participant that pays.
  public func readPacs010(doc : Xml.Element, minorUnitsOf : Text -> ?Nat8) : Result.Result<DirectDebitMessage, [Issue]> {
    let issues = List.empty<Issue>();
    let ?body = Xml.child(doc, "FIDrctDbt") else return #err([{ rule = "ISO-BIZ-REQUIRED"; path = "/Document/FIDrctDbt"; detail = "missing" }]);
    let messageId = need(body, ["GrpHdr", "MsgId"], "/Document/FIDrctDbt/GrpHdr/MsgId", issues);
    let creationDateTime = need(body, ["GrpHdr", "CreDtTm"], "/Document/FIDrctDbt/GrpHdr/CreDtTm", issues);
    let declaredCount = countOf(need(body, ["GrpHdr", "NbOfTxs"], "/Document/FIDrctDbt/GrpHdr/NbOfTxs", issues));
    let txs = List.empty<DirectDebit>();
    var ci = 0;
    for (ci_ in Xml.children(body, "CdtInstr").vals()) {
      ci += 1;
      let cp = "/Document/FIDrctDbt/CdtInstr[" # Nat.toText(ci) # "]";
      let creditor = agentBic(ci_, ["Cdtr"], cp # "/Cdtr", issues);
      var i = 0;
      for (tx in Xml.children(ci_, "DrctDbtTxInf").vals()) {
        i += 1;
        let p = cp # "/DrctDbtTxInf[" # Nat.toText(i) # "]";
        List.add(txs, {
          uetr = uetrOf(tx, p, issues);
          endToEndId = need(tx, ["PmtId", "EndToEndId"], p # "/PmtId/EndToEndId", issues);
          instructionId = t(tx, ["PmtId", "InstrId"]);
          amount = readAmount(tx, ["IntrBkSttlmAmt"], p # "/IntrBkSttlmAmt", minorUnitsOf, issues);
          creditorAgent = creditor;
          debtorAgent = agentBic(tx, ["Dbtr"], p # "/Dbtr", issues);
          mandateId = null;
          sequence = null;
          debtorAccount = accountIdOf(tx, ["DbtrAcct"]);
          debtorName = t(tx, ["Dbtr", "FinInstnId", "Nm"]);
          creditorName = t(ci_, ["Cdtr", "FinInstnId", "Nm"]);
        });
      };
    };
    if (declaredCount != List.size(txs)) List.add(issues, { rule = "ISO-BIZ-COUNT"; path = "/Document/FIDrctDbt/GrpHdr/NbOfTxs"; detail = "NbOfTxs says " # Nat.toText(declaredCount) # ", the message carries " # Nat.toText(List.size(txs)) });
    if (List.size(issues) > 0) return #err(List.toArray(issues));
    #ok({ family = "pacs.010"; messageId; creationDateTime; declaredCount; transactions = List.toArray(txs) })
  };

  /// A reversal item (pacs.007 interbank, pain.007 customer): the original by UETR or end-to-end id,
  /// the reversed amount, the reason.
  public type ReversalItem = { reversalId : ?Text; originalUetr : ?Text; originalEndToEndId : ?Text; amount : ?Amount; reasonCode : ?Text; reasonProprietary : ?Text };
  public type Reversal = { family : Text; messageId : Text; creationDateTime : Text; declaredCount : Nat; originalMessageId : ?Text; originalMessageName : ?Text; groupReasonCode : ?Text; groupReasonProprietary : ?Text; items : [ReversalItem] };

  func optAmount(e : Xml.Element, names : [Text], path : Text, minorUnitsOf : Text -> ?Nat8, issues : List.List<Issue>) : ?Amount {
    switch (Xml.path(e, names)) { case (?_) ?readAmount(e, names, path, minorUnitsOf, issues); case null null }
  };

  /// pacs.007.001.10 — PmtRvsl.
  public func readPacs007(doc : Xml.Element, minorUnitsOf : Text -> ?Nat8) : Result.Result<Reversal, [Issue]> {
    let issues = List.empty<Issue>();
    let ?body = Xml.child(doc, "FIToFIPmtRvsl") else return #err([{ rule = "ISO-BIZ-REQUIRED"; path = "/Document/FIToFIPmtRvsl"; detail = "missing" }]);
    let messageId = need(body, ["GrpHdr", "MsgId"], "/Document/FIToFIPmtRvsl/GrpHdr/MsgId", issues);
    let creationDateTime = need(body, ["GrpHdr", "CreDtTm"], "/Document/FIToFIPmtRvsl/GrpHdr/CreDtTm", issues);
    let declaredCount = countOf(need(body, ["GrpHdr", "NbOfTxs"], "/Document/FIToFIPmtRvsl/GrpHdr/NbOfTxs", issues));
    let (gcode, gprtry) = switch (Xml.child(body, "OrgnlGrpInf")) { case (?g) reason(g, "RvslRsnInf"); case null (null, null) };
    let items = List.empty<ReversalItem>();
    var i = 0;
    for (x in Xml.children(body, "TxInf").vals()) {
      i += 1;
      let p = "/Document/FIToFIPmtRvsl/TxInf[" # Nat.toText(i) # "]";
      let (code, prtry) = reason(x, "RvslRsnInf");
      List.add(items, { reversalId = t(x, ["RvslId"]); originalUetr = t(x, ["OrgnlUETR"]); originalEndToEndId = t(x, ["OrgnlEndToEndId"]); amount = optAmount(x, ["RvsdIntrBkSttlmAmt"], p # "/RvsdIntrBkSttlmAmt", minorUnitsOf, issues); reasonCode = code; reasonProprietary = prtry });
    };
    if (declaredCount != List.size(items)) List.add(issues, { rule = "ISO-BIZ-COUNT"; path = "/Document/FIToFIPmtRvsl/GrpHdr/NbOfTxs"; detail = "NbOfTxs says " # Nat.toText(declaredCount) # ", the message carries " # Nat.toText(List.size(items)) });
    if (List.size(issues) > 0) return #err(List.toArray(issues));
    #ok({ family = "pacs.007"; messageId; creationDateTime; declaredCount; originalMessageId = t(body, ["OrgnlGrpInf", "OrgnlMsgId"]); originalMessageName = t(body, ["OrgnlGrpInf", "OrgnlMsgNmId"]); groupReasonCode = gcode; groupReasonProprietary = gprtry; items = List.toArray(items) })
  };

  /// pain.007.001.10 — CstmrPmtRvsl: the customer's reversal of collections it initiated, one TxInf
  /// per original transaction under each original payment information block.
  public func readPain007(doc : Xml.Element, minorUnitsOf : Text -> ?Nat8) : Result.Result<Reversal, [Issue]> {
    let issues = List.empty<Issue>();
    let ?body = Xml.child(doc, "CstmrPmtRvsl") else return #err([{ rule = "ISO-BIZ-REQUIRED"; path = "/Document/CstmrPmtRvsl"; detail = "missing" }]);
    let messageId = need(body, ["GrpHdr", "MsgId"], "/Document/CstmrPmtRvsl/GrpHdr/MsgId", issues);
    let creationDateTime = need(body, ["GrpHdr", "CreDtTm"], "/Document/CstmrPmtRvsl/GrpHdr/CreDtTm", issues);
    let declaredCount = countOf(need(body, ["GrpHdr", "NbOfTxs"], "/Document/CstmrPmtRvsl/GrpHdr/NbOfTxs", issues));
    let (gcode, gprtry) = switch (Xml.child(body, "OrgnlGrpInf")) { case (?g) reason(g, "RvslRsnInf"); case null (null, null) };
    let items = List.empty<ReversalItem>();
    var pi = 0;
    for (pinf in Xml.children(body, "OrgnlPmtInfAndRvsl").vals()) {
      pi += 1;
      var i = 0;
      for (x in Xml.children(pinf, "TxInf").vals()) {
        i += 1;
        let p = "/Document/CstmrPmtRvsl/OrgnlPmtInfAndRvsl[" # Nat.toText(pi) # "]/TxInf[" # Nat.toText(i) # "]";
        let (code, prtry) = reason(x, "RvslRsnInf");
        let amt = switch (optAmount(x, ["RvsdInstdAmt"], p # "/RvsdInstdAmt", minorUnitsOf, issues)) { case (?a) ?a; case null optAmount(x, ["OrgnlInstdAmt"], p # "/OrgnlInstdAmt", minorUnitsOf, issues) };
        List.add(items, { reversalId = t(x, ["RvslId"]); originalUetr = t(x, ["OrgnlUETR"]); originalEndToEndId = t(x, ["OrgnlEndToEndId"]); amount = amt; reasonCode = code; reasonProprietary = prtry });
      };
    };
    if (declaredCount != List.size(items)) List.add(issues, { rule = "ISO-BIZ-COUNT"; path = "/Document/CstmrPmtRvsl/GrpHdr/NbOfTxs"; detail = "NbOfTxs says " # Nat.toText(declaredCount) # ", the message carries " # Nat.toText(List.size(items)) });
    if (List.size(issues) > 0) return #err(List.toArray(issues));
    #ok({ family = "pain.007"; messageId; creationDateTime; declaredCount; originalMessageId = t(body, ["OrgnlGrpInf", "OrgnlMsgId"]); originalMessageName = t(body, ["OrgnlGrpInf", "OrgnlMsgNmId"]); groupReasonCode = gcode; groupReasonProprietary = gprtry; items = List.toArray(items) })
  };

  /// pacs.029.001.02 — MulSttlmReq: the scheme operator's settlement request, one instruction per
  /// settlement cycle with the movement of every participant.
  public type SettlementRequestItem = { instructionId : Text; cycle : ?Text; declaredMovements : ?Nat; movements : [Movement] };
  public type SettlementRequest = { messageId : Text; creationDateTime : Text; declaredCount : Nat; items : [SettlementRequestItem] };

  public func readPacs029(doc : Xml.Element, minorUnitsOf : Text -> ?Nat8) : Result.Result<SettlementRequest, [Issue]> {
    let issues = List.empty<Issue>();
    let ?body = Xml.child(doc, "MulSttlmReq") else return #err([{ rule = "ISO-BIZ-REQUIRED"; path = "/Document/MulSttlmReq"; detail = "missing" }]);
    let messageId = need(body, ["GrpHdr", "MsgId"], "/Document/MulSttlmReq/GrpHdr/MsgId", issues);
    let creationDateTime = need(body, ["GrpHdr", "CreDtTm"], "/Document/MulSttlmReq/GrpHdr/CreDtTm", issues);
    let declaredCount = countOf(need(body, ["GrpHdr", "NbOfSttlmReqs"], "/Document/MulSttlmReq/GrpHdr/NbOfSttlmReqs", issues));
    let items = List.empty<SettlementRequestItem>();
    var i = 0;
    for (req in Xml.children(body, "SttlmReq").vals()) {
      i += 1;
      let p = "/Document/MulSttlmReq/SttlmReq[" # Nat.toText(i) # "]";
      let moves = List.empty<Movement>();
      var j = 0;
      for (m in Xml.children(req, "MvmntRcrd").vals()) {
        j += 1;
        let mp = p # "/MvmntRcrd[" # Nat.toText(j) # "]";
        let amt = readAmount(m, ["Amt", "Amt"], mp # "/Amt/Amt", minorUnitsOf, issues);
        let bic = switch (t(m, ["Ptcpt", "Id", "OrgId", "AnyBIC"])) { case (?b) b; case null { List.add(issues, { rule = "ISO-BIZ-AGENT-BIC"; path = mp # "/Ptcpt"; detail = "a movement names its participant by AnyBIC on this rail" }); "" } };
        let debit = switch (t(m, ["Amt", "CdtDbt"])) { case (?"DBIT") true; case (?"CRDT") false; case (_) { List.add(issues, { rule = "ISO-BIZ-REQUIRED"; path = mp # "/Amt/CdtDbt"; detail = "a movement says whether the participant is debited or credited" }); true } };
        List.add(moves, { participantBic = bic; currency = amt.currency; amount = amt.minor; debit });
      };
      let declared = switch (t(req, ["NbOfMvmntRcrds"])) { case (?n) ?countOf(n); case null null };
      switch (declared) { case (?n) { if (n != List.size(moves)) List.add(issues, { rule = "ISO-BIZ-COUNT"; path = p # "/NbOfMvmntRcrds"; detail = "NbOfMvmntRcrds says " # Nat.toText(n) # ", the request carries " # Nat.toText(List.size(moves)) }) }; case null {} };
      List.add(items, { instructionId = need(req, ["InstrId"], p # "/InstrId", issues); cycle = t(req, ["SttlmCycl"]); declaredMovements = declared; movements = List.toArray(moves) });
    };
    if (declaredCount != List.size(items)) List.add(issues, { rule = "ISO-BIZ-COUNT"; path = "/Document/MulSttlmReq/GrpHdr/NbOfSttlmReqs"; detail = "NbOfSttlmReqs says " # Nat.toText(declaredCount) # ", the message carries " # Nat.toText(List.size(items)) });
    if (List.size(issues) > 0) return #err(List.toArray(issues));
    #ok({ messageId; creationDateTime; declaredCount; items = List.toArray(items) })
  };

  // ─── the mandate cycle ───

  public type MandateItem = { mandateId : Text; requestId : ?Text; sequence : Text; maxAmount : ?Amount; creditorAgent : Text; debtorAgent : Text; debtorAccount : Text; firstCollection : ?Text; finalCollection : ?Text };
  public type MandateMessage = { messageId : Text; creationDateTime : Text; mandates : [MandateItem] };

  func mandateItem(m : Xml.Element, p : Text, minorUnitsOf : Text -> ?Nat8, issues : List.List<Issue>, requireIds : Bool) : MandateItem {
    let mandateId = switch (t(m, ["MndtId"])) { case (?id) id; case null { switch (t(m, ["MndtReqId"])) { case (?r) r; case null { List.add(issues, { rule = "ISO-BIZ-REQUIRED"; path = p # "/MndtId"; detail = "a mandate carries its id or its request id" }); "" } } } };
    let sequence = switch (t(m, ["Ocrncs", "SeqTp"])) { case (?s) s; case null "RCUR" };
    let maxAmount = switch (optAmount(m, ["MaxAmt"], p # "/MaxAmt", minorUnitsOf, issues)) { case (?a) ?a; case null optAmount(m, ["ColltnAmt"], p # "/ColltnAmt", minorUnitsOf, issues) };
    let creditorAgent = if (requireIds) agentBic(m, ["CdtrAgt"], p # "/CdtrAgt", issues) else (switch (t(m, ["CdtrAgt", "FinInstnId", "BICFI"])) { case (?b) b; case null "" });
    let debtorAgent = if (requireIds) agentBic(m, ["DbtrAgt"], p # "/DbtrAgt", issues) else (switch (t(m, ["DbtrAgt", "FinInstnId", "BICFI"])) { case (?b) b; case null "" });
    let debtorAccount = switch (accountIdOf(m, ["DbtrAcct"])) { case (?a) a; case null { if (requireIds) List.add(issues, { rule = "ISO-BIZ-REQUIRED"; path = p # "/DbtrAcct"; detail = "the debtor account the mandate is over" }); "" } };
    { mandateId; requestId = t(m, ["MndtReqId"]); sequence; maxAmount; creditorAgent; debtorAgent; debtorAccount; firstCollection = t(m, ["Ocrncs", "FrstColltnDt"]); finalCollection = t(m, ["Ocrncs", "FnlColltnDt"]) }
  };

  /// pain.009.001.07 — MndtInitnReq.
  public func readPain009(doc : Xml.Element, minorUnitsOf : Text -> ?Nat8) : Result.Result<MandateMessage, [Issue]> {
    let issues = List.empty<Issue>();
    let ?body = Xml.child(doc, "MndtInitnReq") else return #err([{ rule = "ISO-BIZ-REQUIRED"; path = "/Document/MndtInitnReq"; detail = "missing" }]);
    let messageId = need(body, ["GrpHdr", "MsgId"], "/Document/MndtInitnReq/GrpHdr/MsgId", issues);
    let creationDateTime = need(body, ["GrpHdr", "CreDtTm"], "/Document/MndtInitnReq/GrpHdr/CreDtTm", issues);
    let items = List.empty<MandateItem>();
    var i = 0;
    for (m in Xml.children(body, "Mndt").vals()) { i += 1; List.add(items, mandateItem(m, "/Document/MndtInitnReq/Mndt[" # Nat.toText(i) # "]", minorUnitsOf, issues, true)) };
    if (List.size(issues) > 0) return #err(List.toArray(issues));
    #ok({ messageId; creationDateTime; mandates = List.toArray(items) })
  };

  func originalMandateId(x : Xml.Element, p : Text, issues : List.List<Issue>) : Text {
    switch (t(x, ["OrgnlMndt", "OrgnlMndtId"])) {
      case (?id) id;
      case null { switch (t(x, ["OrgnlMndt", "OrgnlMndt", "MndtId"])) { case (?id) id; case null { List.add(issues, { rule = "ISO-BIZ-REQUIRED"; path = p # "/OrgnlMndt"; detail = "the original mandate is named by its id" }); "" } } }
    }
  };
  func reasonOf(x : Xml.Element, names : [Text]) : Text {
    switch (Xml.path(x, names)) { case (?r) { switch (t(r, ["Cd"])) { case (?c) c; case null { switch (t(r, ["Prtry"])) { case (?pr) pr; case null "" } } } }; case null "" }
  };

  public type MandateAmendmentItem = { originalMandateId : Text; mandate : MandateItem; reason : Text };
  public type MandateAmendment = { messageId : Text; creationDateTime : Text; items : [MandateAmendmentItem] };
  /// pain.010.001.07 — MndtAmdmntReq.
  public func readPain010(doc : Xml.Element, minorUnitsOf : Text -> ?Nat8) : Result.Result<MandateAmendment, [Issue]> {
    let issues = List.empty<Issue>();
    let ?body = Xml.child(doc, "MndtAmdmntReq") else return #err([{ rule = "ISO-BIZ-REQUIRED"; path = "/Document/MndtAmdmntReq"; detail = "missing" }]);
    let messageId = need(body, ["GrpHdr", "MsgId"], "/Document/MndtAmdmntReq/GrpHdr/MsgId", issues);
    let creationDateTime = need(body, ["GrpHdr", "CreDtTm"], "/Document/MndtAmdmntReq/GrpHdr/CreDtTm", issues);
    let items = List.empty<MandateAmendmentItem>();
    var i = 0;
    for (x in Xml.children(body, "UndrlygAmdmntDtls").vals()) {
      i += 1;
      let p = "/Document/MndtAmdmntReq/UndrlygAmdmntDtls[" # Nat.toText(i) # "]";
      let ?m = Xml.child(x, "Mndt") else { List.add(issues, { rule = "ISO-BIZ-REQUIRED"; path = p # "/Mndt"; detail = "missing" }); continue };
      List.add(items, { originalMandateId = originalMandateId(x, p, issues); mandate = mandateItem(m, p # "/Mndt", minorUnitsOf, issues, false); reason = reasonOf(x, ["AmdmntRsn", "Rsn"]) });
    };
    if (List.size(issues) > 0) return #err(List.toArray(issues));
    #ok({ messageId; creationDateTime; items = List.toArray(items) })
  };

  public type MandateCancellationItem = { originalMandateId : Text; reason : Text };
  public type MandateCancellation = { messageId : Text; creationDateTime : Text; items : [MandateCancellationItem] };
  /// pain.011.001.07 — MndtCxlReq.
  public func readPain011(doc : Xml.Element) : Result.Result<MandateCancellation, [Issue]> {
    let issues = List.empty<Issue>();
    let ?body = Xml.child(doc, "MndtCxlReq") else return #err([{ rule = "ISO-BIZ-REQUIRED"; path = "/Document/MndtCxlReq"; detail = "missing" }]);
    let messageId = need(body, ["GrpHdr", "MsgId"], "/Document/MndtCxlReq/GrpHdr/MsgId", issues);
    let creationDateTime = need(body, ["GrpHdr", "CreDtTm"], "/Document/MndtCxlReq/GrpHdr/CreDtTm", issues);
    let items = List.empty<MandateCancellationItem>();
    var i = 0;
    for (x in Xml.children(body, "UndrlygCxlDtls").vals()) {
      i += 1;
      let p = "/Document/MndtCxlReq/UndrlygCxlDtls[" # Nat.toText(i) # "]";
      List.add(items, { originalMandateId = originalMandateId(x, p, issues); reason = reasonOf(x, ["CxlRsn", "Rsn"]) });
    };
    if (List.size(issues) > 0) return #err(List.toArray(issues));
    #ok({ messageId; creationDateTime; items = List.toArray(items) })
  };

  public type MandateAcceptanceItem = { originalMandateId : Text; accepted : Bool; reason : ?Text };
  public type MandateAcceptance = { messageId : Text; creationDateTime : Text; items : [MandateAcceptanceItem] };
  /// pain.012.001.07 — MndtAccptncRpt (read when another bank reports on a mandate this bank holds).
  public func readPain012(doc : Xml.Element) : Result.Result<MandateAcceptance, [Issue]> {
    let issues = List.empty<Issue>();
    let ?body = Xml.child(doc, "MndtAccptncRpt") else return #err([{ rule = "ISO-BIZ-REQUIRED"; path = "/Document/MndtAccptncRpt"; detail = "missing" }]);
    let messageId = need(body, ["GrpHdr", "MsgId"], "/Document/MndtAccptncRpt/GrpHdr/MsgId", issues);
    let creationDateTime = need(body, ["GrpHdr", "CreDtTm"], "/Document/MndtAccptncRpt/GrpHdr/CreDtTm", issues);
    let items = List.empty<MandateAcceptanceItem>();
    var i = 0;
    for (x in Xml.children(body, "UndrlygAccptncDtls").vals()) {
      i += 1;
      let p = "/Document/MndtAccptncRpt/UndrlygAccptncDtls[" # Nat.toText(i) # "]";
      let accepted = switch (t(x, ["AccptncRslt", "Accptd"])) { case (?"true" or ?"1") true; case (?"false" or ?"0") false; case (_) { List.add(issues, { rule = "ISO-BIZ-REQUIRED"; path = p # "/AccptncRslt/Accptd"; detail = "missing" }); false } };
      let rsn = reasonOf(x, ["AccptncRslt", "RjctRsn"]);
      List.add(items, { originalMandateId = originalMandateId(x, p, issues); accepted; reason = if (rsn == "") null else ?rsn });
    };
    if (List.size(issues) > 0) return #err(List.toArray(issues));
    #ok({ messageId; creationDateTime; items = List.toArray(items) })
  };

  // ─── cash management, liquidity, exceptions and investigations ───

  public type ReportingRequestItem = { id : ?Text; requestedMessage : Text; accountId : ?Text; ownerBic : ?Text; fromDate : ?Text; toDate : ?Text };
  public type ReportingRequest = { messageId : Text; creationDateTime : Text; items : [ReportingRequestItem] };
  /// camt.060.001.05 — AcctRptgReq.
  public func readCamt060(doc : Xml.Element) : Result.Result<ReportingRequest, [Issue]> {
    let issues = List.empty<Issue>();
    let ?body = Xml.child(doc, "AcctRptgReq") else return #err([{ rule = "ISO-BIZ-REQUIRED"; path = "/Document/AcctRptgReq"; detail = "missing" }]);
    let messageId = need(body, ["GrpHdr", "MsgId"], "/Document/AcctRptgReq/GrpHdr/MsgId", issues);
    let creationDateTime = need(body, ["GrpHdr", "CreDtTm"], "/Document/AcctRptgReq/GrpHdr/CreDtTm", issues);
    let items = List.empty<ReportingRequestItem>();
    var i = 0;
    for (x in Xml.children(body, "RptgReq").vals()) {
      i += 1;
      let p = "/Document/AcctRptgReq/RptgReq[" # Nat.toText(i) # "]";
      List.add(items, { id = t(x, ["Id"]); requestedMessage = need(x, ["ReqdMsgNmId"], p # "/ReqdMsgNmId", issues); accountId = accountIdOf(x, ["Acct"]); ownerBic = t(x, ["AcctOwnr", "Agt", "FinInstnId", "BICFI"]); fromDate = t(x, ["RptgPrd", "FrToDt", "FrDt"]); toDate = t(x, ["RptgPrd", "FrToDt", "ToDt"]) });
    };
    if (List.size(issues) > 0) return #err(List.toArray(issues));
    #ok({ messageId; creationDateTime; items = List.toArray(items) })
  };

  public type NotificationItem = { id : Text; endToEndId : ?Text; uetr : ?Text; amount : Amount; accountId : ?Text; debtorAgent : ?Text; expectedValueDate : ?Text };
  public type NotificationToReceive = { messageId : Text; creationDateTime : Text; notificationId : Text; accountId : ?Text; items : [NotificationItem] };
  /// camt.057.001.06 — NtfctnToRcv.
  public func readCamt057(doc : Xml.Element, minorUnitsOf : Text -> ?Nat8) : Result.Result<NotificationToReceive, [Issue]> {
    let issues = List.empty<Issue>();
    let ?body = Xml.child(doc, "NtfctnToRcv") else return #err([{ rule = "ISO-BIZ-REQUIRED"; path = "/Document/NtfctnToRcv"; detail = "missing" }]);
    let messageId = need(body, ["GrpHdr", "MsgId"], "/Document/NtfctnToRcv/GrpHdr/MsgId", issues);
    let creationDateTime = need(body, ["GrpHdr", "CreDtTm"], "/Document/NtfctnToRcv/GrpHdr/CreDtTm", issues);
    let ?n = Xml.child(body, "Ntfctn") else return #err([{ rule = "ISO-BIZ-REQUIRED"; path = "/Document/NtfctnToRcv/Ntfctn"; detail = "missing" }]);
    let notificationId = need(n, ["Id"], "/Document/NtfctnToRcv/Ntfctn/Id", issues);
    let items = List.empty<NotificationItem>();
    var i = 0;
    for (x in Xml.children(n, "Itm").vals()) {
      i += 1;
      let p = "/Document/NtfctnToRcv/Ntfctn/Itm[" # Nat.toText(i) # "]";
      List.add(items, { id = need(x, ["Id"], p # "/Id", issues); endToEndId = t(x, ["EndToEndId"]); uetr = t(x, ["UETR"]); amount = readAmount(x, ["Amt"], p # "/Amt", minorUnitsOf, issues); accountId = accountIdOf(x, ["Acct"]); debtorAgent = t(x, ["DbtrAgt", "FinInstnId", "BICFI"]); expectedValueDate = t(x, ["XpctdValDt"]) });
    };
    if (List.size(issues) > 0) return #err(List.toArray(issues));
    #ok({ messageId; creationDateTime; notificationId; accountId = accountIdOf(n, ["Acct"]); items = List.toArray(items) })
  };

  public type LiquidityTransfer = { messageId : Text; creationDateTime : ?Text; endToEndId : Text; instructionId : ?Text; creditorBic : ?Text; creditorAccount : ?Text; debtorBic : ?Text; debtorAccount : ?Text; amount : Amount; settlementDate : ?Text };
  /// camt.050.001.05 — LqdtyCdtTrf. The amount carries its currency on this rail (`AmtWthCcy`).
  public func readCamt050(doc : Xml.Element, minorUnitsOf : Text -> ?Nat8) : Result.Result<LiquidityTransfer, [Issue]> {
    let issues = List.empty<Issue>();
    let ?body = Xml.child(doc, "LqdtyCdtTrf") else return #err([{ rule = "ISO-BIZ-REQUIRED"; path = "/Document/LqdtyCdtTrf"; detail = "missing" }]);
    let messageId = need(body, ["MsgHdr", "MsgId"], "/Document/LqdtyCdtTrf/MsgHdr/MsgId", issues);
    let ?lt = Xml.child(body, "LqdtyCdtTrf") else return #err([{ rule = "ISO-BIZ-REQUIRED"; path = "/Document/LqdtyCdtTrf/LqdtyCdtTrf"; detail = "missing" }]);
    let p = "/Document/LqdtyCdtTrf/LqdtyCdtTrf";
    let endToEndId = need(lt, ["LqdtyTrfId", "EndToEndId"], p # "/LqdtyTrfId/EndToEndId", issues);
    let amount = switch (Xml.path(lt, ["TrfdAmt", "AmtWthCcy"])) {
      case (?_) readAmount(lt, ["TrfdAmt", "AmtWthCcy"], p # "/TrfdAmt/AmtWthCcy", minorUnitsOf, issues);
      case null { List.add(issues, { rule = "ISO-BIZ-CURRENCY"; path = p # "/TrfdAmt"; detail = "the transferred amount names its currency on this rail (AmtWthCcy)" }); { currency = ""; minor = 0 } };
    };
    if (List.size(issues) > 0) return #err(List.toArray(issues));
    #ok({ messageId; creationDateTime = t(body, ["MsgHdr", "CreDtTm"]); endToEndId; instructionId = t(lt, ["LqdtyTrfId", "InstrId"]); creditorBic = t(lt, ["Cdtr", "FinInstnId", "BICFI"]); creditorAccount = accountIdOf(lt, ["CdtrAcct"]); debtorBic = t(lt, ["Dbtr", "FinInstnId", "BICFI"]); debtorAccount = accountIdOf(lt, ["DbtrAcct"]); amount; settlementDate = t(lt, ["SttlmDt"]) })
  };

  public type Investigation = {
    family : Text; assignmentId : Text; assignerBic : ?Text; assigneeBic : ?Text; creationDateTime : Text; caseId : ?Text;
    originalMessageId : ?Text; originalMessageName : ?Text; originalUetr : ?Text; originalEndToEndId : ?Text; originalInstructionId : ?Text;
    originalAmount : ?Amount; originalSettlementDate : ?Text;
    /// camt.026: the codes of what is missing (`Justfn/MssngOrIncrrctInf/MssngInf/Cd`); empty means `AnyInf`.
    missingInformation : [Text];
    /// camt.028: the instruction for the next agent (`Inf/InstrForNxtAgt/InstrInf`).
    instruction : ?Text;
    /// camt.087: the modified interbank settlement amount (`Mod/IntrBkSttlmAmt`).
    modifiedAmount : ?Amount;
  };
  /// camt.026 (unable to apply), camt.027 (claim non-receipt), camt.028 (additional payment
  /// information), camt.087 (request to modify payment): one shape — the assignment, the case, the
  /// underlying transaction by UETR or end-to-end id.
  public func readInvestigation(doc : Xml.Element, family : Text, minorUnitsOf : Text -> ?Nat8) : Result.Result<Investigation, [Issue]> {
    let issues = List.empty<Issue>();
    let rootName = switch (family) { case ("camt.026") "UblToApply"; case ("camt.027") "ClmNonRct"; case ("camt.028") "AddtlPmtInf"; case ("camt.087") "ReqToModfyPmt"; case (_) "" };
    let ?body = Xml.child(doc, rootName) else return #err([{ rule = "ISO-BIZ-REQUIRED"; path = "/Document/" # rootName; detail = "missing" }]);
    let assignmentId = need(body, ["Assgnmt", "Id"], "/Document/" # rootName # "/Assgnmt/Id", issues);
    let creationDateTime = need(body, ["Assgnmt", "CreDtTm"], "/Document/" # rootName # "/Assgnmt/CreDtTm", issues);
    let und = Xml.child(body, "Undrlyg");
    func u(names : [Text]) : ?Text { switch (und) { case (?x) { switch (t(x, Array.concat(["IntrBk"], names))) { case (?v) ?v; case null { switch (t(x, Array.concat(["Initn"], names))) { case (?v) ?v; case null t(x, Array.concat(["StmtNtry"], names)) } } } }; case null null } };
    let ib = switch (und) { case (?x) Xml.child(x, "IntrBk"); case null null };
    let originalAmount = switch (ib) { case (?x) optAmount(x, ["OrgnlIntrBkSttlmAmt"], "/Document/" # rootName # "/Undrlyg/IntrBk/OrgnlIntrBkSttlmAmt", minorUnitsOf, issues); case null null };
    let missing = List.empty<Text>();
    switch (Xml.path(body, ["Justfn", "MssngOrIncrrctInf"])) { case (?m) { for (x in Xml.children(m, "MssngInf").vals()) { switch (t(x, ["Cd"])) { case (?c) List.add(missing, c); case null {} } } }; case null {} };
    let modifiedAmount = optAmount(body, ["Mod", "IntrBkSttlmAmt"], "/Document/" # rootName # "/Mod/IntrBkSttlmAmt", minorUnitsOf, issues);
    if (List.size(issues) > 0) return #err(List.toArray(issues));
    #ok({
      family; assignmentId; assignerBic = t(body, ["Assgnmt", "Assgnr", "Agt", "FinInstnId", "BICFI"]); assigneeBic = t(body, ["Assgnmt", "Assgne", "Agt", "FinInstnId", "BICFI"]); creationDateTime; caseId = t(body, ["Case", "Id"]);
      originalMessageId = u(["OrgnlGrpInf", "OrgnlMsgId"]); originalMessageName = u(["OrgnlGrpInf", "OrgnlMsgNmId"]);
      originalUetr = u(["OrgnlUETR"]); originalEndToEndId = u(["OrgnlEndToEndId"]); originalInstructionId = u(["OrgnlInstrId"]);
      originalAmount; originalSettlementDate = (switch (ib) { case (?x) t(x, ["OrgnlIntrBkSttlmDt"]); case null null });
      missingInformation = List.toArray(missing); instruction = t(body, ["Inf", "InstrForNxtAgt", "InstrInf"]); modifiedAmount;
    })
  };

  // ─── system administration and the file header ───

  public type ResendCriteria = { businessDate : ?Text; sequenceNumber : ?Text; originalMessageName : ?Text; fileReference : ?Text; recipientBic : ?Text };
  public type ResendRequest = { messageId : Text; creationDateTime : ?Text; originalQueryId : ?Text; criteria : [ResendCriteria] };
  /// admi.006.001.01 — RsndReq.
  public func readAdmi006(doc : Xml.Element) : Result.Result<ResendRequest, [Issue]> {
    let issues = List.empty<Issue>();
    let ?body = Xml.child(doc, "RsndReq") else return #err([{ rule = "ISO-BIZ-REQUIRED"; path = "/Document/RsndReq"; detail = "missing" }]);
    let messageId = need(body, ["MsgHdr", "MsgId"], "/Document/RsndReq/MsgHdr/MsgId", issues);
    let items = List.empty<ResendCriteria>();
    for (c in Xml.children(body, "RsndSchCrit").vals()) {
      List.add(items, { businessDate = t(c, ["BizDt"]); sequenceNumber = t(c, ["SeqNb"]); originalMessageName = t(c, ["OrgnlMsgNmId"]); fileReference = t(c, ["FileRef"]); recipientBic = t(c, ["Rcpt", "Id", "AnyBIC"]) });
    };
    if (List.size(issues) > 0) return #err(List.toArray(issues));
    #ok({ messageId; creationDateTime = t(body, ["MsgHdr", "CreDtTm"]); originalQueryId = t(body, ["MsgHdr", "OrgnlBizQry", "MsgId"]); criteria = List.toArray(items) })
  };

  public type ProcessingRequest = { messageId : Text; session : ?Text; requestType : Text; requesterBic : ?Text; additional : [Text] };
  /// admi.017.001.01 — PrcgReq.
  public func readAdmi017(doc : Xml.Element) : Result.Result<ProcessingRequest, [Issue]> {
    let issues = List.empty<Issue>();
    let ?body = Xml.child(doc, "PrcgReq") else return #err([{ rule = "ISO-BIZ-REQUIRED"; path = "/Document/PrcgReq"; detail = "missing" }]);
    let messageId = need(body, ["MsgId"], "/Document/PrcgReq/MsgId", issues);
    let requestType = need(body, ["Req", "Tp"], "/Document/PrcgReq/Req/Tp", issues);
    let extra = List.empty<Text>();
    switch (Xml.child(body, "Req")) { case (?r) { for (a in Xml.children(r, "AddtlReqInf").vals()) List.add(extra, Xml.trim(a.text)) }; case null {} };
    if (List.size(issues) > 0) return #err(List.toArray(issues));
    #ok({ messageId; session = t(body, ["SttlmSsnIdr"]); requestType; requesterBic = t(body, ["Req", "RqstrId", "AnyBIC", "AnyBIC"]); additional = List.toArray(extra) })
  };

  public type FileHeader = { payloadId : Text; creationDateTime : Text; payloadType : Text; declaredDocuments : ?Nat; possibleDuplicate : Bool; payloads : [Xml.Element] };
  /// head.002.001.01 — Xchg, the business file header: the payload description and the payloads,
  /// each one element (an AppHdr, or a Document).
  public func readHead002(xchg : Xml.Element) : Result.Result<FileHeader, [Issue]> {
    let issues = List.empty<Issue>();
    let payloadId = need(xchg, ["PyldDesc", "PyldData", "PyldIdr"], "/Xchg/PyldDesc/PyldData/PyldIdr", issues);
    let creationDateTime = need(xchg, ["PyldDesc", "PyldData", "CreDtAndTm"], "/Xchg/PyldDesc/PyldData/CreDtAndTm", issues);
    let payloadType = need(xchg, ["PyldDesc", "PyldTp"], "/Xchg/PyldDesc/PyldTp", issues);
    let declared = switch (t(xchg, ["PyldDesc", "ApplSpcfcs", "TtlNbOfDocs"])) { case (?n) ?countOf(n); case null null };
    let possibleDuplicate = switch (t(xchg, ["PyldDesc", "PyldData", "PssblDplctFlg"])) { case (?"true" or ?"1") true; case (_) false };
    let payloads = List.empty<Xml.Element>();
    for (p in Xml.children(xchg, "Pyld").vals()) { for (c in p.children.vals()) List.add(payloads, c) };
    if (List.size(issues) > 0) return #err(List.toArray(issues));
    #ok({ payloadId; creationDateTime; payloadType; declaredDocuments = declared; possibleDuplicate; payloads = List.toArray(payloads) })
  };


  // ─── the report and the receipt (families the hub also reads) ───

  /// camt.052.001.08 — BkToCstmrAcctRpt: one report over one account — balances and booked entries,
  /// the period as the schema's `FrToDt` (date-times), the request it answers in `OrgnlBizQry`.
  public type AccountReport = {
    messageId : Text; creationDateTime : Text; reportId : Text; originalQuery : ?(Text, Text);
    accountId : Text; currency : ?Text; fromDateTime : ?Text; toDateTime : ?Text; balances : [Balance]; entries : [Entry];
  };

  func readEntry(e : Xml.Element, p : Text, minorUnitsOf : Text -> ?Nat8, issues : List.List<Issue>) : Entry {
    let tx = Xml.path(e, ["NtryDtls", "TxDtls"]);
    func r(names : [Text]) : ?Text { switch (tx) { case (?x) t(x, names); case null null } };
    let credit = switch (t(e, ["CdtDbtInd"])) { case (?"CRDT") true; case (?"DBIT") false; case (_) { List.add(issues, { rule = "ISO-BIZ-REQUIRED"; path = p # "/CdtDbtInd"; detail = "an entry says whether it credits or debits" }); true } };
    let counterparty = if (credit) r(["RltdPties", "Dbtr", "Pty", "Nm"]) else r(["RltdPties", "Cdtr", "Pty", "Nm"]);
    let rmt = List.empty<Text>();
    switch (tx) { case (?x) { switch (Xml.child(x, "RmtInf")) { case (?ri) { for (u in Xml.children(ri, "Ustrd").vals()) List.add(rmt, Xml.trim(u.text)) }; case null {} } }; case null {} };
    {
      reference = switch (t(e, ["NtryRef"])) { case (?x) x; case null "" };
      amount = readAmount(e, ["Amt"], p # "/Amt", minorUnitsOf, issues);
      credit;
      bookingDate = switch (t(e, ["BookgDt", "Dt"])) { case (?x) x; case null "" };
      valueDate = switch (t(e, ["ValDt", "Dt"])) { case (?x) x; case null "" };
      uetr = r(["Refs", "UETR"]);
      endToEndId = r(["Refs", "EndToEndId"]);
      block = switch (t(e, ["AcctSvcrRef"])) { case (?x) countOf(x); case null 0 };
      counterparty;
      remittance = List.toArray(rmt);
    }
  };

  func readBalance(b : Xml.Element, p : Text, minorUnitsOf : Text -> ?Nat8, issues : List.List<Issue>) : Balance {
    let credit = switch (t(b, ["CdtDbtInd"])) { case (?"CRDT") true; case (?"DBIT") false; case (_) { List.add(issues, { rule = "ISO-BIZ-REQUIRED"; path = p # "/CdtDbtInd"; detail = "a balance says whether it is a credit or a debit" }); true } };
    { code = need(b, ["Tp", "CdOrPrtry", "Cd"], p # "/Tp/CdOrPrtry/Cd", issues); amount = readAmount(b, ["Amt"], p # "/Amt", minorUnitsOf, issues); credit; date = need(b, ["Dt", "Dt"], p # "/Dt/Dt", issues) }
  };

  public func readCamt052(doc : Xml.Element, minorUnitsOf : Text -> ?Nat8) : Result.Result<AccountReport, [Issue]> {
    let issues = List.empty<Issue>();
    let ?body = Xml.child(doc, "BkToCstmrAcctRpt") else return #err([{ rule = "ISO-BIZ-REQUIRED"; path = "/Document/BkToCstmrAcctRpt"; detail = "missing" }]);
    let messageId = need(body, ["GrpHdr", "MsgId"], "/Document/BkToCstmrAcctRpt/GrpHdr/MsgId", issues);
    let creationDateTime = need(body, ["GrpHdr", "CreDtTm"], "/Document/BkToCstmrAcctRpt/GrpHdr/CreDtTm", issues);
    let originalQuery = switch (t(body, ["GrpHdr", "OrgnlBizQry", "MsgId"]), t(body, ["GrpHdr", "OrgnlBizQry", "MsgNmId"])) { case (?id, ?name) ?(id, name); case (?id, null) ?(id, ""); case (_) null };
    let reports = Xml.children(body, "Rpt");
    if (reports.size() != 1) return #err([{ rule = "ISO-BIZ-COUNT"; path = "/Document/BkToCstmrAcctRpt/Rpt"; detail = "one report over one account (found " # Nat.toText(reports.size()) # ")" }]);
    let rpt = reports[0];
    let p = "/Document/BkToCstmrAcctRpt/Rpt";
    let reportId = need(rpt, ["Id"], p # "/Id", issues);
    let accountId = switch (accountIdOf(rpt, ["Acct"])) { case (?a) a; case null { List.add(issues, { rule = "ISO-BIZ-REQUIRED"; path = p # "/Acct/Id"; detail = "the account is identified by IBAN or Othr/Id" }); "" } };
    let bals = List.empty<Balance>();
    var i = 0;
    for (b in Xml.children(rpt, "Bal").vals()) { i += 1; List.add(bals, readBalance(b, p # "/Bal[" # Nat.toText(i) # "]", minorUnitsOf, issues)) };
    let entries = List.empty<Entry>();
    i := 0;
    for (e in Xml.children(rpt, "Ntry").vals()) { i += 1; List.add(entries, readEntry(e, p # "/Ntry[" # Nat.toText(i) # "]", minorUnitsOf, issues)) };
    if (List.size(issues) > 0) return #err(List.toArray(issues));
    #ok({ messageId; creationDateTime; reportId; originalQuery; accountId; currency = t(rpt, ["Acct", "Ccy"]); fromDateTime = t(rpt, ["FrToDt", "FrDtTm"]); toDateTime = t(rpt, ["FrToDt", "ToDtTm"]); balances = List.toArray(bals); entries = List.toArray(entries) })
  };

  /// camt.025.001.05 — Rct: a receipt for one or more messages, each with the handling status.
  public type ReceiptDetail = { originalMessageId : Text; originalMessageName : ?Text; statusCode : ?Text; description : ?Text };
  public type Receipt = { messageId : Text; creationDateTime : ?Text; details : [ReceiptDetail] };

  public func readCamt025(doc : Xml.Element) : Result.Result<Receipt, [Issue]> {
    let issues = List.empty<Issue>();
    let ?body = Xml.child(doc, "Rct") else return #err([{ rule = "ISO-BIZ-REQUIRED"; path = "/Document/Rct"; detail = "missing" }]);
    let messageId = need(body, ["MsgHdr", "MsgId"], "/Document/Rct/MsgHdr/MsgId", issues);
    let details = List.empty<ReceiptDetail>();
    var i = 0;
    for (d in Xml.children(body, "RctDtls").vals()) {
      i += 1;
      let p = "/Document/Rct/RctDtls[" # Nat.toText(i) # "]";
      List.add(details, { originalMessageId = need(d, ["OrgnlMsgId", "MsgId"], p # "/OrgnlMsgId/MsgId", issues); originalMessageName = t(d, ["OrgnlMsgId", "MsgNmId"]); statusCode = t(d, ["ReqHdlg", "StsCd"]); description = t(d, ["ReqHdlg", "Desc"]) });
    };
    if (List.size(details) == 0) List.add(issues, { rule = "ISO-BIZ-REQUIRED"; path = "/Document/Rct/RctDtls"; detail = "a receipt names at least one message" });
    if (List.size(issues) > 0) return #err(List.toArray(issues));
    #ok({ messageId; creationDateTime = t(body, ["MsgHdr", "CreDtTm"]); details = List.toArray(details) })
  };

  // ═══════════════════════════════════════════════════════════════════════════════
  // Writing. Each emitter takes the record its reader produces and writes the family's official shape:
  // the schema's required elements in the schema's order, the record's optional fields where present.
  // What the record cannot supply and the schema requires is refused, not defaulted — an emitter answers
  // `#err` with the same `ISO-BIZ-…` rule ids the readers use, so a caller sees the missing field by name.
  // The integration kit's runner shows every emitted document valid under `xmllint --schema` and equal
  // to its record after a second read.
  // ═══════════════════════════════════════════════════════════════════════════════

  public type Emitted = Result.Result<Text, [Issue]>;

  func el(indent : Nat, name : Text, value : Text) : Text { sp(indent) # "<" # name # ">" # Xml.escape(value) # "</" # name # ">\n" };
  func sp(n : Nat) : Text { var o = ""; var i = 0; while (i < n) { o #= " "; i += 1 }; o };
  func opt(indent : Nat, name : Text, v : ?Text) : Text { switch (v) { case (?x) el(indent, name, x); case null "" } };
  public func clip(t : Text, max : Nat) : Text {
    if (Text.size(t) <= max) return t;
    Text.fromIter(Iter.fromArray(Array.tabulate<Char>(max, func(i) { Text.toArray(t)[i] })))
  };
  func document(namespace : Text, body : Text) : Text {
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<Document xmlns=\"" # namespace # "\">\n" # body # "</Document>\n"
  };
  func ns(family : Text) : Text { "urn:iso:std:iso:20022:tech:xsd:" # family };

  /// A currency-and-amount element; an unregistered currency is an issue, and the text written for it
  /// is never delivered because the emitter answers `#err`.
  func amountEl(indent : Nat, name : Text, a : Amount, minorUnitsOf : Text -> ?Nat8, path : Text, issues : List.List<Issue>) : Text {
    let text = switch (minorUnitsOf(a.currency)) {
      case (?mu) amountText(a.minor, mu);
      case null { List.add(issues, { rule = "ISO-BIZ-CURRENCY"; path; detail = "currency " # a.currency # " is not registered" }); "0" };
    };
    sp(indent) # "<" # name # " Ccy=\"" # Xml.escape(a.currency) # "\">" # text # "</" # name # ">\n"
  };
  func requireText(v : ?Text, path : Text, what : Text, issues : List.List<Issue>) : Text {
    switch (v) { case (?x) x; case null { List.add(issues, { rule = "ISO-BIZ-REQUIRED"; path; detail = what }); "" } }
  };
  func agentEl(indent : Nat, name : Text, bic : Text) : Text { sp(indent) # "<" # name # "><FinInstnId><BICFI>" # Xml.escape(bic) # "</BICFI></FinInstnId></" # name # ">\n" };
  func agentOpt(indent : Nat, name : Text, bic : ?Text) : Text { switch (bic) { case (?b) agentEl(indent, name, b); case null "" } };
  func partyEl(indent : Nat, name : Text, nm : ?Text) : Text {
    switch (nm) { case (?n) sp(indent) # "<" # name # "><Nm>" # Xml.escape(clip(n, 140)) # "</Nm></" # name # ">\n"; case null sp(indent) # "<" # name # "/>\n" }
  };
  func upper(c : Char) : Bool { c >= 'A' and c <= 'Z' };
  /// An IBAN is two letters, two digits and up to thirty alphanumerics; anything else is `Othr/Id`.
  public func ibanLike(id : Text) : Bool {
    let a = Text.toArray(id);
    if (a.size() < 15 or a.size() > 34) return false;
    if (not (upper(a[0]) and upper(a[1]) and Char.isDigit(a[2]) and Char.isDigit(a[3]))) return false;
    for (c in a.vals()) { if (not (upper(c) or Char.isDigit(c))) return false };
    true
  };
  func accountEl(indent : Nat, name : Text, id : Text, currency : ?Text) : Text {
    sp(indent) # "<" # name # ">" # (if (ibanLike(id)) "<Id><IBAN>" # Xml.escape(id) # "</IBAN></Id>" else "<Id><Othr><Id>" # Xml.escape(clip(id, 34)) # "</Id></Othr></Id>") # (switch (currency) { case (?c) "<Ccy>" # Xml.escape(c) # "</Ccy>"; case null "" }) # "</" # name # ">\n"
  };
  func accountOpt(indent : Nat, name : Text, id : ?Text) : Text { switch (id) { case (?x) accountEl(indent, name, x, null); case null "" } };
  func reasonEl(indent : Nat, wrapper : Text, code : ?Text, prtry : ?Text) : Text {
    switch (code, prtry) {
      case (?c, _) sp(indent) # "<" # wrapper # "><Rsn><Cd>" # Xml.escape(clip(c, 4)) # "</Cd></Rsn></" # wrapper # ">\n";
      case (null, ?p) sp(indent) # "<" # wrapper # "><Rsn><Prtry>" # Xml.escape(clip(p, 35)) # "</Prtry></Rsn></" # wrapper # ">\n";
      case (null, null) "";
    }
  };
  func finish(text : Text, issues : List.List<Issue>) : Emitted { if (List.size(issues) > 0) #err(List.toArray(issues)) else #ok(text) };

  /// pacs.003.001.08 (customer collections) or pacs.010.001.04 (FI direct debits), by `r.family`.
  /// pacs.003 needs the settlement method, a charge bearer, the interbank settlement date and, for every
  /// transaction, the debtor account; pacs.010 groups the transactions under one creditor instruction.
  public func directDebitXml(r : DirectDebitMessage, minorUnitsOf : Text -> ?Nat8, settlementMethod : Text, chargeBearer : Text, settlementDate : Text) : Emitted {
    let issues = List.empty<Issue>();
    let n = Nat.toText(r.transactions.size());
    if (r.declaredCount != r.transactions.size()) List.add(issues, { rule = "ISO-BIZ-COUNT"; path = "/GrpHdr/NbOfTxs"; detail = "NbOfTxs says " # Nat.toText(r.declaredCount) # ", the record carries " # n });
    switch (r.family) {
      case ("pacs.003") {
        var txs = "";
        var i = 0;
        for (tx in r.transactions.vals()) {
          i += 1;
          let p = "/Document/FIToFICstmrDrctDbt/DrctDbtTxInf[" # Nat.toText(i) # "]";
          let debtorAccount = requireText(tx.debtorAccount, p # "/DbtrAcct", "pacs.003 names the debtor account", issues);
          txs #= sp(4) # "<DrctDbtTxInf>\n"
            # sp(6) # "<PmtId>" # (switch (tx.instructionId) { case (?x) "<InstrId>" # Xml.escape(clip(x, 35)) # "</InstrId>"; case null "" }) # "<EndToEndId>" # Xml.escape(clip(tx.endToEndId, 35)) # "</EndToEndId><UETR>" # Xml.escape(tx.uetr) # "</UETR></PmtId>\n"
            # (switch (tx.sequence) { case (?s) sp(6) # "<PmtTpInf><SeqTp>" # Xml.escape(s) # "</SeqTp></PmtTpInf>\n"; case null "" })
            # amountEl(6, "IntrBkSttlmAmt", tx.amount, minorUnitsOf, p # "/IntrBkSttlmAmt", issues)
            # el(6, "IntrBkSttlmDt", settlementDate)
            # el(6, "ChrgBr", chargeBearer)
            # (switch (tx.mandateId) { case (?m) sp(6) # "<DrctDbtTx><MndtRltdInf><MndtId>" # Xml.escape(clip(m, 35)) # "</MndtId></MndtRltdInf></DrctDbtTx>\n"; case null "" })
            # partyEl(6, "Cdtr", tx.creditorName)
            # agentEl(6, "CdtrAgt", tx.creditorAgent)
            # partyEl(6, "Dbtr", tx.debtorName)
            # accountEl(6, "DbtrAcct", debtorAccount, null)
            # agentEl(6, "DbtrAgt", tx.debtorAgent)
            # sp(4) # "</DrctDbtTxInf>\n";
        };
        finish(document(ns("pacs.003.001.08"), "  <FIToFICstmrDrctDbt>\n    <GrpHdr>\n" # el(6, "MsgId", clip(r.messageId, 35)) # el(6, "CreDtTm", r.creationDateTime) # el(6, "NbOfTxs", n) # sp(6) # "<SttlmInf><SttlmMtd>" # Xml.escape(settlementMethod) # "</SttlmMtd></SttlmInf>\n    </GrpHdr>\n" # txs # "  </FIToFICstmrDrctDbt>\n"), issues)
      };
      case ("pacs.010") {
        // one credit instruction per creditor, in first-seen order
        let creditors = List.empty<Text>();
        for (tx in r.transactions.vals()) { if (not List.contains(creditors, Text.equal, tx.creditorAgent)) List.add(creditors, tx.creditorAgent) };
        var instrs = "";
        var ci = 0;
        for (c in List.values(creditors)) {
          ci += 1;
          var txs = "";
          var i = 0;
          var creditorName : ?Text = null;
          for (tx in r.transactions.vals()) {
            if (tx.creditorAgent == c) {
              i += 1;
              if (creditorName == null) creditorName := tx.creditorName;
              let p = "/Document/FIDrctDbt/CdtInstr[" # Nat.toText(ci) # "]/DrctDbtTxInf[" # Nat.toText(i) # "]";
              txs #= sp(6) # "<DrctDbtTxInf>\n"
                # sp(8) # "<PmtId>" # (switch (tx.instructionId) { case (?x) "<InstrId>" # Xml.escape(clip(x, 35)) # "</InstrId>"; case null "" }) # "<EndToEndId>" # Xml.escape(clip(tx.endToEndId, 35)) # "</EndToEndId><UETR>" # Xml.escape(tx.uetr) # "</UETR></PmtId>\n"
                # amountEl(8, "IntrBkSttlmAmt", tx.amount, minorUnitsOf, p # "/IntrBkSttlmAmt", issues)
                # el(8, "IntrBkSttlmDt", settlementDate)
                # sp(8) # "<Dbtr><FinInstnId><BICFI>" # Xml.escape(tx.debtorAgent) # "</BICFI>" # (switch (tx.debtorName) { case (?nm) "<Nm>" # Xml.escape(clip(nm, 140)) # "</Nm>"; case null "" }) # "</FinInstnId></Dbtr>\n"
                # accountOpt(8, "DbtrAcct", tx.debtorAccount)
                # sp(6) # "</DrctDbtTxInf>\n";
            };
          };
          instrs #= sp(4) # "<CdtInstr>\n" # el(6, "CdtId", clip(r.messageId # "-" # Nat.toText(ci), 35))
            # sp(6) # "<Cdtr><FinInstnId><BICFI>" # Xml.escape(c) # "</BICFI>" # (switch (creditorName) { case (?nm) "<Nm>" # Xml.escape(clip(nm, 140)) # "</Nm>"; case null "" }) # "</FinInstnId></Cdtr>\n"
            # txs # sp(4) # "</CdtInstr>\n";
        };
        if (r.transactions.size() == 0) List.add(issues, { rule = "ISO-BIZ-REQUIRED"; path = "/Document/FIDrctDbt/CdtInstr"; detail = "an FI direct debit carries at least one transaction" });
        finish(document(ns("pacs.010.001.04"), "  <FIDrctDbt>\n    <GrpHdr>\n" # el(6, "MsgId", clip(r.messageId, 35)) # el(6, "CreDtTm", r.creationDateTime) # el(6, "NbOfTxs", n) # "    </GrpHdr>\n" # instrs # "  </FIDrctDbt>\n"), issues)
      };
      case (other) #err([{ rule = "ISO-BIZ-FAMILY"; path = "/"; detail = "a direct-debit record is pacs.003 or pacs.010, not " # other }]);
    }
  };

  /// pacs.007.001.10 (interbank, `settlementMethod`) or pain.007.001.10 (customer, `initiatingParty`
  /// and the original payment information id), by `r.family`. pain.007 requires the original group
  /// information; pacs.007 requires every item's reversed amount.
  public func reversalXml(r : Reversal, minorUnitsOf : Text -> ?Nat8, settlementMethod : Text, initiatingParty : ?Text, originalPaymentInfoId : Text) : Emitted {
    let issues = List.empty<Issue>();
    let n = Nat.toText(r.items.size());
    if (r.declaredCount != r.items.size()) List.add(issues, { rule = "ISO-BIZ-COUNT"; path = "/GrpHdr/NbOfTxs"; detail = "NbOfTxs says " # Nat.toText(r.declaredCount) # ", the record carries " # n });
    let groupInfo = switch (r.originalMessageId, r.originalMessageName) {
      case (?id, ?name) ?(sp(4) # "<OrgnlGrpInf>\n" # el(6, "OrgnlMsgId", clip(id, 35)) # el(6, "OrgnlMsgNmId", clip(name, 35)) # reasonEl(6, "RvslRsnInf", r.groupReasonCode, r.groupReasonProprietary) # sp(4) # "</OrgnlGrpInf>\n");
      case (_) null;
    };
    switch (r.family) {
      case ("pacs.007") {
        var txs = "";
        var i = 0;
        for (x in r.items.vals()) {
          i += 1;
          let p = "/Document/FIToFIPmtRvsl/TxInf[" # Nat.toText(i) # "]";
          let amount = switch (x.amount) { case (?a) a; case null { List.add(issues, { rule = "ISO-BIZ-REQUIRED"; path = p # "/RvsdIntrBkSttlmAmt"; detail = "pacs.007 carries the reversed interbank settlement amount" }); { currency = ""; minor = 0 } } };
          txs #= sp(4) # "<TxInf>\n" # opt(6, "RvslId", x.reversalId) # opt(6, "OrgnlEndToEndId", x.originalEndToEndId) # opt(6, "OrgnlUETR", x.originalUetr)
            # (if (x.amount != null) amountEl(6, "RvsdIntrBkSttlmAmt", amount, minorUnitsOf, p # "/RvsdIntrBkSttlmAmt", issues) else "")
            # reasonEl(6, "RvslRsnInf", x.reasonCode, x.reasonProprietary) # sp(4) # "</TxInf>\n";
        };
        finish(document(ns("pacs.007.001.10"), "  <FIToFIPmtRvsl>\n    <GrpHdr>\n" # el(6, "MsgId", clip(r.messageId, 35)) # el(6, "CreDtTm", r.creationDateTime) # el(6, "NbOfTxs", n) # sp(6) # "<SttlmInf><SttlmMtd>" # Xml.escape(settlementMethod) # "</SttlmMtd></SttlmInf>\n    </GrpHdr>\n" # (switch (groupInfo) { case (?g) g; case null "" }) # txs # "  </FIToFIPmtRvsl>\n"), issues)
      };
      case ("pain.007") {
        let gi = switch (groupInfo) { case (?g) g; case null { List.add(issues, { rule = "ISO-BIZ-REQUIRED"; path = "/Document/CstmrPmtRvsl/OrgnlGrpInf"; detail = "pain.007 names the original message (id and name)" }); "" } };
        var txs = "";
        var i = 0;
        for (x in r.items.vals()) {
          i += 1;
          let p = "/Document/CstmrPmtRvsl/OrgnlPmtInfAndRvsl/TxInf[" # Nat.toText(i) # "]";
          txs #= sp(6) # "<TxInf>\n" # opt(8, "RvslId", x.reversalId) # opt(8, "OrgnlEndToEndId", x.originalEndToEndId) # opt(8, "OrgnlUETR", x.originalUetr)
            # (switch (x.amount) { case (?a) amountEl(8, "RvsdInstdAmt", a, minorUnitsOf, p # "/RvsdInstdAmt", issues); case null "" })
            # reasonEl(8, "RvslRsnInf", x.reasonCode, x.reasonProprietary) # sp(6) # "</TxInf>\n";
        };
        finish(document(ns("pain.007.001.10"), "  <CstmrPmtRvsl>\n    <GrpHdr>\n" # el(6, "MsgId", clip(r.messageId, 35)) # el(6, "CreDtTm", r.creationDateTime) # el(6, "NbOfTxs", n) # partyEl(6, "InitgPty", initiatingParty) # "    </GrpHdr>\n" # gi
          # "    <OrgnlPmtInfAndRvsl>\n" # el(6, "OrgnlPmtInfId", clip(originalPaymentInfoId, 35)) # txs # "    </OrgnlPmtInfAndRvsl>\n  </CstmrPmtRvsl>\n"), issues)
      };
      case (other) #err([{ rule = "ISO-BIZ-FAMILY"; path = "/"; detail = "a reversal record is pacs.007 or pain.007, not " # other }]);
    }
  };

  /// pacs.029.001.02 — MulSttlmReq. The schema asks two movements or more of every request.
  public func settlementRequestXml(r : SettlementRequest, minorUnitsOf : Text -> ?Nat8, settlementMethod : ?Text) : Emitted {
    let issues = List.empty<Issue>();
    if (r.declaredCount != r.items.size()) List.add(issues, { rule = "ISO-BIZ-COUNT"; path = "/GrpHdr/NbOfSttlmReqs"; detail = "NbOfSttlmReqs says " # Nat.toText(r.declaredCount) # ", the record carries " # Nat.toText(r.items.size()) });
    if (r.items.size() == 0) List.add(issues, { rule = "ISO-BIZ-REQUIRED"; path = "/Document/MulSttlmReq/SttlmReq"; detail = "a settlement request carries at least one instruction" });
    var reqs = "";
    var i = 0;
    for (it in r.items.vals()) {
      i += 1;
      let p = "/Document/MulSttlmReq/SttlmReq[" # Nat.toText(i) # "]";
      if (it.movements.size() < 2) List.add(issues, { rule = "ISO-BIZ-COUNT"; path = p # "/MvmntRcrd"; detail = "the schema asks two movements or more" });
      switch (it.declaredMovements) { case (?d) { if (d != it.movements.size()) List.add(issues, { rule = "ISO-BIZ-COUNT"; path = p # "/NbOfMvmntRcrds"; detail = "NbOfMvmntRcrds says " # Nat.toText(d) # ", the record carries " # Nat.toText(it.movements.size()) }) }; case null {} };
      var recs = "";
      var j = 0;
      for (m in it.movements.vals()) {
        j += 1;
        recs #= sp(6) # "<MvmntRcrd>\n" # el(8, "Id", "MV" # Nat.toText(j))
          # sp(8) # "<Amt>\n" # amountEl(10, "Amt", { currency = m.currency; minor = m.amount }, minorUnitsOf, p # "/MvmntRcrd[" # Nat.toText(j) # "]/Amt/Amt", issues) # el(10, "CdtDbt", if (m.debit) "DBIT" else "CRDT") # sp(8) # "</Amt>\n"
          # sp(8) # "<Ptcpt><Id><OrgId><AnyBIC>" # Xml.escape(m.participantBic) # "</AnyBIC></OrgId></Id></Ptcpt>\n" # sp(6) # "</MvmntRcrd>\n";
      };
      reqs #= sp(4) # "<SttlmReq>\n" # el(6, "InstrId", clip(it.instructionId, 35)) # opt(6, "SttlmCycl", it.cycle) # (switch (it.declaredMovements) { case (?d) el(6, "NbOfMvmntRcrds", Nat.toText(d)); case null "" }) # recs # sp(4) # "</SttlmReq>\n";
    };
    finish(document(ns("pacs.029.001.02"), "  <MulSttlmReq>\n    <GrpHdr>\n" # el(6, "MsgId", clip(r.messageId, 35)) # el(6, "CreDtTm", r.creationDateTime) # el(6, "NbOfSttlmReqs", Nat.toText(r.items.size())) # (switch (settlementMethod) { case (?m) sp(6) # "<SttlmInf><SttlmMtd>" # Xml.escape(m) # "</SttlmMtd></SttlmInf>\n"; case null "" }) # "    </GrpHdr>\n" # reqs # "  </MulSttlmReq>\n"), issues)
  };

  func mandateBody(indent : Nat, m : MandateItem, minorUnitsOf : Text -> ?Nat8, p : Text, issues : List.List<Issue>, initiation : Bool, creditorName : ?Text, debtorName : ?Text) : Text {
    // pain.009's Mandate19 requires MndtReqId and admits MndtId; pain.010's Mandate18 requires MndtId
    let ids = if (initiation) el(indent, "MndtId", clip(m.mandateId, 35)) # el(indent, "MndtReqId", clip(requireText(m.requestId, p # "/MndtReqId", "a mandate initiation carries the request id", issues), 35))
      else el(indent, "MndtId", clip(m.mandateId, 35)) # opt(indent, "MndtReqId", m.requestId);
    ids
    # sp(indent) # "<Ocrncs><SeqTp>" # Xml.escape(m.sequence) # "</SeqTp>" # (switch (m.firstCollection) { case (?d) "<FrstColltnDt>" # d # "</FrstColltnDt>"; case null "" }) # (switch (m.finalCollection) { case (?d) "<FnlColltnDt>" # d # "</FnlColltnDt>"; case null "" }) # "</Ocrncs>\n"
    # el(indent, "TrckgInd", "false")
    # (switch (m.maxAmount) { case (?a) amountEl(indent, "MaxAmt", a, minorUnitsOf, p # "/MaxAmt", issues); case null "" })
    # (if (initiation or creditorName != null) partyEl(indent, "Cdtr", creditorName) else "")
    # (if (m.creditorAgent != "") agentEl(indent, "CdtrAgt", m.creditorAgent) else "")
    # (if (initiation or debtorName != null) partyEl(indent, "Dbtr", debtorName) else "")
    # (if (m.debtorAccount != "") accountEl(indent, "DbtrAcct", m.debtorAccount, null) else "")
    # (if (initiation or m.debtorAgent != "") agentEl(indent, "DbtrAgt", (if (m.debtorAgent == "") requireText(null, p # "/DbtrAgt", "a mandate initiation names the debtor agent", issues) else m.debtorAgent)) else "")
  };
  func groupHeader(messageId : Text, creationDateTime : Text, initiatingParty : ?Text) : Text {
    "    <GrpHdr>\n" # el(6, "MsgId", clip(messageId, 35)) # el(6, "CreDtTm", creationDateTime) # partyEl(6, "InitgPty", initiatingParty) # "    </GrpHdr>\n"
  };

  /// pain.009.001.07 — MndtInitnReq.
  public func mandateInitiationXml(r : MandateMessage, minorUnitsOf : Text -> ?Nat8, initiatingParty : ?Text, creditorName : ?Text, debtorName : ?Text) : Emitted {
    let issues = List.empty<Issue>();
    if (r.mandates.size() == 0) List.add(issues, { rule = "ISO-BIZ-REQUIRED"; path = "/Document/MndtInitnReq/Mndt"; detail = "an initiation carries at least one mandate" });
    var body = "";
    var i = 0;
    for (m in r.mandates.vals()) { i += 1; body #= sp(4) # "<Mndt>\n" # mandateBody(6, m, minorUnitsOf, "/Document/MndtInitnReq/Mndt[" # Nat.toText(i) # "]", issues, true, creditorName, debtorName) # sp(4) # "</Mndt>\n" };
    finish(document(ns("pain.009.001.07"), "  <MndtInitnReq>\n" # groupHeader(r.messageId, r.creationDateTime, initiatingParty) # body # "  </MndtInitnReq>\n"), issues)
  };

  /// A mandate reason: four upper-case alphanumerics are an external code, anything else is proprietary.
  /// The amendment and cancellation wrap the choice in `Rsn`; the acceptance report's `RjctRsn` is the choice itself.
  func mandateReason(indent : Nat, wrapper : Text, reason : Text, withRsn : Bool) : Text {
    let a = Text.toArray(reason);
    var code = a.size() == 4;
    for (c in a.vals()) { if (not (upper(c) or Char.isDigit(c))) code := false };
    let choice = if (code) "<Cd>" # Xml.escape(reason) # "</Cd>" else "<Prtry>" # Xml.escape(clip(reason, 35)) # "</Prtry>";
    sp(indent) # "<" # wrapper # ">" # (if (withRsn) "<Rsn>" # choice # "</Rsn>" else choice) # "</" # wrapper # ">\n"
  };

  /// pain.010.001.07 — MndtAmdmntReq.
  public func mandateAmendmentXml(r : MandateAmendment, minorUnitsOf : Text -> ?Nat8, initiatingParty : ?Text) : Emitted {
    let issues = List.empty<Issue>();
    if (r.items.size() == 0) List.add(issues, { rule = "ISO-BIZ-REQUIRED"; path = "/Document/MndtAmdmntReq/UndrlygAmdmntDtls"; detail = "an amendment carries at least one mandate" });
    var body = "";
    var i = 0;
    for (x in r.items.vals()) {
      i += 1;
      let p = "/Document/MndtAmdmntReq/UndrlygAmdmntDtls[" # Nat.toText(i) # "]";
      if (x.reason == "") List.add(issues, { rule = "ISO-BIZ-REQUIRED"; path = p # "/AmdmntRsn/Rsn"; detail = "an amendment states its reason" });
      body #= sp(4) # "<UndrlygAmdmntDtls>\n" # mandateReason(6, "AmdmntRsn", x.reason, true) # sp(6) # "<Mndt>\n" # mandateBody(8, x.mandate, minorUnitsOf, p # "/Mndt", issues, false, null, null) # sp(6) # "</Mndt>\n"
        # sp(6) # "<OrgnlMndt><OrgnlMndtId>" # Xml.escape(clip(x.originalMandateId, 35)) # "</OrgnlMndtId></OrgnlMndt>\n" # sp(4) # "</UndrlygAmdmntDtls>\n";
    };
    finish(document(ns("pain.010.001.07"), "  <MndtAmdmntReq>\n" # groupHeader(r.messageId, r.creationDateTime, initiatingParty) # body # "  </MndtAmdmntReq>\n"), issues)
  };

  /// pain.011.001.07 — MndtCxlReq.
  public func mandateCancellationXml(r : MandateCancellation, initiatingParty : ?Text) : Emitted {
    let issues = List.empty<Issue>();
    if (r.items.size() == 0) List.add(issues, { rule = "ISO-BIZ-REQUIRED"; path = "/Document/MndtCxlReq/UndrlygCxlDtls"; detail = "a cancellation names at least one mandate" });
    var body = "";
    var i = 0;
    for (x in r.items.vals()) {
      i += 1;
      if (x.reason == "") List.add(issues, { rule = "ISO-BIZ-REQUIRED"; path = "/Document/MndtCxlReq/UndrlygCxlDtls[" # Nat.toText(i) # "]/CxlRsn/Rsn"; detail = "a cancellation states its reason" });
      body #= sp(4) # "<UndrlygCxlDtls>\n" # mandateReason(6, "CxlRsn", x.reason, true) # sp(6) # "<OrgnlMndt><OrgnlMndtId>" # Xml.escape(clip(x.originalMandateId, 35)) # "</OrgnlMndtId></OrgnlMndt>\n" # sp(4) # "</UndrlygCxlDtls>\n";
    };
    finish(document(ns("pain.011.001.07"), "  <MndtCxlReq>\n" # groupHeader(r.messageId, r.creationDateTime, initiatingParty) # body # "  </MndtCxlReq>\n"), issues)
  };

  /// pain.012.001.07 — MndtAccptncRpt, one acceptance detail per item; `originalMessage` names the
  /// request answered (id, message name) when known.
  public func mandateAcceptanceXml(r : MandateAcceptance, initiatingParty : ?Text, originalMessage : ?(Text, Text)) : Emitted {
    let issues = List.empty<Issue>();
    if (r.items.size() == 0) List.add(issues, { rule = "ISO-BIZ-REQUIRED"; path = "/Document/MndtAccptncRpt/UndrlygAccptncDtls"; detail = "a report decides at least one mandate" });
    let omi = switch (originalMessage) { case (?(id, name)) sp(6) # "<OrgnlMsgInf><MsgId>" # Xml.escape(clip(id, 35)) # "</MsgId><MsgNmId>" # Xml.escape(clip(name, 35)) # "</MsgNmId></OrgnlMsgInf>\n"; case null "" };
    var body = "";
    for (x in r.items.vals()) {
      // the reader keeps the rejection reason only, so an accepted item is written without one
      let rj = switch (x.reason) { case (?rs) { if (x.accepted) "" else mandateReason(8, "RjctRsn", rs, false) }; case null "" };
      body #= sp(4) # "<UndrlygAccptncDtls>\n" # omi # sp(6) # "<AccptncRslt>\n" # el(8, "Accptd", if (x.accepted) "true" else "false") # rj
        # sp(6) # "</AccptncRslt>\n" # sp(6) # "<OrgnlMndt><OrgnlMndtId>" # Xml.escape(clip(x.originalMandateId, 35)) # "</OrgnlMndtId></OrgnlMndt>\n" # sp(4) # "</UndrlygAccptncDtls>\n";
    };
    finish(document(ns("pain.012.001.07"), "  <MndtAccptncRpt>\n" # groupHeader(r.messageId, r.creationDateTime, initiatingParty) # body # "  </MndtAccptncRpt>\n"), issues)
  };

  /// camt.060.001.05 — AcctRptgReq. The schema requires the account owner: an agent BIC here.
  public func reportingRequestXml(r : ReportingRequest) : Emitted {
    let issues = List.empty<Issue>();
    if (r.items.size() == 0) List.add(issues, { rule = "ISO-BIZ-REQUIRED"; path = "/Document/AcctRptgReq/RptgReq"; detail = "a reporting request asks for at least one report" });
    var body = "";
    var i = 0;
    for (x in r.items.vals()) {
      i += 1;
      let p = "/Document/AcctRptgReq/RptgReq[" # Nat.toText(i) # "]";
      let owner = requireText(x.ownerBic, p # "/AcctOwnr", "the account owner is named by its agent BIC", issues);
      let period = switch (x.fromDate) {
        case (?f) sp(6) # "<RptgPrd><FrToDt><FrDt>" # f # "</FrDt>" # (switch (x.toDate) { case (?to) "<ToDt>" # to # "</ToDt>"; case null "" }) # "</FrToDt><Tp>ALLL</Tp></RptgPrd>\n";
        case null { switch (x.toDate) { case (?_) { List.add(issues, { rule = "ISO-BIZ-REQUIRED"; path = p # "/RptgPrd/FrToDt/FrDt"; detail = "a period with an end has a start" }); "" }; case null "" } };
      };
      body #= sp(4) # "<RptgReq>\n" # opt(6, "Id", x.id) # el(6, "ReqdMsgNmId", clip(x.requestedMessage, 35)) # accountOpt(6, "Acct", x.accountId)
        # sp(6) # "<AcctOwnr><Agt><FinInstnId><BICFI>" # Xml.escape(owner) # "</BICFI></FinInstnId></Agt></AcctOwnr>\n" # period # sp(4) # "</RptgReq>\n";
    };
    finish(document(ns("camt.060.001.05"), "  <AcctRptgReq>\n    <GrpHdr>\n" # el(6, "MsgId", clip(r.messageId, 35)) # el(6, "CreDtTm", r.creationDateTime) # "    </GrpHdr>\n" # body # "  </AcctRptgReq>\n"), issues)
  };

  /// camt.057.001.06 — NtfctnToRcv.
  public func notificationToReceiveXml(r : NotificationToReceive, minorUnitsOf : Text -> ?Nat8) : Emitted {
    let issues = List.empty<Issue>();
    if (r.items.size() == 0) List.add(issues, { rule = "ISO-BIZ-REQUIRED"; path = "/Document/NtfctnToRcv/Ntfctn/Itm"; detail = "a notification carries at least one item" });
    var body = "";
    var i = 0;
    for (x in r.items.vals()) {
      i += 1;
      let p = "/Document/NtfctnToRcv/Ntfctn/Itm[" # Nat.toText(i) # "]";
      body #= sp(6) # "<Itm>\n" # el(8, "Id", clip(x.id, 35)) # opt(8, "EndToEndId", x.endToEndId) # opt(8, "UETR", x.uetr) # accountOpt(8, "Acct", x.accountId)
        # amountEl(8, "Amt", x.amount, minorUnitsOf, p # "/Amt", issues) # opt(8, "XpctdValDt", x.expectedValueDate) # agentOpt(8, "DbtrAgt", x.debtorAgent) # sp(6) # "</Itm>\n";
    };
    finish(document(ns("camt.057.001.06"), "  <NtfctnToRcv>\n    <GrpHdr>\n" # el(6, "MsgId", clip(r.messageId, 35)) # el(6, "CreDtTm", r.creationDateTime) # "    </GrpHdr>\n    <Ntfctn>\n" # el(6, "Id", clip(r.notificationId, 35)) # accountOpt(6, "Acct", r.accountId) # body # "    </Ntfctn>\n  </NtfctnToRcv>\n"), issues)
  };

  /// camt.050.001.05 — LqdtyCdtTrf, the amount with its currency (`AmtWthCcy`).
  public func liquidityTransferXml(r : LiquidityTransfer, minorUnitsOf : Text -> ?Nat8) : Emitted {
    let issues = List.empty<Issue>();
    let p = "/Document/LqdtyCdtTrf/LqdtyCdtTrf";
    let body = "  <LqdtyCdtTrf>\n    <MsgHdr>\n" # el(6, "MsgId", clip(r.messageId, 35)) # opt(6, "CreDtTm", r.creationDateTime) # "    </MsgHdr>\n    <LqdtyCdtTrf>\n"
      # sp(6) # "<LqdtyTrfId>" # (switch (r.instructionId) { case (?x) "<InstrId>" # Xml.escape(clip(x, 35)) # "</InstrId>"; case null "" }) # "<EndToEndId>" # Xml.escape(clip(r.endToEndId, 35)) # "</EndToEndId></LqdtyTrfId>\n"
      # agentOpt(6, "Cdtr", r.creditorBic) # accountOpt(6, "CdtrAcct", r.creditorAccount)
      # sp(6) # "<TrfdAmt>\n" # amountEl(8, "AmtWthCcy", r.amount, minorUnitsOf, p # "/TrfdAmt/AmtWthCcy", issues) # sp(6) # "</TrfdAmt>\n"
      # agentOpt(6, "Dbtr", r.debtorBic) # accountOpt(6, "DbtrAcct", r.debtorAccount) # opt(6, "SttlmDt", r.settlementDate)
      # "    </LqdtyCdtTrf>\n  </LqdtyCdtTrf>\n";
    finish(document(ns("camt.050.001.05"), body), issues)
  };

  /// camt.026 / 027 / 028 / 087 by `r.family`: the assignment, the case, the underlying interbank
  /// transaction (the schema requires its original amount and settlement date), and the family's own
  /// part — camt.026's justification, camt.028's information, camt.087's modification.
  public func investigationXml(r : Investigation, minorUnitsOf : Text -> ?Nat8) : Emitted {
    let issues = List.empty<Issue>();
    let (family, rootName) = switch (r.family) {
      case ("camt.026") ("camt.026.001.07", "UblToApply"); case ("camt.027") ("camt.027.001.07", "ClmNonRct");
      case ("camt.028") ("camt.028.001.09", "AddtlPmtInf"); case ("camt.087") ("camt.087.001.06", "ReqToModfyPmt");
      case (other) return #err([{ rule = "ISO-BIZ-FAMILY"; path = "/"; detail = "an investigation record is camt.026, camt.027, camt.028 or camt.087, not " # other }]);
    };
    let p = "/Document/" # rootName;
    let assigner = requireText(r.assignerBic, p # "/Assgnmt/Assgnr", "the assigner is named by its agent BIC", issues);
    let assignee = requireText(r.assigneeBic, p # "/Assgnmt/Assgne", "the assignee is named by its agent BIC", issues);
    let origAmount = switch (r.originalAmount) { case (?a) amountEl(8, "OrgnlIntrBkSttlmAmt", a, minorUnitsOf, p # "/Undrlyg/IntrBk/OrgnlIntrBkSttlmAmt", issues); case null { List.add(issues, { rule = "ISO-BIZ-REQUIRED"; path = p # "/Undrlyg/IntrBk/OrgnlIntrBkSttlmAmt"; detail = "the underlying transaction carries its original interbank settlement amount" }); "" } };
    let origDate = requireText(r.originalSettlementDate, p # "/Undrlyg/IntrBk/OrgnlIntrBkSttlmDt", "the underlying transaction carries its original settlement date", issues);
    let groupInfo = switch (r.originalMessageId, r.originalMessageName) { case (?id, ?name) sp(8) # "<OrgnlGrpInf><OrgnlMsgId>" # Xml.escape(clip(id, 35)) # "</OrgnlMsgId><OrgnlMsgNmId>" # Xml.escape(clip(name, 35)) # "</OrgnlMsgNmId></OrgnlGrpInf>\n"; case (_) "" };
    let tail = switch (r.family) {
      case ("camt.026") {
        if (r.missingInformation.size() == 0) sp(4) # "<Justfn><AnyInf>true</AnyInf></Justfn>\n"
        else { var m = ""; for (c in r.missingInformation.vals()) m #= "<MssngInf><Cd>" # Xml.escape(c) # "</Cd></MssngInf>"; sp(4) # "<Justfn><MssngOrIncrrctInf>" # m # "</MssngOrIncrrctInf></Justfn>\n" }
      };
      case ("camt.028") sp(4) # "<Inf>" # (switch (r.instruction) { case (?x) "<InstrForNxtAgt><InstrInf>" # Xml.escape(clip(x, 140)) # "</InstrInf></InstrForNxtAgt>"; case null "" }) # "</Inf>\n";
      case ("camt.087") sp(4) # "<Mod>\n" # (switch (r.modifiedAmount) { case (?a) amountEl(6, "IntrBkSttlmAmt", a, minorUnitsOf, p # "/Mod/IntrBkSttlmAmt", issues); case null "" }) # sp(4) # "</Mod>\n";
      case (_) "";
    };
    let body = "  <" # rootName # ">\n    <Assgnmt>\n" # el(6, "Id", clip(r.assignmentId, 35))
      # sp(6) # "<Assgnr><Agt><FinInstnId><BICFI>" # Xml.escape(assigner) # "</BICFI></FinInstnId></Agt></Assgnr>\n"
      # sp(6) # "<Assgne><Agt><FinInstnId><BICFI>" # Xml.escape(assignee) # "</BICFI></FinInstnId></Agt></Assgne>\n"
      # el(6, "CreDtTm", r.creationDateTime) # "    </Assgnmt>\n"
      # (switch (r.caseId) { case (?c) sp(4) # "<Case><Id>" # Xml.escape(clip(c, 35)) # "</Id><Cretr><Agt><FinInstnId><BICFI>" # Xml.escape(assigner) # "</BICFI></FinInstnId></Agt></Cretr></Case>\n"; case null "" })
      # "    <Undrlyg>\n      <IntrBk>\n" # groupInfo # opt(8, "OrgnlInstrId", r.originalInstructionId) # opt(8, "OrgnlEndToEndId", r.originalEndToEndId) # opt(8, "OrgnlUETR", r.originalUetr) # origAmount # el(8, "OrgnlIntrBkSttlmDt", origDate) # "      </IntrBk>\n    </Undrlyg>\n"
      # tail # "  </" # rootName # ">\n";
    finish(document(ns(family), body), issues)
  };

  /// admi.006.001.01 — RsndReq. The schema requires each criterion's recipient: an AnyBIC here.
  public func resendRequestXml(r : ResendRequest) : Emitted {
    let issues = List.empty<Issue>();
    if (r.criteria.size() == 0) List.add(issues, { rule = "ISO-BIZ-REQUIRED"; path = "/Document/RsndReq/RsndSchCrit"; detail = "a resend request carries at least one search criterion" });
    var body = "";
    var i = 0;
    for (c in r.criteria.vals()) {
      i += 1;
      let rcpt = requireText(c.recipientBic, "/Document/RsndReq/RsndSchCrit[" # Nat.toText(i) # "]/Rcpt", "the recipient is named by its BIC", issues);
      body #= sp(4) # "<RsndSchCrit>\n" # opt(6, "BizDt", c.businessDate) # opt(6, "SeqNb", c.sequenceNumber) # opt(6, "OrgnlMsgNmId", c.originalMessageName) # opt(6, "FileRef", c.fileReference)
        # sp(6) # "<Rcpt><Id><AnyBIC>" # Xml.escape(rcpt) # "</AnyBIC></Id></Rcpt>\n" # sp(4) # "</RsndSchCrit>\n";
    };
    let hdr = "    <MsgHdr>\n" # el(6, "MsgId", clip(r.messageId, 35)) # opt(6, "CreDtTm", r.creationDateTime) # (switch (r.originalQueryId) { case (?q) sp(6) # "<OrgnlBizQry><MsgId>" # Xml.escape(clip(q, 35)) # "</MsgId></OrgnlBizQry>\n"; case null "" }) # "    </MsgHdr>\n";
    finish(document(ns("admi.006.001.01"), "  <RsndReq>\n" # hdr # body # "  </RsndReq>\n"), issues)
  };

  /// admi.017.001.01 — PrcgReq.
  public func processingRequestXml(r : ProcessingRequest) : Emitted {
    let issues = List.empty<Issue>();
    if (r.requestType == "") List.add(issues, { rule = "ISO-BIZ-REQUIRED"; path = "/Document/PrcgReq/Req/Tp"; detail = "a processing request says what it asks for" });
    var extra = "";
    for (a in r.additional.vals()) extra #= el(6, "AddtlReqInf", clip(a, 35));
    let body = "  <PrcgReq>\n" # el(4, "MsgId", clip(r.messageId, 35)) # opt(4, "SttlmSsnIdr", r.session) # "    <Req>\n" # el(6, "Tp", clip(r.requestType, 35))
      # (switch (r.requesterBic) { case (?b) sp(6) # "<RqstrId><AnyBIC><AnyBIC>" # Xml.escape(b) # "</AnyBIC></AnyBIC></RqstrId>\n"; case null "" }) # extra # "    </Req>\n  </PrcgReq>\n";
    finish(document(ns("admi.017.001.01"), body), issues)
  };

  /// head.002.001.01 — Xchg: the payload description and the payloads, each serialized as it was read.
  public func fileHeaderXml(r : FileHeader) : Emitted {
    let issues = List.empty<Issue>();
    switch (r.declaredDocuments) { case (?d) { if (d != r.payloads.size()) List.add(issues, { rule = "ISO-BIZ-COUNT"; path = "/Xchg/PyldDesc/ApplSpcfcs/TtlNbOfDocs"; detail = "TtlNbOfDocs says " # Nat.toText(d) # ", the file carries " # Nat.toText(r.payloads.size()) }) }; case null {} };
    var pl = "";
    for (p in r.payloads.vals()) pl #= "  <Pyld>" # Xml.serializeBody(p) # "</Pyld>\n";
    let n = Nat.toText(r.payloads.size());
    let text = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<Xchg xmlns=\"" # ns("head.002.001.01") # "\">\n  <PyldDesc>\n"
      # sp(4) # "<PyldData><PyldIdr>" # Xml.escape(clip(r.payloadId, 35)) # "</PyldIdr><CreDtAndTm>" # Xml.escape(r.creationDateTime) # "</CreDtAndTm><PssblDplctFlg>" # (if (r.possibleDuplicate) "true" else "false") # "</PssblDplctFlg></PyldData>\n"
      # (switch (r.declaredDocuments) { case (?d) sp(4) # "<ApplSpcfcs><TtlNbOfDocs>" # Nat.toText(d) # "</TtlNbOfDocs></ApplSpcfcs>\n"; case null "" })
      # el(4, "PyldTp", clip(r.payloadType, 256))
      # sp(4) # "<MnfstData><DocTp>" # Xml.escape(clip(r.payloadType, 35)) # "</DocTp><NbOfDocs>" # n # "</NbOfDocs></MnfstData>\n"
      # "  </PyldDesc>\n" # pl # "</Xchg>\n";
    finish(text, issues)
  };

  func entryXml(indent : Nat, e : Entry, minorUnitsOf : Text -> ?Nat8, p : Text, issues : List.List<Issue>) : Text {
    let i = indent;
    var rmt = "";
    for (line in e.remittance.vals()) rmt #= el(i + 8, "Ustrd", clip(line, 140));
    let refs = (if (e.block > 0) el(i + 8, "AcctSvcrRef", Nat.toText(e.block)) else "") # opt(i + 8, "EndToEndId", e.endToEndId) # opt(i + 8, "UETR", e.uetr);
    let details = (if (refs != "") sp(i + 6) # "<Refs>\n" # refs # sp(i + 6) # "</Refs>\n" else "")
      # (switch (e.counterparty) { case (?c) sp(i + 6) # "<RltdPties>" # (if (e.credit) "<Dbtr><Pty><Nm>" # Xml.escape(clip(c, 140)) # "</Nm></Pty></Dbtr>" else "<Cdtr><Pty><Nm>" # Xml.escape(clip(c, 140)) # "</Nm></Pty></Cdtr>") # "</RltdPties>\n"; case null "" })
      # (if (e.remittance.size() > 0) sp(i + 6) # "<RmtInf>\n" # rmt # sp(i + 6) # "</RmtInf>\n" else "");
    sp(i) # "<Ntry>\n"
    # (if (e.reference != "") el(i + 2, "NtryRef", clip(e.reference, 35)) else "")
    # amountEl(i + 2, "Amt", e.amount, minorUnitsOf, p # "/Amt", issues)
    # el(i + 2, "CdtDbtInd", if (e.credit) "CRDT" else "DBIT")
    # sp(i + 2) # "<Sts><Cd>BOOK</Cd></Sts>\n"
    # (if (e.bookingDate != "") sp(i + 2) # "<BookgDt><Dt>" # Xml.escape(e.bookingDate) # "</Dt></BookgDt>\n" else "")
    # (if (e.valueDate != "") sp(i + 2) # "<ValDt><Dt>" # Xml.escape(e.valueDate) # "</Dt></ValDt>\n" else "")
    # (if (e.block > 0) el(i + 2, "AcctSvcrRef", Nat.toText(e.block)) else "")
    # sp(i + 2) # "<BkTxCd><Prtry><Cd>PMNT</Cd></Prtry></BkTxCd>\n"
    # (if (details != "") sp(i + 2) # "<NtryDtls><TxDtls>\n" # details # sp(i + 2) # "</TxDtls></NtryDtls>\n" else "")
    # sp(i) # "</Ntry>\n"
  };

  func balanceXml(indent : Nat, b : Balance, minorUnitsOf : Text -> ?Nat8, p : Text, issues : List.List<Issue>) : Text {
    sp(indent) # "<Bal>\n"
    # sp(indent + 2) # "<Tp><CdOrPrtry><Cd>" # Xml.escape(clip(b.code, 4)) # "</Cd></CdOrPrtry></Tp>\n"
    # amountEl(indent + 2, "Amt", b.amount, minorUnitsOf, p # "/Amt", issues)
    # el(indent + 2, "CdtDbtInd", if (b.credit) "CRDT" else "DBIT")
    # sp(indent + 2) # "<Dt><Dt>" # Xml.escape(b.date) # "</Dt></Dt>\n"
    # sp(indent) # "</Bal>\n"
  };

  /// camt.052.001.08 — BkToCstmrAcctRpt.
  public func accountReportXml(r : AccountReport, minorUnitsOf : Text -> ?Nat8) : Emitted {
    let issues = List.empty<Issue>();
    let p = "/Document/BkToCstmrAcctRpt/Rpt";
    var bals = ""; var i = 0;
    for (b in r.balances.vals()) { i += 1; bals #= balanceXml(6, b, minorUnitsOf, p # "/Bal[" # Nat.toText(i) # "]", issues) };
    var body = ""; i := 0;
    for (e in r.entries.vals()) { i += 1; body #= entryXml(6, e, minorUnitsOf, p # "/Ntry[" # Nat.toText(i) # "]", issues) };
    let obq = switch (r.originalQuery) { case (?(id, name)) sp(6) # "<OrgnlBizQry><MsgId>" # Xml.escape(clip(id, 35)) # "</MsgId>" # (if (name != "") "<MsgNmId>" # Xml.escape(clip(name, 35)) # "</MsgNmId>" else "") # "</OrgnlBizQry>\n"; case null "" };
    let period = switch (r.fromDateTime, r.toDateTime) {
      case (?f, ?to) sp(6) # "<FrToDt><FrDtTm>" # Xml.escape(f) # "</FrDtTm><ToDtTm>" # Xml.escape(to) # "</ToDtTm></FrToDt>\n";
      case (null, null) "";
      case (_) { List.add(issues, { rule = "ISO-BIZ-REQUIRED"; path = p # "/FrToDt"; detail = "a period has both its start and its end" }); "" };
    };
    if (r.accountId == "") List.add(issues, { rule = "ISO-BIZ-REQUIRED"; path = p # "/Acct/Id"; detail = "the report names its account" });
    finish(document(ns("camt.052.001.08"), "  <BkToCstmrAcctRpt>\n    <GrpHdr>\n" # el(6, "MsgId", clip(r.messageId, 35)) # el(6, "CreDtTm", r.creationDateTime) # obq # "    </GrpHdr>\n    <Rpt>\n"
      # el(6, "Id", clip(r.reportId, 35)) # el(6, "CreDtTm", r.creationDateTime) # period # accountEl(6, "Acct", r.accountId, r.currency) # bals # body # "    </Rpt>\n  </BkToCstmrAcctRpt>\n"), issues)
  };

  /// camt.025.001.05 — Rct.
  public func receiptXml(r : Receipt) : Emitted {
    let issues = List.empty<Issue>();
    if (r.details.size() == 0) List.add(issues, { rule = "ISO-BIZ-REQUIRED"; path = "/Document/Rct/RctDtls"; detail = "a receipt names at least one message" });
    var body = "";
    for (d in r.details.vals()) {
      let handling = switch (d.statusCode) { case (?s) sp(6) # "<ReqHdlg>\n" # el(8, "StsCd", clip(s, 4)) # opt(8, "Desc", switch (d.description) { case (?x) ?clip(x, 140); case null null }) # sp(6) # "</ReqHdlg>\n"; case null "" };
      body #= "    <RctDtls>\n" # sp(6) # "<OrgnlMsgId><MsgId>" # Xml.escape(clip(d.originalMessageId, 35)) # "</MsgId>" # (switch (d.originalMessageName) { case (?n) "<MsgNmId>" # Xml.escape(clip(n, 35)) # "</MsgNmId>"; case null "" }) # "</OrgnlMsgId>\n" # handling # "    </RctDtls>\n";
    };
    finish(document(ns("camt.025.001.05"), "  <Rct>\n    <MsgHdr>\n" # el(6, "MsgId", clip(r.messageId, 35)) # opt(6, "CreDtTm", r.creationDateTime) # "    </MsgHdr>\n" # body # "  </Rct>\n"), issues)
  };

  // ═══════════════════════════════════════════════════════════════════════════════
  // The message as a whole: parse, identify the family by namespace, validate against the official
  // schema profile, read the business content; and back — write the record, and read it again.
  // ═══════════════════════════════════════════════════════════════════════════════

  /// The typed content of one message of the target list.
  public type Message = {
    #directDebit : DirectDebitMessage;
    #reversal : Reversal;
    #settlementRequest : SettlementRequest;
    #mandateInitiation : MandateMessage;
    #mandateAmendment : MandateAmendment;
    #mandateCancellation : MandateCancellation;
    #mandateAcceptance : MandateAcceptance;
    #reportingRequest : ReportingRequest;
    #notificationToReceive : NotificationToReceive;
    #liquidityTransfer : LiquidityTransfer;
    #investigation : Investigation;
    #resendRequest : ResendRequest;
    #processingRequest : ProcessingRequest;
    #fileHeader : FileHeader;
    #accountReport : AccountReport;
    #receipt : Receipt;
  };

  /// What a reading of the bytes established: the family (by the root's namespace, "unknown" when it
  /// is not one this module carries), the schema's verdict, and — when the schema passed — the business
  /// reading. The schema tier and the business tier never mix: a message the schema refuses is not read.
  public type Decoded = { family : Text; schemaIssues : [Issue]; message : Result.Result<Message, [Issue]> };

  /// The family's short name ("pacs.007") from its message definition identifier ("pacs.007.001.10").
  public func shortFamily(family : Text) : Text {
    let parts = Iter.toArray(Text.split(family, #char '.'));
    if (parts.size() >= 2) parts[0] # "." # parts[1] else family
  };

  func readMessage(sc : P.Schema, root : Xml.Element, minorUnitsOf : Text -> ?Nat8) : Result.Result<Message, [Issue]> {
    func wrap<T>(r : Result.Result<T, [Issue]>, f : T -> Message) : Result.Result<Message, [Issue]> { switch (r) { case (#ok(v)) #ok(f(v)); case (#err(e)) #err(e) } };
    switch (shortFamily(sc.family)) {
      case ("pacs.003") wrap<DirectDebitMessage>(readPacs003(root, minorUnitsOf), func(v) { #directDebit(v) });
      case ("pacs.010") wrap<DirectDebitMessage>(readPacs010(root, minorUnitsOf), func(v) { #directDebit(v) });
      case ("pacs.007") wrap<Reversal>(readPacs007(root, minorUnitsOf), func(v) { #reversal(v) });
      case ("pain.007") wrap<Reversal>(readPain007(root, minorUnitsOf), func(v) { #reversal(v) });
      case ("pacs.029") wrap<SettlementRequest>(readPacs029(root, minorUnitsOf), func(v) { #settlementRequest(v) });
      case ("pain.009") wrap<MandateMessage>(readPain009(root, minorUnitsOf), func(v) { #mandateInitiation(v) });
      case ("pain.010") wrap<MandateAmendment>(readPain010(root, minorUnitsOf), func(v) { #mandateAmendment(v) });
      case ("pain.011") wrap<MandateCancellation>(readPain011(root), func(v) { #mandateCancellation(v) });
      case ("pain.012") wrap<MandateAcceptance>(readPain012(root), func(v) { #mandateAcceptance(v) });
      case ("camt.060") wrap<ReportingRequest>(readCamt060(root), func(v) { #reportingRequest(v) });
      case ("camt.057") wrap<NotificationToReceive>(readCamt057(root, minorUnitsOf), func(v) { #notificationToReceive(v) });
      case ("camt.050") wrap<LiquidityTransfer>(readCamt050(root, minorUnitsOf), func(v) { #liquidityTransfer(v) });
      case ("camt.026" or "camt.027" or "camt.028" or "camt.087") wrap<Investigation>(readInvestigation(root, shortFamily(sc.family), minorUnitsOf), func(v) { #investigation(v) });
      case ("admi.006") wrap<ResendRequest>(readAdmi006(root), func(v) { #resendRequest(v) });
      case ("admi.017") wrap<ProcessingRequest>(readAdmi017(root), func(v) { #processingRequest(v) });
      case ("head.002") wrap<FileHeader>(readHead002(root), func(v) { #fileHeader(v) });
      case ("camt.052") wrap<AccountReport>(readCamt052(root, minorUnitsOf), func(v) { #accountReport(v) });
      case ("camt.025") wrap<Receipt>(readCamt025(root), func(v) { #receipt(v) });
      case (other) #err([{ rule = "ISO-BIZ-FAMILY"; path = "/" # root.name; detail = other # " is carried by the compact codec, not by this module" }]);
    }
  };

  /// The bytes of one message: the root element (a `Document`, or head.002's `Xchg`) validated against
  /// its official schema — a business file's payloads each against their own — then read.
  public func decode(bytes : Blob, minorUnitsOf : Text -> ?Nat8) : Decoded {
    let root = switch (Xml.parseMessage(bytes)) {
      case (#err(e)) return { family = "unknown"; schemaIssues = [{ rule = e.rule; path = "$xml@" # Nat.toText(e.offset); detail = e.detail }]; message = #err([]) };
      case (#ok(roots)) {
        if (roots.size() != 1) return { family = "unknown"; schemaIssues = [{ rule = "XML-ROOT"; path = "/" # roots[1].name; detail = "one root element: a Document, or a business file's Xchg" }]; message = #err([]) };
        roots[0]
      };
    };
    let ?sc = IsoSchema.schemaFor(root.namespace) else return { family = "unknown"; schemaIssues = [{ rule = "ISO-XSD-ROOT"; path = "/" # root.name; detail = "namespace " # root.namespace # " is not a family this component carries" }]; message = #err([]) };
    let issues = List.fromArray<Issue>(IsoSchema.validate(sc, root));
    if (root.name == "Xchg") {
      var j = 0;
      for (pl in Xml.children(root, "Pyld").vals()) {
        for (payload in pl.children.vals()) {
          let prefix = "/Xchg/Pyld[" # Nat.toText(j + 1) # "]";
          switch (IsoSchema.schemaFor(payload.namespace)) {
            case (?ps) { for (i in IsoSchema.validate(ps, payload).vals()) List.add(issues, { rule = i.rule; path = prefix # i.path; detail = i.detail }) };
            case null List.add(issues, { rule = "ISO-XSD-ROOT"; path = prefix # "/" # payload.name; detail = "namespace " # payload.namespace # " is not a family this component carries" });
          };
        };
        j += 1;
      };
    };
    let schemaIssues = List.toArray(issues);
    if (schemaIssues.size() > 0) return { family = sc.family; schemaIssues; message = #err([]) };
    { family = sc.family; schemaIssues; message = readMessage(sc, root, minorUnitsOf) }
  };

  /// What the records do not carry and the schemas require: the writer supplies them.
  public type EmitOptions = {
    settlementMethod : Text;        // pacs.003, pacs.007, pacs.029's SttlmMtd (CLRG, INDA, INGA, COVE)
    chargeBearer : Text;            // pacs.003's ChrgBr (SLEV, SHAR, DEBT, CRED)
    settlementDate : Text;          // pacs.003 / pacs.010's IntrBkSttlmDt
    initiatingParty : ?Text;        // pain.007 / 009 / 010 / 011 / 012's InitgPty name
    originalPaymentInfoId : Text;   // pain.007's OrgnlPmtInfId
    creditorName : ?Text;           // pain.009's Cdtr name
    debtorName : ?Text;             // pain.009's Dbtr name
    originalMessage : ?(Text, Text); // pain.012's OrgnlMsgInf (id, message name)
  };

  public func defaultEmitOptions(settlementDate : Text) : EmitOptions {
    { settlementMethod = "CLRG"; chargeBearer = "SLEV"; settlementDate; initiatingParty = null; originalPaymentInfoId = "PMTINF-1"; creditorName = null; debtorName = null; originalMessage = null }
  };

  /// The record written in its family's official shape.
  public func emit(m : Message, minorUnitsOf : Text -> ?Nat8, o : EmitOptions) : Emitted {
    switch (m) {
      case (#directDebit(r)) directDebitXml(r, minorUnitsOf, o.settlementMethod, o.chargeBearer, o.settlementDate);
      case (#reversal(r)) reversalXml(r, minorUnitsOf, o.settlementMethod, o.initiatingParty, o.originalPaymentInfoId);
      case (#settlementRequest(r)) settlementRequestXml(r, minorUnitsOf, ?o.settlementMethod);
      case (#mandateInitiation(r)) mandateInitiationXml(r, minorUnitsOf, o.initiatingParty, o.creditorName, o.debtorName);
      case (#mandateAmendment(r)) mandateAmendmentXml(r, minorUnitsOf, o.initiatingParty);
      case (#mandateCancellation(r)) mandateCancellationXml(r, o.initiatingParty);
      case (#mandateAcceptance(r)) mandateAcceptanceXml(r, o.initiatingParty, o.originalMessage);
      case (#reportingRequest(r)) reportingRequestXml(r);
      case (#notificationToReceive(r)) notificationToReceiveXml(r, minorUnitsOf);
      case (#liquidityTransfer(r)) liquidityTransferXml(r, minorUnitsOf);
      case (#investigation(r)) investigationXml(r, minorUnitsOf);
      case (#resendRequest(r)) resendRequestXml(r);
      case (#processingRequest(r)) processingRequestXml(r);
      case (#fileHeader(r)) fileHeaderXml(r);
      case (#accountReport(r)) accountReportXml(r, minorUnitsOf);
      case (#receipt(r)) receiptXml(r);
    }
  };

  /// Structural equality of two readings. A business file's payloads are element trees whose
  /// insignificant whitespace the serializer does not keep, so they compare by their serialized form.
  public func equalMessage(a : Message, b : Message) : Bool {
    switch (a, b) {
      case (#fileHeader(x), #fileHeader(y)) {
        x.payloadId == y.payloadId and x.creationDateTime == y.creationDateTime and x.payloadType == y.payloadType and x.declaredDocuments == y.declaredDocuments and x.possibleDuplicate == y.possibleDuplicate
        and Array.map<Xml.Element, Text>(x.payloads, Xml.serializeBody) == Array.map<Xml.Element, Text>(y.payloads, Xml.serializeBody)
      };
      case (_) a == b;
    }
  };

  /// The round trip the integration kit asserts: the message read, written, read again, and the two
  /// readings equal. `#ok(xml)` is the written document; `#err` names the first tier that refused.
  public func roundTrip(bytes : Blob, minorUnitsOf : Text -> ?Nat8, o : EmitOptions) : Result.Result<Text, [Issue]> {
    let first = decode(bytes, minorUnitsOf);
    if (first.schemaIssues.size() > 0) return #err(first.schemaIssues);
    let m = switch (first.message) { case (#ok(m)) m; case (#err(e)) return #err(e) };
    let xml = switch (emit(m, minorUnitsOf, o)) { case (#ok(x)) x; case (#err(e)) return #err(e) };
    let second = decode(Text.encodeUtf8(xml), minorUnitsOf);
    if (second.schemaIssues.size() > 0) return #err(Array.map<Issue, Issue>(second.schemaIssues, func(i) { { rule = "ROUNDTRIP-" # i.rule; path = i.path; detail = i.detail } }));
    switch (second.message) {
      case (#err(e)) #err(Array.map<Issue, Issue>(e, func(i) { { rule = "ROUNDTRIP-" # i.rule; path = i.path; detail = i.detail } }));
      case (#ok(m2)) { if (equalMessage(m2, m)) #ok(xml) else #err([{ rule = "ROUNDTRIP-EQUALITY"; path = "/"; detail = "the second reading differs from the first" }]) };
    }
  };
}
