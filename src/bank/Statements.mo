/// Statements.mo — account statements as ISO 20022 messages.
///
/// The journal already projects one account, currency and period into the camt.053 shape
/// and round-trips it against the **deployed** published ISO 20022 example. Three things
/// are added here, and each is a decision rather than a format:
///
///   1. **A statement is cut, not re-derived.** camt.053 is built from the end-of-day batch statement
///      cut, so the opening and closing figures are the ones that stood at the cut and do
///      not move when a posting is later value-dated into that day. Every other figure this
///      estate serves is recomputed on demand; a customer's statement is the exception, and
///      deliberately so.
///   2. **The five balance kinds are stated, including the one a conventional core computes
///      by subtracting a hold table.** `CLAV` (closing available) differs from `CLBD`
///      (closing booked) by exactly the reservations the journal is holding, which the
///      journal reports as `debitsPending` and `creditsPending` on the balance. `PRCD`
///      (previously closed booked) is the prior period's close, which is what makes a
///      statement's continuity checkable by its reader.
///   3. **Every entry names the journal block it came from**, so one line of a statement can
///      be verified against the certified root without being given the rest of the book.
///
/// camt.052 is the intraday report of the same account from the live fold — no cut, because
/// an intraday report is a snapshot and says so. camt.054 is one notification per movement.

import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Int "mo:core/Int";
import Text "mo:core/Text";
import Blob "mo:core/Blob";
import Array "mo:core/Array";
import List "mo:core/List";
import Sha256 "mo:sha2/Sha256";

import JT "mo:journal/JournalTypes";
import JCore "mo:journal/JournalCore";
import JCamt "mo:journal/Camt053";
import CivilDate "mo:journal/CivilDate";
import JC "mo:journal/Canonical";

import RT "ReportTypes";

module {

  public let CAMT052_NS : Text = "urn:iso:std:iso:20022:tech:xsd:camt.052.001.08";
  public let CAMT053_NS : Text = JCamt.CAMT053_NS;
  public let CAMT054_NS : Text = "urn:iso:std:iso:20022:tech:xsd:camt.054.001.08";

  // ═══════════════════════════════════════════════════════════
  //  THE FIVE BALANCE KINDS
  // ═══════════════════════════════════════════════════════════

  public func balanceTypeCode(k : RT.BalanceType) : Text {
    switch (k) { case (#OPBD) "OPBD"; case (#CLBD) "CLBD"; case (#ITBD) "ITBD"; case (#PRCD) "PRCD"; case (#CLAV) "CLAV" }
  };

  func net(debits : Nat, credits : Nat) : Int { debits - credits : Int };

  /// The balances a camt.053 states for one account and currency. The cut supplies `OPBD`
  /// and `CLBD` — a record, so they do not move — while `PRCD` is the prior period's close
  /// and `CLAV` is the live available figure, which is the booked figure less what the
  /// journal is holding in reservations.
  public func statementBalances(
    js : JCore.State,
    account : JT.AccountCode,
    subledger : ?JT.SubledgerKey,
    currency : JT.Currency,
    cut : RT.StatementCutFigures,
    priorClose : ?{ debits : Nat; credits : Nat },
  ) : [RT.StatementBalance] {
    let live = JCore.balance(js, account, subledger, currency);
    let out = List.empty<RT.StatementBalance>();
    List.add(out, { kind = #OPBD; debits = cut.openingDebits; credits = cut.openingCredits;
                    net = net(cut.openingDebits, cut.openingCredits) });
    List.add(out, { kind = #CLBD; debits = cut.closingDebits; credits = cut.closingCredits;
                    net = net(cut.closingDebits, cut.closingCredits) });
    switch (priorClose) {
      case (?p) List.add(out, { kind = #PRCD; debits = p.debits; credits = p.credits; net = net(p.debits, p.credits) });
      case null {};
    };
    // The interim booked figure is the live booked one: what is on the books right now,
    // which is what `ITBD` means and is distinct from the cut.
    List.add(out, { kind = #ITBD; debits = live.debitsPosted; credits = live.creditsPosted;
                    net = net(live.debitsPosted, live.creditsPosted) });
    // Available: booked less the reservations the journal is holding. A conventional core
    // computes this by subtracting a hold table that nothing reconciles; here the pending
    // figures come from the same fold as the posted ones.
    List.add(out, {
      kind = #CLAV;
      debits = live.debitsPosted + live.debitsPending;
      credits = live.creditsPosted + live.creditsPending;
      net = net(live.debitsPosted + live.debitsPending, live.creditsPosted + live.creditsPending);
    });
    List.toArray(out)
  };

  // ═══════════════════════════════════════════════════════════
  //  THE XML
  // ═══════════════════════════════════════════════════════════

  func escape(t : Text) : Text {
    var out = "";
    for (c in t.chars()) {
      out #= (switch (c) {
        case ('&') "&amp;"; case ('<') "&lt;"; case ('>') "&gt;";
        case ('\"') "&quot;"; case ('\'') "&apos;";
        case (_) Text.fromChar(c);
      });
    };
    out
  };

  func pad(n : Nat, width : Nat) : Text {
    var s = Nat.toText(n);
    while (s.size() < width) s := "0" # s;
    s
  };

  /// Minor units to the decimal form ISO 20022 asks for, exactly: no floating point
  /// anywhere, because a statement figure that was ever a float is a figure nobody can
  /// reconcile.
  public func amountText(minor_ : Nat, minorUnits : Nat8) : Text {
    let u = Nat8.toNat(minorUnits);
    if (u == 0) return Nat.toText(minor_);
    var scale = 1;
    var i = 0;
    while (i < u) { scale *= 10; i += 1 };
    Nat.toText(minor_ / scale) # "." # pad(minor_ % scale, u)
  };

  func elem(indent : Nat, name : Text, value : Text) : Text {
    var pre = "";
    var i = 0;
    while (i < indent) { pre #= " "; i += 1 };
    pre # "<" # name # ">" # escape(value) # "</" # name # ">\n"
  };

  func balanceXml(indent : Nat, b : RT.StatementBalance, currency : JT.Currency, minorUnits : Nat8, day : JT.Day) : Text {
    var pre = "";
    var i = 0;
    while (i < indent) { pre #= " "; i += 1 };
    // ISO 20022 reports a balance as a positive amount with a credit/debit indicator, never
    // as a signed number
    let (amount, cdt) = if (b.net >= 0) (Int.abs(b.net), "DBIT") else (Int.abs(b.net), "CRDT");
    pre # "<Bal><Tp><CdOrPrtry><Cd>" # balanceTypeCode(b.kind) # "</Cd></CdOrPrtry></Tp>"
      # "<Amt Ccy=\"" # escape(currency) # "\">" # amountText(amount, minorUnits) # "</Amt>"
      # "<CdtDbtInd>" # cdt # "</CdtDbtInd>"
      # "<Dt><Dt>" # CivilDate.toText(day) # "</Dt></Dt></Bal>\n"
  };

  /// One `Ntry`, in the journal's own element shape.
  ///
  /// This **reproduces** `Camt053.mo`'s `entryXml` from the pinned submodule rather than calling
  /// it, because that function is private there; the construction and the file are named here as
  /// the NOTICE requires. Matching it element for element is not a convenience: the deployed
  /// published ISO 20022 example decodes exactly this subset (`iso20022-xml-subset-v1`) and
  /// compares every field, so a camt.052 or camt.054 that invented its own entry shape would be
  /// a message that one of our two independent checkers could not read.
  func entryXml(indent : Nat, e : JCamt.StatementEntry, minorUnits : Nat8) : Text {
    let day = CivilDate.fromNanos(Int.abs(e.bookedAt));
    var rem = "";
    for (line in e.remittance.vals()) { rem #= elem(indent + 8, "Ustrd", line) };
    spaces(indent) # "<Ntry>\n"
    # elem(indent + 2, "NtryRef", e.entryId)
    # spaces(indent + 2) # "<Amt Ccy=\"" # escape(e.amount.currency) # "\">"
      # amountText(e.amount.minorUnits, minorUnits) # "</Amt>\n"
    # elem(indent + 2, "CdtDbtInd", e.creditDebit)
    # elem(indent + 2, "Sts", e.status)
    # spaces(indent + 2) # "<BookgDt><Dt>" # CivilDate.toText(day) # "</Dt></BookgDt>\n"
    # spaces(indent + 2) # "<NtryDtls><TxDtls>\n"
    # elem(indent + 6, "PaymentId", Nat.toText(e.paymentId))
    # elem(indent + 6, "UETR", e.uetr)
    # elem(indent + 6, "TxSts", e.status)
    # elem(indent + 6, "BookedAt", Int.toText(e.bookedAt))
    # (switch (e.accountIban) { case (?v) elem(indent + 6, "IBAN", v); case null "" })
    # (switch (e.accountOtherId) { case (?v) elem(indent + 6, "Othr", v); case null "" })
    # elem(indent + 6, "RltdPties", e.counterpartyName)
    # spaces(indent + 6) # "<RmtInf>\n" # rem # spaces(indent + 6) # "</RmtInf>\n"
    # spaces(indent + 2) # "</TxDtls></NtryDtls>\n"
    # spaces(indent) # "</Ntry>\n"
  };

  func spaces(n : Nat) : Text {
    var out = "";
    var i = 0;
    while (i < n) { out #= " "; i += 1 };
    out
  };

  /// camt.053 — the statement of a cut day. `balances` carries all five kinds.
  public func camt053Xml(
    s : JCamt.Statement,
    balances : [RT.StatementBalance],
    minorUnits : Nat8,
    msgId : Text,
    creationDateTime : Text,
  ) : Text {
    var body = "";
    for (e in s.entries.vals()) body #= entryXml(6, e, minorUnits);
    var bals = "";
    for (b in balances.vals()) {
      let day = switch (b.kind) { case (#OPBD) s.periodStart; case (#PRCD) s.periodStart; case (_) s.periodEnd };
      bals #= balanceXml(6, b, s.currency, minorUnits, day);
    };
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
    # "<Document xmlns=\"" # CAMT053_NS # "\">\n"
    # "  <BkToCstmrStmt>\n"
    # "    <GrpHdr>\n"
    # elem(6, "MsgId", msgId)
    # elem(6, "CreDtTm", creationDateTime)
    # "    </GrpHdr>\n"
    # "    <Stmt>\n"
    # elem(6, "Id", s.period # "-" # s.account # "-" # s.currency)
    # "      <Acct><Id><Othr><Id>" # escape(s.account) # "</Id></Othr></Id><Ccy>" # escape(s.currency) # "</Ccy></Acct>\n"
    # "      <FrToDt><FrDtTm>" # CivilDate.toText(s.periodStart) # "T00:00:00Z</FrDtTm><ToDtTm>" # CivilDate.toText(s.periodEnd) # "T23:59:59Z</ToDtTm></FrToDt>\n"
    # bals
    # body
    # "    </Stmt>\n"
    # "  </BkToCstmrStmt>\n"
    # "</Document>\n"
  };

  /// camt.052 — the intraday account report. The same projection with no cut behind it, and
  /// it says so: the balances are `ITBD` and `CLAV`, never `CLBD`, because an intraday
  /// report has no closing figure to state.
  public func camt052Xml(
    s : JCamt.Statement,
    balances : [RT.StatementBalance],
    minorUnits : Nat8,
    msgId : Text,
    creationDateTime : Text,
    asOf : JT.Day,
  ) : Text {
    var body = "";
    for (e in s.entries.vals()) body #= entryXml(6, e, minorUnits);
    var bals = "";
    for (b in balances.vals()) {
      switch (b.kind) {
        case (#CLBD) {};                 // an intraday report states no closing booked figure
        case (_) bals #= balanceXml(6, b, s.currency, minorUnits, asOf);
      };
    };
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
    # "<Document xmlns=\"" # CAMT052_NS # "\">\n"
    # "  <BkToCstmrAcctRpt>\n"
    # "    <GrpHdr>\n"
    # elem(6, "MsgId", msgId)
    # elem(6, "CreDtTm", creationDateTime)
    # "    </GrpHdr>\n"
    # "    <Rpt>\n"
    # elem(6, "Id", "ITD-" # s.account # "-" # s.currency # "-" # CivilDate.toText(asOf))
    # elem(6, "CreDtTm", creationDateTime)
    # "      <Acct><Id><Othr><Id>" # escape(s.account) # "</Id></Othr></Id><Ccy>" # escape(s.currency) # "</Ccy></Acct>\n"
    # bals
    # body
    # "    </Rpt>\n"
    # "  </BkToCstmrAcctRpt>\n"
    # "</Document>\n"
  };

  /// camt.054 — one debit or credit notification. Emitted per movement, naming the journal
  /// block the movement is, so the notification and its proof are the same object.
  public func camt054Xml(
    account : JT.AccountCode,
    currency : JT.Currency,
    entry : JCamt.StatementEntry,
    minorUnits : Nat8,
    msgId : Text,
    creationDateTime : Text,
  ) : Text {
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
    # "<Document xmlns=\"" # CAMT054_NS # "\">\n"
    # "  <BkToCstmrDbtCdtNtfctn>\n"
    # "    <GrpHdr>\n"
    # elem(6, "MsgId", msgId)
    # elem(6, "CreDtTm", creationDateTime)
    # "    </GrpHdr>\n"
    # "    <Ntfctn>\n"
    # elem(6, "Id", "NTF-" # Nat.toText(entry.paymentId))
    # elem(6, "CreDtTm", creationDateTime)
    # "      <Acct><Id><Othr><Id>" # escape(account) # "</Id></Othr></Id><Ccy>" # escape(currency) # "</Ccy></Acct>\n"
    # entryXml(6, entry, minorUnits)
    # "    </Ntfctn>\n"
    # "  </BkToCstmrDbtCdtNtfctn>\n"
    # "</Document>\n"
  };

  // ═══════════════════════════════════════════════════════════
  //  THE REGISTER
  // ═══════════════════════════════════════════════════════════

  /// The block indices the statement's entries came from. An entry's `paymentId` **is** the
  /// journal block index, which is how a single line is proved.
  public func entryBlocks(s : JCamt.Statement) : [Nat] {
    Array.map<JCamt.StatementEntry, Nat>(s.entries, func(e) { e.paymentId })
  };

  public func refBytes(r : RT.StatementRef) : Blob {
    let w = JC.Writer();
    w.text("thebes.bank.statement.v1");
    w.text(r.id);
    w.nat(r.account);
    switch (r.kind) {
      case (#camt053(x)) { w.byte(0x53); w.nat(x.cut) };
      case (#camt052(x)) { w.byte(0x52); w.nat(x.asOf) };
      case (#camt054(x)) { w.byte(0x54); w.nat(x.movement) };
    };
    w.text(r.currency);
    w.text(r.period);
    w.nat(r.balances.size());
    for (b in r.balances.vals()) {
      w.text(balanceTypeCode(b.kind));
      w.nat(b.debits);
      w.nat(b.credits);
    };
    w.nat(r.entryBlocks.size());
    for (i in r.entryBlocks.vals()) w.nat(i);
    w.nat(r.atHeight);
    Blob.fromArray(w.toArray())
  };

  public func refHash(r : RT.StatementRef) : Blob { Sha256.fromBlob(#sha256, refBytes(r)) };

  /// The register key. A re-issued statement is identifiably the **same** statement: the
  /// key is the account, the kind and the date, so issuing it again increments a counter
  /// rather than creating a second statement for the same day.
  public func registerKey(account : Nat, kind : RT.StatementKind) : Text {
    switch (kind) {
      case (#camt053(x)) "053|" # Nat.toText(account) # "|" # Nat.toText(x.cut);
      case (#camt052(x)) "052|" # Nat.toText(account) # "|" # Nat.toText(x.asOf);
      case (#camt054(x)) "054|" # Nat.toText(account) # "|" # Nat.toText(x.movement);
    }
  };
};
