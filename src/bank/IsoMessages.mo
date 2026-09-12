/// IsoMessages.mo — the ISO 20022 messages the bank acts on, read from a validated tree, and the ones
/// it emits, written schema-valid.
///
/// Reading: a pacs.008 (FI-to-FI customer credit transfer) or pacs.009 (FI credit transfer) into
/// its transactions — UETR, end-to-end id, interbank settlement amount, the debtor and creditor
/// agents whose positions move; a pacs.002 status report into its per-transaction statuses; a
/// pacs.004 return into its returned transactions; a head.001 Business Application Header into its
/// sender and message identification. Every read presumes `IsoSchema.validate` passed, so the
/// required elements are there; what this layer still refuses is business content the schema
/// cannot see — a missing UETR where the rail requires one, an amount in a currency the journal
/// does not know, an agent that is not a participant — with its own rule ids (`ISO-BIZ-…`).
///
/// Writing: a pacs.002 status report answering a received message, and the camt.053 statement
/// and camt.054 notification of a participant's account in the schema's own shape (the compact
/// `iso20022-xml-subset-v1` shape the deployed example reads stays in Statements.mo). Everything
/// written here validates under `xmllint --schema` against the official XSD — the harness asserts
/// it on every instance — and parses under an independent ISO 20022 library.

import Array "mo:core/Array";
import Char "mo:core/Char";
import Iter "mo:core/Iter";
import List "mo:core/List";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Nat32 "mo:core/Nat32";
import Nat64 "mo:core/Nat64";
import Result "mo:core/Result";
import Text "mo:core/Text";

import CivilDate "mo:journal/CivilDate";

import PayT "PaymentsTypes";
import Xml "Xml";

module {

  public type Issue = PayT.Issue;

  public type Amount = { currency : Text; minor : Nat };

  public type CreditTransfer = {
    uetr : Text;
    endToEndId : Text;
    instructionId : ?Text;
    amount : Amount;
    settlementDate : ?Text;
    /// The participants whose positions move: the debtor agent pays, the creditor agent is paid.
    debtorAgent : Text;
    creditorAgent : Text;
    debtorName : ?Text;
    creditorName : ?Text;
    chargeBearer : ?Text;
  };

  public type CreditTransferMessage = {
    family : PayT.Family;
    messageId : Text;
    creationDateTime : Text;
    settlementMethod : Text;
    declaredCount : Nat;
    transactions : [CreditTransfer];
  };

  public type StatusItem = { originalUetr : ?Text; originalEndToEndId : ?Text; originalInstructionId : ?Text; originalTransactionId : ?Text; status : ?Text; reasonCode : ?Text; reasonProprietary : ?Text };
  public type StatusReport = { messageId : Text; creationDateTime : Text; originalMessageId : ?Text; originalMessageName : ?Text; groupStatus : ?Text; items : [StatusItem] };

  public type ReturnItem = { returnId : ?Text; originalUetr : ?Text; originalEndToEndId : ?Text; amount : Amount; reasonCode : ?Text; reasonProprietary : ?Text };
  public type PaymentReturn = { messageId : Text; creationDateTime : Text; declaredCount : Nat; items : [ReturnItem] };

  public type Header = { fromBic : Text; toBic : Text; businessMessageId : Text; messageDefinition : Text; creationDate : Text };

  // ─── reading ───

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

  /// pacs.008.001.08 — FIToFICstmrCdtTrf.
  public func readPacs008(doc : Xml.Element, minorUnitsOf : Text -> ?Nat8) : Result.Result<CreditTransferMessage, [Issue]> {
    let issues = List.empty<Issue>();
    let ?body = Xml.child(doc, "FIToFICstmrCdtTrf") else return #err([{ rule = "ISO-BIZ-REQUIRED"; path = "/Document/FIToFICstmrCdtTrf"; detail = "missing" }]);
    let messageId = need(body, ["GrpHdr", "MsgId"], "/Document/FIToFICstmrCdtTrf/GrpHdr/MsgId", issues);
    let creationDateTime = need(body, ["GrpHdr", "CreDtTm"], "/Document/FIToFICstmrCdtTrf/GrpHdr/CreDtTm", issues);
    let settlementMethod = need(body, ["GrpHdr", "SttlmInf", "SttlmMtd"], "/Document/FIToFICstmrCdtTrf/GrpHdr/SttlmInf/SttlmMtd", issues);
    let declaredCount = countOf(need(body, ["GrpHdr", "NbOfTxs"], "/Document/FIToFICstmrCdtTrf/GrpHdr/NbOfTxs", issues));
    let txs = List.empty<CreditTransfer>();
    var i = 0;
    for (tx in Xml.children(body, "CdtTrfTxInf").vals()) {
      i += 1;
      let p = "/Document/FIToFICstmrCdtTrf/CdtTrfTxInf[" # Nat.toText(i) # "]";
      List.add(txs, {
        uetr = uetrOf(tx, p, issues);
        endToEndId = need(tx, ["PmtId", "EndToEndId"], p # "/PmtId/EndToEndId", issues);
        instructionId = t(tx, ["PmtId", "InstrId"]);
        amount = readAmount(tx, ["IntrBkSttlmAmt"], p # "/IntrBkSttlmAmt", minorUnitsOf, issues);
        settlementDate = t(tx, ["IntrBkSttlmDt"]);
        debtorAgent = agentBic(tx, ["DbtrAgt"], p # "/DbtrAgt", issues);
        creditorAgent = agentBic(tx, ["CdtrAgt"], p # "/CdtrAgt", issues);
        debtorName = t(tx, ["Dbtr", "Nm"]);
        creditorName = t(tx, ["Cdtr", "Nm"]);
        chargeBearer = t(tx, ["ChrgBr"]);
      });
    };
    if (declaredCount != List.size(txs)) List.add(issues, { rule = "ISO-BIZ-COUNT"; path = "/Document/FIToFICstmrCdtTrf/GrpHdr/NbOfTxs"; detail = "NbOfTxs says " # Nat.toText(declaredCount) # ", the message carries " # Nat.toText(List.size(txs)) });
    if (List.size(issues) > 0) return #err(List.toArray(issues));
    #ok({ family = #pacs008; messageId; creationDateTime; settlementMethod; declaredCount; transactions = List.toArray(txs) })
  };

  /// pacs.009.001.08 — FICdtTrf. The paying participant is the debtor agent when one is named,
  /// else the debtor institution; the paid one the creditor agent, else the creditor institution.
  public func readPacs009(doc : Xml.Element, minorUnitsOf : Text -> ?Nat8) : Result.Result<CreditTransferMessage, [Issue]> {
    let issues = List.empty<Issue>();
    let ?body = Xml.child(doc, "FICdtTrf") else return #err([{ rule = "ISO-BIZ-REQUIRED"; path = "/Document/FICdtTrf"; detail = "missing" }]);
    let messageId = need(body, ["GrpHdr", "MsgId"], "/Document/FICdtTrf/GrpHdr/MsgId", issues);
    let creationDateTime = need(body, ["GrpHdr", "CreDtTm"], "/Document/FICdtTrf/GrpHdr/CreDtTm", issues);
    let settlementMethod = need(body, ["GrpHdr", "SttlmInf", "SttlmMtd"], "/Document/FICdtTrf/GrpHdr/SttlmInf/SttlmMtd", issues);
    let declaredCount = countOf(need(body, ["GrpHdr", "NbOfTxs"], "/Document/FICdtTrf/GrpHdr/NbOfTxs", issues));
    let txs = List.empty<CreditTransfer>();
    var i = 0;
    for (tx in Xml.children(body, "CdtTrfTxInf").vals()) {
      i += 1;
      let p = "/Document/FICdtTrf/CdtTrfTxInf[" # Nat.toText(i) # "]";
      let payer = switch (Xml.child(tx, "DbtrAgt")) { case (?_) agentBic(tx, ["DbtrAgt"], p # "/DbtrAgt", issues); case null agentBic(tx, ["Dbtr"], p # "/Dbtr", issues) };
      let payee = switch (Xml.child(tx, "CdtrAgt")) { case (?_) agentBic(tx, ["CdtrAgt"], p # "/CdtrAgt", issues); case null agentBic(tx, ["Cdtr"], p # "/Cdtr", issues) };
      List.add(txs, {
        uetr = uetrOf(tx, p, issues);
        endToEndId = need(tx, ["PmtId", "EndToEndId"], p # "/PmtId/EndToEndId", issues);
        instructionId = t(tx, ["PmtId", "InstrId"]);
        amount = readAmount(tx, ["IntrBkSttlmAmt"], p # "/IntrBkSttlmAmt", minorUnitsOf, issues);
        settlementDate = t(tx, ["IntrBkSttlmDt"]);
        debtorAgent = payer;
        creditorAgent = payee;
        debtorName = t(tx, ["Dbtr", "FinInstnId", "Nm"]);
        creditorName = t(tx, ["Cdtr", "FinInstnId", "Nm"]);
        chargeBearer = null;
      });
    };
    if (declaredCount != List.size(txs)) List.add(issues, { rule = "ISO-BIZ-COUNT"; path = "/Document/FICdtTrf/GrpHdr/NbOfTxs"; detail = "NbOfTxs says " # Nat.toText(declaredCount) # ", the message carries " # Nat.toText(List.size(txs)) });
    if (List.size(issues) > 0) return #err(List.toArray(issues));
    #ok({ family = #pacs009; messageId; creationDateTime; settlementMethod; declaredCount; transactions = List.toArray(txs) })
  };

  func reason(e : Xml.Element, wrapper : Text) : (?Text, ?Text) {
    switch (Xml.child(e, wrapper)) {
      case (?r) (t(r, ["Rsn", "Cd"]), t(r, ["Rsn", "Prtry"]));
      case null (null, null);
    }
  };

  /// pacs.002.001.10 — FIToFIPmtStsRpt.
  public func readPacs002(doc : Xml.Element) : Result.Result<StatusReport, [Issue]> {
    let issues = List.empty<Issue>();
    let ?body = Xml.child(doc, "FIToFIPmtStsRpt") else return #err([{ rule = "ISO-BIZ-REQUIRED"; path = "/Document/FIToFIPmtStsRpt"; detail = "missing" }]);
    let messageId = need(body, ["GrpHdr", "MsgId"], "/Document/FIToFIPmtStsRpt/GrpHdr/MsgId", issues);
    let creationDateTime = need(body, ["GrpHdr", "CreDtTm"], "/Document/FIToFIPmtStsRpt/GrpHdr/CreDtTm", issues);
    let items = List.empty<StatusItem>();
    for (x in Xml.children(body, "TxInfAndSts").vals()) {
      let (code, prtry) = reason(x, "StsRsnInf");
      List.add(items, { originalUetr = t(x, ["OrgnlUETR"]); originalEndToEndId = t(x, ["OrgnlEndToEndId"]); originalInstructionId = t(x, ["OrgnlInstrId"]); originalTransactionId = t(x, ["OrgnlTxId"]); status = t(x, ["TxSts"]); reasonCode = code; reasonProprietary = prtry });
    };
    if (List.size(issues) > 0) return #err(List.toArray(issues));
    #ok({ messageId; creationDateTime; originalMessageId = t(body, ["OrgnlGrpInfAndSts", "OrgnlMsgId"]); originalMessageName = t(body, ["OrgnlGrpInfAndSts", "OrgnlMsgNmId"]); groupStatus = t(body, ["OrgnlGrpInfAndSts", "GrpSts"]); items = List.toArray(items) })
  };

  /// pacs.004.001.09 — PmtRtr.
  public func readPacs004(doc : Xml.Element, minorUnitsOf : Text -> ?Nat8) : Result.Result<PaymentReturn, [Issue]> {
    let issues = List.empty<Issue>();
    let ?body = Xml.child(doc, "PmtRtr") else return #err([{ rule = "ISO-BIZ-REQUIRED"; path = "/Document/PmtRtr"; detail = "missing" }]);
    let messageId = need(body, ["GrpHdr", "MsgId"], "/Document/PmtRtr/GrpHdr/MsgId", issues);
    let creationDateTime = need(body, ["GrpHdr", "CreDtTm"], "/Document/PmtRtr/GrpHdr/CreDtTm", issues);
    let declaredCount = countOf(need(body, ["GrpHdr", "NbOfTxs"], "/Document/PmtRtr/GrpHdr/NbOfTxs", issues));
    let items = List.empty<ReturnItem>();
    var i = 0;
    for (x in Xml.children(body, "TxInf").vals()) {
      i += 1;
      let p = "/Document/PmtRtr/TxInf[" # Nat.toText(i) # "]";
      let (code, prtry) = reason(x, "RtrRsnInf");
      List.add(items, { returnId = t(x, ["RtrId"]); originalUetr = t(x, ["OrgnlUETR"]); originalEndToEndId = t(x, ["OrgnlEndToEndId"]); amount = readAmount(x, ["RtrdIntrBkSttlmAmt"], p # "/RtrdIntrBkSttlmAmt", minorUnitsOf, issues); reasonCode = code; reasonProprietary = prtry });
    };
    if (declaredCount != List.size(items)) List.add(issues, { rule = "ISO-BIZ-COUNT"; path = "/Document/PmtRtr/GrpHdr/NbOfTxs"; detail = "NbOfTxs says " # Nat.toText(declaredCount) # ", the message carries " # Nat.toText(List.size(items)) });
    if (List.size(issues) > 0) return #err(List.toArray(issues));
    #ok({ messageId; creationDateTime; declaredCount; items = List.toArray(items) })
  };

  /// head.001.001.02 — the Business Application Header.
  public func readHeader(hdr : Xml.Element) : Result.Result<Header, [Issue]> {
    let issues = List.empty<Issue>();
    let fromBic = need(hdr, ["Fr", "FIId", "FinInstnId", "BICFI"], "/AppHdr/Fr/FIId/FinInstnId/BICFI", issues);
    let toBic = need(hdr, ["To", "FIId", "FinInstnId", "BICFI"], "/AppHdr/To/FIId/FinInstnId/BICFI", issues);
    let businessMessageId = need(hdr, ["BizMsgIdr"], "/AppHdr/BizMsgIdr", issues);
    let messageDefinition = need(hdr, ["MsgDefIdr"], "/AppHdr/MsgDefIdr", issues);
    let creationDate = need(hdr, ["CreDt"], "/AppHdr/CreDt", issues);
    if (List.size(issues) > 0) return #err(List.toArray(issues));
    #ok({ fromBic; toBic; businessMessageId; messageDefinition; creationDate })
  };

  // ─── writing ───

  func el(indent : Nat, name : Text, value : Text) : Text { sp(indent) # "<" # name # ">" # Xml.escape(value) # "</" # name # ">\n" };
  func sp(n : Nat) : Text { var o = ""; var i = 0; while (i < n) { o #= " "; i += 1 }; o };
  func opt(indent : Nat, name : Text, v : ?Text) : Text { switch (v) { case (?x) el(indent, name, x); case null "" } };

  /// `YYYY-MM-DDThh:mm:ssZ` from nanoseconds since the epoch.
  public func isoDateTime(nanos : Nat64) : Text {
    let secs = Nat64.toNat(nanos / 1_000_000_000);
    let day = secs / 86_400;
    let rem = secs % 86_400;
    func two(n : Nat) : Text { if (n < 10) "0" # Nat.toText(n) else Nat.toText(n) };
    CivilDate.toText(day) # "T" # two(rem / 3600) # ":" # two(rem % 3600 / 60) # ":" # two(rem % 60) # "Z"
  };

  public type StatusLine = { originalEndToEndId : ?Text; originalUetr : Text; status : Text; reasonCode : ?Text; reasonProprietary : ?Text; additionalInfo : ?Text };

  /// pacs.002.001.10 answering a received message: one TxInfAndSts per transaction. Schema-valid:
  /// `Rsn` is a choice of `Cd` (an external reason code, ≤ 4) or `Prtry` (≤ 35); `AddtlInf` ≤ 105.
  public type GroupStatus = { status : Text; reasonProprietary : ?Text; additionalInfo : ?Text };

  public func pacs002Xml(messageId : Text, creationDateTime : Text, originalMessageId : Text, originalMessageName : Text, group : ?GroupStatus, lines : [StatusLine]) : Text {
    var grp = "";
    switch (group) {
      case (?g) {
        grp := el(6, "GrpSts", g.status);
        if (g.reasonProprietary != null or g.additionalInfo != null) {
          grp #= sp(6) # "<StsRsnInf>\n" # (switch (g.reasonProprietary) { case (?p) sp(8) # "<Rsn><Prtry>" # Xml.escape(clip(p, 35)) # "</Prtry></Rsn>\n"; case null "" }) # (switch (g.additionalInfo) { case (?x) el(8, "AddtlInf", clip(x, 105)); case null "" }) # sp(6) # "</StsRsnInf>\n";
        };
      };
      case null {};
    };
    var body = "";
    for (l in lines.vals()) {
      var rsn = "";
      switch (l.reasonCode, l.reasonProprietary, l.additionalInfo) {
        case (null, null, null) {};
        case (code, prtry, info) {
          rsn := sp(6) # "<StsRsnInf>\n"
            # (switch (code, prtry) { case (?c, _) sp(8) # "<Rsn><Cd>" # Xml.escape(c) # "</Cd></Rsn>\n"; case (null, ?p) sp(8) # "<Rsn><Prtry>" # Xml.escape(clip(p, 35)) # "</Prtry></Rsn>\n"; case (null, null) "" })
            # (switch (info) { case (?x) el(8, "AddtlInf", clip(x, 105)); case null "" })
            # sp(6) # "</StsRsnInf>\n";
        };
      };
      body #= sp(4) # "<TxInfAndSts>\n" # opt(6, "OrgnlEndToEndId", l.originalEndToEndId) # el(6, "OrgnlUETR", l.originalUetr) # el(6, "TxSts", l.status) # rsn # sp(4) # "</TxInfAndSts>\n";
    };
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
    # "<Document xmlns=\"urn:iso:std:iso:20022:tech:xsd:pacs.002.001.10\">\n"
    # "  <FIToFIPmtStsRpt>\n"
    # "    <GrpHdr>\n" # el(6, "MsgId", clip(messageId, 35)) # el(6, "CreDtTm", creationDateTime) # "    </GrpHdr>\n"
    # "    <OrgnlGrpInfAndSts>\n" # el(6, "OrgnlMsgId", clip(originalMessageId, 35)) # el(6, "OrgnlMsgNmId", originalMessageName) # grp # "    </OrgnlGrpInfAndSts>\n"
    # body
    # "  </FIToFIPmtStsRpt>\n"
    # "</Document>\n"
  };

  public func clip(t : Text, max : Nat) : Text {
    if (Text.size(t) <= max) return t;
    Text.fromIter(Iter.fromArray(Array.tabulate<Char>(max, func(i) { Text.toArray(t)[i] })))
  };

  /// One booked movement of an account, as a camt.053/054 entry: the schema's `Ntry` with
  /// `NtryDtls/TxDtls` carrying the UETR in `Refs` and the journal block as the account servicer
  /// reference, so a line still names its proof.
  public type Entry = { reference : Text; amount : Amount; credit : Bool; bookingDay : Nat; valueDay : Nat; uetr : ?Text; endToEndId : ?Text; block : Nat; counterparty : ?Text; remittance : [Text] };

  public type Balance = { code : Text; amount : Amount; credit : Bool; day : Nat };

  func entryXml(indent : Nat, e : Entry, minorUnits : Nat8) : Text {
    let i = indent;
    var rmt = "";
    for (line in e.remittance.vals()) rmt #= el(i + 8, "Ustrd", clip(line, 140));
    sp(i) # "<Ntry>\n"
    # el(i + 2, "NtryRef", clip(e.reference, 35))
    # sp(i + 2) # "<Amt Ccy=\"" # Xml.escape(e.amount.currency) # "\">" # amountText(e.amount.minor, minorUnits) # "</Amt>\n"
    # el(i + 2, "CdtDbtInd", if (e.credit) "CRDT" else "DBIT")
    # sp(i + 2) # "<Sts><Cd>BOOK</Cd></Sts>\n"
    # sp(i + 2) # "<BookgDt><Dt>" # CivilDate.toText(e.bookingDay) # "</Dt></BookgDt>\n"
    # sp(i + 2) # "<ValDt><Dt>" # CivilDate.toText(e.valueDay) # "</Dt></ValDt>\n"
    # el(i + 2, "AcctSvcrRef", Nat.toText(e.block))
    # sp(i + 2) # "<BkTxCd><Prtry><Cd>PMNT</Cd></Prtry></BkTxCd>\n"
    # sp(i + 2) # "<NtryDtls><TxDtls>\n"
    # sp(i + 6) # "<Refs>\n" # el(i + 8, "AcctSvcrRef", Nat.toText(e.block)) # opt(i + 8, "EndToEndId", e.endToEndId) # opt(i + 8, "UETR", e.uetr) # sp(i + 6) # "</Refs>\n"
    # (switch (e.counterparty) { case (?c) sp(i + 6) # "<RltdPties>" # (if (e.credit) "<Dbtr><Pty><Nm>" # Xml.escape(clip(c, 140)) # "</Nm></Pty></Dbtr>" else "<Cdtr><Pty><Nm>" # Xml.escape(clip(c, 140)) # "</Nm></Pty></Cdtr>") # "</RltdPties>\n"; case null "" })
    # (if (e.remittance.size() > 0) sp(i + 6) # "<RmtInf>\n" # rmt # sp(i + 6) # "</RmtInf>\n" else "")
    # sp(i + 2) # "</TxDtls></NtryDtls>\n"
    # sp(i) # "</Ntry>\n"
  };

  func balanceXml(indent : Nat, b : Balance, minorUnits : Nat8) : Text {
    sp(indent) # "<Bal>\n"
    # sp(indent + 2) # "<Tp><CdOrPrtry><Cd>" # b.code # "</Cd></CdOrPrtry></Tp>\n"
    # sp(indent + 2) # "<Amt Ccy=\"" # Xml.escape(b.amount.currency) # "\">" # amountText(b.amount.minor, minorUnits) # "</Amt>\n"
    # el(indent + 2, "CdtDbtInd", if (b.credit) "CRDT" else "DBIT")
    # sp(indent + 2) # "<Dt><Dt>" # CivilDate.toText(b.day) # "</Dt></Dt>\n"
    # sp(indent) # "</Bal>\n"
  };

  func acctXml(indent : Nat, iban : ?Text, otherId : Text, currency : Text) : Text {
    sp(indent) # "<Acct>" # (switch (iban) { case (?i) "<Id><IBAN>" # Xml.escape(i) # "</IBAN></Id>"; case null "<Id><Othr><Id>" # Xml.escape(clip(otherId, 34)) # "</Id></Othr></Id>" }) # "<Ccy>" # Xml.escape(currency) # "</Ccy></Acct>\n"
  };

  /// camt.053.001.08 — BkToCstmrStmt, schema-valid: `Stmt` with `Id`, `CreDtTm`, `FrToDt`, `Acct`,
  /// the balances (at least one), the entries.
  public func camt053Xml(messageId : Text, creationDateTime : Text, statementId : Text, iban : ?Text, accountId : Text, currency : Text, minorUnits : Nat8, fromDay : Nat, toDay : Nat, balances : [Balance], entries : [Entry]) : Text {
    var bals = ""; for (b in balances.vals()) bals #= balanceXml(6, b, minorUnits);
    var body = ""; for (e in entries.vals()) body #= entryXml(6, e, minorUnits);
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
    # "<Document xmlns=\"urn:iso:std:iso:20022:tech:xsd:camt.053.001.08\">\n"
    # "  <BkToCstmrStmt>\n"
    # "    <GrpHdr>\n" # el(6, "MsgId", clip(messageId, 35)) # el(6, "CreDtTm", creationDateTime) # "    </GrpHdr>\n"
    # "    <Stmt>\n"
    # el(6, "Id", clip(statementId, 35))
    # el(6, "CreDtTm", creationDateTime)
    # sp(6) # "<FrToDt><FrDtTm>" # CivilDate.toText(fromDay) # "T00:00:00Z</FrDtTm><ToDtTm>" # CivilDate.toText(toDay) # "T23:59:59Z</ToDtTm></FrToDt>\n"
    # acctXml(6, iban, accountId, currency)
    # bals
    # body
    # "    </Stmt>\n"
    # "  </BkToCstmrStmt>\n"
    # "</Document>\n"
  };

  /// camt.054.001.08 — BkToCstmrDbtCdtNtfctn for one movement.
  public func camt054Xml(messageId : Text, creationDateTime : Text, notificationId : Text, iban : ?Text, accountId : Text, currency : Text, minorUnits : Nat8, entry : Entry) : Text {
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
    # "<Document xmlns=\"urn:iso:std:iso:20022:tech:xsd:camt.054.001.08\">\n"
    # "  <BkToCstmrDbtCdtNtfctn>\n"
    # "    <GrpHdr>\n" # el(6, "MsgId", clip(messageId, 35)) # el(6, "CreDtTm", creationDateTime) # "    </GrpHdr>\n"
    # "    <Ntfctn>\n"
    # el(6, "Id", clip(notificationId, 35))
    # el(6, "CreDtTm", creationDateTime)
    # acctXml(6, iban, accountId, currency)
    # entryXml(6, entry, minorUnits)
    # "    </Ntfctn>\n"
    # "  </BkToCstmrDbtCdtNtfctn>\n"
    # "</Document>\n"
  };

  /// A pacs.008.001.08 the bank itself emits (the harness's valid instances, and an outbound
  /// customer credit transfer): the schema's required elements, a settlement method, one
  /// transaction per item.
  public type OutboundTransfer = { uetr : Text; endToEndId : Text; amount : Amount; debtorAgent : Text; creditorAgent : Text; debtorName : Text; creditorName : Text; debtorIban : ?Text; creditorIban : ?Text; settlementDate : Nat };
  public func pacs008Xml(messageId : Text, creationDateTime : Text, minorUnits : Nat8, items : [OutboundTransfer]) : Text {
    var body = "";
    for (x in items.vals()) {
      body #= "    <CdtTrfTxInf>\n"
        # sp(6) # "<PmtId>" # "<EndToEndId>" # Xml.escape(clip(x.endToEndId, 35)) # "</EndToEndId><UETR>" # Xml.escape(x.uetr) # "</UETR></PmtId>\n"
        # sp(6) # "<IntrBkSttlmAmt Ccy=\"" # Xml.escape(x.amount.currency) # "\">" # amountText(x.amount.minor, minorUnits) # "</IntrBkSttlmAmt>\n"
        # el(6, "IntrBkSttlmDt", CivilDate.toText(x.settlementDate))
        # el(6, "ChrgBr", "SLEV")
        # sp(6) # "<Dbtr><Nm>" # Xml.escape(clip(x.debtorName, 140)) # "</Nm></Dbtr>\n"
        # (switch (x.debtorIban) { case (?i) sp(6) # "<DbtrAcct><Id><IBAN>" # Xml.escape(i) # "</IBAN></Id></DbtrAcct>\n"; case null "" })
        # sp(6) # "<DbtrAgt><FinInstnId><BICFI>" # Xml.escape(x.debtorAgent) # "</BICFI></FinInstnId></DbtrAgt>\n"
        # sp(6) # "<CdtrAgt><FinInstnId><BICFI>" # Xml.escape(x.creditorAgent) # "</BICFI></FinInstnId></CdtrAgt>\n"
        # sp(6) # "<Cdtr><Nm>" # Xml.escape(clip(x.creditorName, 140)) # "</Nm></Cdtr>\n"
        # (switch (x.creditorIban) { case (?i) sp(6) # "<CdtrAcct><Id><IBAN>" # Xml.escape(i) # "</IBAN></Id></CdtrAcct>\n"; case null "" })
        # "    </CdtTrfTxInf>\n";
    };
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
    # "<Document xmlns=\"urn:iso:std:iso:20022:tech:xsd:pacs.008.001.08\">\n"
    # "  <FIToFICstmrCdtTrf>\n"
    # "    <GrpHdr>\n" # el(6, "MsgId", clip(messageId, 35)) # el(6, "CreDtTm", creationDateTime) # el(6, "NbOfTxs", Nat.toText(items.size())) # sp(6) # "<SttlmInf><SttlmMtd>CLRG</SttlmMtd></SttlmInf>\n" # "    </GrpHdr>\n"
    # body
    # "  </FIToFICstmrCdtTrf>\n"
    # "</Document>\n"
  };


  // ═══════════════════════════════════════════════════════════════════════════════
  // the extended target list — the declared target list: reversals, direct debits, the mandate cycle, the
  // multilateral settlement request, cash management and liquidity, the exceptions-and-investigations
  // set, system administration, the business file header.
  // ═══════════════════════════════════════════════════════════════════════════════

  /// A direct debit (pacs.003 customer collection, pacs.010 FI direct debit): the creditor agent
  /// pulls from the debtor agent under an authority — the mandate the collection names, or the
  /// debtor participant's standing debit authority for FI direct debits.
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
  public type DirectDebitMessage = { family : PayT.Family; messageId : Text; creationDateTime : Text; declaredCount : Nat; transactions : [DirectDebit] };

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
    #ok({ family = #pacs003; messageId; creationDateTime; declaredCount; transactions = List.toArray(txs) })
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
    #ok({ family = #pacs010; messageId; creationDateTime; declaredCount; transactions = List.toArray(txs) })
  };

  /// A reversal item (pacs.007 interbank, pain.007 customer): the original by UETR or end-to-end id,
  /// the reversed amount, the reason.
  public type ReversalItem = { reversalId : ?Text; originalUetr : ?Text; originalEndToEndId : ?Text; amount : ?Amount; reasonCode : ?Text; reasonProprietary : ?Text };
  public type Reversal = { family : PayT.Family; messageId : Text; creationDateTime : Text; declaredCount : Nat; originalMessageId : ?Text; originalMessageName : ?Text; groupReasonCode : ?Text; groupReasonProprietary : ?Text; items : [ReversalItem] };

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
    #ok({ family = #pacs007; messageId; creationDateTime; declaredCount; originalMessageId = t(body, ["OrgnlGrpInf", "OrgnlMsgId"]); originalMessageName = t(body, ["OrgnlGrpInf", "OrgnlMsgNmId"]); groupReasonCode = gcode; groupReasonProprietary = gprtry; items = List.toArray(items) })
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
    #ok({ family = #pain007; messageId; creationDateTime; declaredCount; originalMessageId = t(body, ["OrgnlGrpInf", "OrgnlMsgId"]); originalMessageName = t(body, ["OrgnlGrpInf", "OrgnlMsgNmId"]); groupReasonCode = gcode; groupReasonProprietary = gprtry; items = List.toArray(items) })
  };

  /// pacs.029.001.02 — MulSttlmReq: the scheme operator's settlement request, one instruction per
  /// settlement cycle with the movement of every participant.
  public type SettlementRequestItem = { instructionId : Text; cycle : ?Text; declaredMovements : ?Nat; movements : [PayT.Movement] };
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
      let moves = List.empty<PayT.Movement>();
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

  public type Investigation = { family : PayT.Family; assignmentId : Text; assignerBic : ?Text; assigneeBic : ?Text; creationDateTime : Text; caseId : ?Text; originalUetr : ?Text; originalEndToEndId : ?Text; originalInstructionId : ?Text };
  /// camt.026 (unable to apply), camt.027 (claim non-receipt), camt.028 (additional payment
  /// information), camt.087 (request to modify payment): one shape — the assignment, the case, the
  /// underlying transaction by UETR or end-to-end id.
  public func readInvestigation(doc : Xml.Element, family : PayT.Family) : Result.Result<Investigation, [Issue]> {
    let issues = List.empty<Issue>();
    let rootName = switch (family) { case (#camt026) "UblToApply"; case (#camt027) "ClmNonRct"; case (#camt028) "AddtlPmtInf"; case (#camt087) "ReqToModfyPmt"; case (_) "" };
    let ?body = Xml.child(doc, rootName) else return #err([{ rule = "ISO-BIZ-REQUIRED"; path = "/Document/" # rootName; detail = "missing" }]);
    let assignmentId = need(body, ["Assgnmt", "Id"], "/Document/" # rootName # "/Assgnmt/Id", issues);
    let creationDateTime = need(body, ["Assgnmt", "CreDtTm"], "/Document/" # rootName # "/Assgnmt/CreDtTm", issues);
    let und = Xml.child(body, "Undrlyg");
    func u(names : [Text]) : ?Text { switch (und) { case (?x) { switch (t(x, Array.concat(["IntrBk"], names))) { case (?v) ?v; case null { switch (t(x, Array.concat(["Initn"], names))) { case (?v) ?v; case null t(x, Array.concat(["StmtNtry"], names)) } } } }; case null null } };
    if (List.size(issues) > 0) return #err(List.toArray(issues));
    #ok({ family; assignmentId; assignerBic = t(body, ["Assgnmt", "Assgnr", "Agt", "FinInstnId", "BICFI"]); assigneeBic = t(body, ["Assgnmt", "Assgne", "Agt", "FinInstnId", "BICFI"]); creationDateTime; caseId = t(body, ["Case", "Id"]); originalUetr = u(["OrgnlUETR"]); originalEndToEndId = u(["OrgnlEndToEndId"]); originalInstructionId = u(["OrgnlInstrId"]) })
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

  // ─── emitters ───

  /// camt.052.001.08 — BkToCstmrAcctRpt, the intraday report answering a camt.060: the same entries
  /// and balances as the statement, under `Rpt`, naming the request in `OrgnlBizQry`.
  public func camt052Xml(messageId : Text, creationDateTime : Text, reportId : Text, originalQuery : ?(Text, Text), iban : ?Text, accountId : Text, currency : Text, minorUnits : Nat8, fromDay : Nat, toDay : Nat, balances : [Balance], entries : [Entry]) : Text {
    var bals = ""; for (b in balances.vals()) bals #= balanceXml(6, b, minorUnits);
    var body = ""; for (e in entries.vals()) body #= entryXml(6, e, minorUnits);
    let obq = switch (originalQuery) { case (?(id, name)) sp(6) # "<OrgnlBizQry>" # "<MsgId>" # Xml.escape(clip(id, 35)) # "</MsgId><MsgNmId>" # Xml.escape(name) # "</MsgNmId></OrgnlBizQry>\n"; case null "" };
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
    # "<Document xmlns=\"urn:iso:std:iso:20022:tech:xsd:camt.052.001.08\">\n"
    # "  <BkToCstmrAcctRpt>\n"
    # "    <GrpHdr>\n" # el(6, "MsgId", clip(messageId, 35)) # el(6, "CreDtTm", creationDateTime) # obq # "    </GrpHdr>\n"
    # "    <Rpt>\n"
    # el(6, "Id", clip(reportId, 35))
    # el(6, "CreDtTm", creationDateTime)
    # sp(6) # "<FrToDt><FrDtTm>" # CivilDate.toText(fromDay) # "T00:00:00Z</FrDtTm><ToDtTm>" # CivilDate.toText(toDay) # "T23:59:59Z</ToDtTm></FrToDt>\n"
    # acctXml(6, iban, accountId, currency)
    # bals
    # body
    # "    </Rpt>\n"
    # "  </BkToCstmrAcctRpt>\n"
    # "</Document>\n"
  };

  /// pain.012.001.07 — MndtAccptncRpt: the bank's decision on a mandate it was asked to hold.
  public func pain012Xml(messageId : Text, creationDateTime : Text, originalMessageId : Text, originalMessageName : Text, mandateId : Text, accepted : Bool, reason : ?Text) : Text {
    let rjct = switch (reason) { case (?r) { if (accepted) "" else sp(8) # "<RjctRsn><Prtry>" # Xml.escape(clip(r, 35)) # "</Prtry></RjctRsn>\n" }; case null "" };
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
    # "<Document xmlns=\"urn:iso:std:iso:20022:tech:xsd:pain.012.001.07\">\n"
    # "  <MndtAccptncRpt>\n"
    # "    <GrpHdr>\n" # el(6, "MsgId", clip(messageId, 35)) # el(6, "CreDtTm", creationDateTime) # "    </GrpHdr>\n"
    # "    <UndrlygAccptncDtls>\n"
    # sp(6) # "<OrgnlMsgInf>" # "<MsgId>" # Xml.escape(clip(originalMessageId, 35)) # "</MsgId><MsgNmId>" # Xml.escape(originalMessageName) # "</MsgNmId></OrgnlMsgInf>\n"
    # sp(6) # "<AccptncRslt>\n" # el(8, "Accptd", if (accepted) "true" else "false") # rjct # sp(6) # "</AccptncRslt>\n"
    # sp(6) # "<OrgnlMndt><OrgnlMndtId>" # Xml.escape(clip(mandateId, 35)) # "</OrgnlMndtId></OrgnlMndt>\n"
    # "    </UndrlygAccptncDtls>\n"
    # "  </MndtAccptncRpt>\n"
    # "</Document>\n"
  };

  /// camt.025.001.05 — Rct: the receipt answering a camt.050 liquidity transfer (or any request the
  /// bank acknowledges with a status code and a description).
  public func camt025Xml(messageId : Text, creationDateTime : Text, originalMessageId : Text, originalMessageName : ?Text, statusCode : Text, description : ?Text) : Text {
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
    # "<Document xmlns=\"urn:iso:std:iso:20022:tech:xsd:camt.025.001.05\">\n"
    # "  <Rct>\n"
    # "    <MsgHdr>\n" # el(6, "MsgId", clip(messageId, 35)) # el(6, "CreDtTm", creationDateTime) # "    </MsgHdr>\n"
    # "    <RctDtls>\n"
    # sp(6) # "<OrgnlMsgId>" # "<MsgId>" # Xml.escape(clip(originalMessageId, 35)) # "</MsgId>" # (switch (originalMessageName) { case (?n) "<MsgNmId>" # Xml.escape(n) # "</MsgNmId>"; case null "" }) # "</OrgnlMsgId>\n"
    # sp(6) # "<ReqHdlg>\n" # el(8, "StsCd", clip(statusCode, 4)) # opt(8, "Desc", switch (description) { case (?d) ?clip(d, 140); case null null }) # sp(6) # "</ReqHdlg>\n"
    # "    </RctDtls>\n"
    # "  </Rct>\n"
    # "</Document>\n"
  };

  /// admi.007.001.01 — RctAck: the receipt acknowledgement answering a processing or resend request.
  public func admi007Xml(messageId : Text, creationDateTime : Text, relatedReference : Text, statusCode : Text, description : ?Text) : Text {
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
    # "<Document xmlns=\"urn:iso:std:iso:20022:tech:xsd:admi.007.001.01\">\n"
    # "  <RctAck>\n"
    # "    <MsgId>\n" # el(6, "MsgId", clip(messageId, 35)) # el(6, "CreDtTm", creationDateTime) # "    </MsgId>\n"
    # "    <Rpt>\n"
    # sp(6) # "<RltdRef><Ref>" # Xml.escape(clip(relatedReference, 35)) # "</Ref></RltdRef>\n"
    # sp(6) # "<ReqHdlg>\n" # el(8, "StsCd", clip(statusCode, 4)) # el(8, "StsDtTm", creationDateTime) # opt(8, "Desc", switch (description) { case (?d) ?clip(d, 140); case null null }) # sp(6) # "</ReqHdlg>\n"
    # "    </Rpt>\n"
    # "  </RctAck>\n"
    # "</Document>\n"
  };
}
