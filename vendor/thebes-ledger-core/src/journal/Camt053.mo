/// Camt053.mo; the journal's account statement, shaped as ISO 20022 camt.053.
///
/// A camt.053 "Bank To Customer Statement" is a projection of the journal: for
/// one account, one currency and one accounting period, the opening balance,
/// every posted leg as an `Ntry`, and the closing balance. The record type
/// `StatementEntry` is structurally identical to the one in the published
/// Thebes ISO 20022 example (`thebes-example-open-banking-iso20022`,
/// `ISO20022.mo`), so its decoder and validator accept what this module emits
///that round trip is acceptance criterion 9.
///
/// Every field is derived from committed journal data; nothing is invented:
///   NtryRef    "JRNL-<block index>-<n>"     n = ordinal of the leg within the statement
///   PaymentId  block index
///   UETR       RFC 9562 UUID (version 8) formed from the block hash
///   TxSts      "BOOK"
///   BookedAt   posting date, midnight UTC, nanoseconds
///   Othr       the account code (IBAN is not a journal concept)
///   RltdPties  counterpart account codes, same currency, other side
///   Ustrd      narration, "source:<kind>:<id>", "value-date:<YYYY-MM-DD>"

import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Int "mo:core/Int";
import List "mo:core/List";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Text "mo:core/Text";

import T "JournalTypes";
import Core "JournalCore";
import CivilDate "CivilDate";

module {

  public type ActiveCurrencyAndAmount = { currency : Text; minorUnits : Nat };

  public type StatementEntry = {
    entryId : Text;
    paymentId : Nat;
    uetr : Text;
    accountIban : ?Text;
    accountOtherId : ?Text;
    amount : ActiveCurrencyAndAmount;
    creditDebit : Text;
    status : Text;
    bookedAt : Int;
    counterpartyName : Text;
    remittance : [Text];
  };

  public type Statement = {
    account : T.AccountCode;
    currency : T.Currency;
    period : T.PeriodId;
    periodStart : T.Day;
    periodEnd : T.Day;
    openingDebits : Nat;
    openingCredits : Nat;
    closingDebits : Nat;
    closingCredits : Nat;
    entries : [StatementEntry];
  };

  public let CAMT053_NS : Text = "urn:iso:std:iso:20022:tech:xsd:camt.053.001.08";

  // ─── UETR from a block hash ────────────────────────────────────────────────

  let HEX : [Text] = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f"];

  func hexByte(b : Nat8) : Text { let n = Nat8.toNat(b); HEX[n / 16] # HEX[n % 16] };
  public func hexOf(b : Blob) : Text { var out = ""; for (x in b.vals()) { out #= hexByte(x) }; out };

  /// RFC 9562 version-8 UUID: sixteen bytes of the hash with the version
  /// nibble set to 8 and the variant bits set to 10.
  public func uetrFromHash(hash : Blob) : Text {
    let bs = Blob.toArray(hash);
    assert (bs.size() >= 16);
    let b = Array.tabulate<Nat8>(16, func(i) {
      if (i == 6) (bs[6] & 0x0F) | 0x80
      else if (i == 8) (bs[8] & 0x3F) | 0x80
      else bs[i]
    });
    var out = "";
    var i = 0;
    while (i < 16) {
      if (i == 4 or i == 6 or i == 8 or i == 10) out #= "-";
      out #= hexByte(b[i]);
      i += 1;
    };
    out
  };

  // ─── Projection ───────────────────────────────────────────────────────────

  /// Statement for (account, currency, period). `hashOf` supplies block hashes
  /// (the journal log owns them; the core does not). Null if the period or
  /// account does not exist.
  /// `subledger = null` is the account's own statement across every sub-ledger;
  /// a key selects one holder's entries and balances.
  public func statement(state : Core.State, blocks : Core.Blocks, periodId : T.PeriodId, account : T.AccountCode, subledger : ?T.SubledgerKey, currency : T.Currency, hashOf : Nat -> ?Blob) : ?Statement {
    let ?period = Core.getPeriod(state, periodId) else return null;
    let ?_ = Core.getAccount(state, account) else return null;
    let ?gl = Core.generalLedger(state, blocks, periodId, ?account) else return null;
    var opening : (Nat, Nat) = (0, 0);
    var closing : (Nat, Nat) = (0, 0);
    let entries = List.empty<StatementEntry>();
    var n = 0;
    let otherId = switch (subledger) { case null account; case (?k) account # "/" # hexOf(k) };
    for (acct in gl.accounts.vals()) {
      if (acct.currency == currency) {
        switch (subledger) {
          case null { opening := (acct.openingDebits, acct.openingCredits); closing := (acct.closingDebits, acct.closingCredits) };
          case (?k) {
            // sub-ledger balances at the period boundaries, by posting date
            let o = Core.balanceAsOf(state, account, ?k, currency, period.start - 1);
            let c = Core.balanceAsOf(state, account, ?k, currency, period.end);
            opening := (o.debits, o.credits); closing := (c.debits, c.credits);
          };
        };
        for (e in acct.entries.vals()) {
          let wanted = switch (subledger) { case null true; case (?k) e.subledger == ?k };
          if (not wanted) continue;
          n += 1;
          // A posted entry always has a block; if the log cannot produce its
          // hash the statement is withheld rather than emitted with an
          // invented identifier.
          let ?hash = hashOf(e.index) else return null;
          let counterparties = Text.join(e.counterparts.values(), ";");
          List.add(entries, {
            entryId = "JRNL-" # Nat.toText(e.index) # "-" # Nat.toText(n);
            paymentId = e.index;
            uetr = uetrFromHash(hash);
            accountIban = null;
            accountOtherId = ?otherId;
            amount = { currency; minorUnits = e.amount };
            creditDebit = switch (e.side) { case (#debit) "DBIT"; case (#credit) "CRDT" };
            status = "BOOK";
            bookedAt = CivilDate.toNanos(e.postingDate);
            counterpartyName = counterparties;
            remittance = [e.narration, "source:" # e.sourceRef.kind # ":" # e.sourceRef.id, "value-date:" # CivilDate.toText(e.valueDate)];
          });
        };
      };
    };
    ?{
      account; currency; period = periodId; periodStart = period.start; periodEnd = period.end;
      openingDebits = opening.0; openingCredits = opening.1; closingDebits = closing.0; closingCredits = closing.1;
      entries = List.toArray(entries);
    }
  };

  // ─── XML ──────────────────────────────────────────────────────────────────

  public func escape(value : Text) : Text {
    var out = Text.replace(value, #text "&", "&amp;");
    out := Text.replace(out, #text "<", "&lt;");
    out := Text.replace(out, #text ">", "&gt;");
    out := Text.replace(out, #text "\"", "&quot;");
    Text.replace(out, #text "'", "&apos;")
  };

  /// Decimal text of `minor` with exactly `minorUnits` fraction digits.
  public func amountText(minor : Nat, minorUnits : Nat8) : Text {
    let e = Nat8.toNat(minorUnits);
    if (e == 0) return Nat.toText(minor);
    let scale = 10 ** e;
    let whole = minor / scale;
    var frac = Nat.toText(minor % scale);
    while (frac.size() < e) { frac := "0" # frac };
    Nat.toText(whole) # "." # frac
  };

  func spaces(n : Nat) : Text { var s = ""; var i = 0; while (i < n) { s #= " "; i += 1 }; s };
  func elem(indent : Nat, tag : Text, value : Text) : Text { spaces(indent) # "<" # tag # ">" # escape(value) # "</" # tag # ">\n" };
  func amountXml(indent : Nat, tag : Text, ccy : Text, minor : Nat, mu : Nat8) : Text {
    spaces(indent) # "<" # tag # " Ccy=\"" # escape(ccy) # "\">" # amountText(minor, mu) # "</" # tag # ">\n"
  };

  func balanceXml(indent : Nat, code : Text, ccy : Text, dr : Nat, cr : Nat, mu : Nat8, day : T.Day) : Text {
    let (net, ind) : (Nat, Text) = if (dr >= cr) (dr - cr : Nat, "DBIT") else (cr - dr : Nat, "CRDT");
    spaces(indent) # "<Bal>\n"
    # spaces(indent + 2) # "<Tp><CdOrPrtry><Cd>" # code # "</Cd></CdOrPrtry></Tp>\n"
    # amountXml(indent + 2, "Amt", ccy, net, mu)
    # elem(indent + 2, "CdtDbtInd", ind)
    # spaces(indent + 2) # "<Dt><Dt>" # CivilDate.toText(day) # "</Dt></Dt>\n"
    # spaces(indent) # "</Bal>\n"
  };

  func entryXml(indent : Nat, e : StatementEntry, mu : Nat8) : Text {
    let day = CivilDate.fromNanos(Int.abs(e.bookedAt));
    var rem = "";
    for (line in e.remittance.vals()) { rem #= elem(indent + 8, "Ustrd", line) };
    spaces(indent) # "<Ntry>\n"
    # elem(indent + 2, "NtryRef", e.entryId)
    # amountXml(indent + 2, "Amt", e.amount.currency, e.amount.minorUnits, mu)
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

  /// camt.053 document for a statement. `msgId` and `creationDateTime` come from
  /// the caller so the output is a pure function of its arguments.
  public func toXml(s : Statement, minorUnits : Nat8, msgId : Text, creationDateTime : Text) : Text {
    var body = "";
    for (e in s.entries.vals()) { body #= entryXml(6, e, minorUnits) };
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
    # balanceXml(6, "OPBD", s.currency, s.openingDebits, s.openingCredits, minorUnits, s.periodStart)
    # body
    # balanceXml(6, "CLBD", s.currency, s.closingDebits, s.closingCredits, minorUnits, s.periodEnd)
    # "    </Stmt>\n"
    # "  </BkToCstmrStmt>\n"
    # "</Document>\n"
  };
};
