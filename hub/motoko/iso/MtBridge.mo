/// MtBridge.mo; the legacy MT bridge of the hub: thirteen SWIFT FIN message types read
/// into the hub's ISO 20022 records and written back from them, each with its field-to-element mapping table
/// exposed as data (`mappings()`) so the fixture set (`integration-kit/legacy/mt-mappings.json`) and the code
/// are checked against each other rather than kept by hand.
///
///   MT101 ↔ pain.001 (one initiation per sequence B)      MT103 ↔ pain.001 (the hub's bridge convention)
///   MT104 ↔ pain.008 (one collection per sequence B)      MT202 ↔ pacs.009        MT202 COV ↔ pacs.009 COV + pacs.008
///   MT900 / MT910 ↔ camt.054 (one entry)                  MT940 / MT950 ↔ camt.053 (entries)   MT942 ↔ camt.052 (report)
///   MT192 ↔ camt.056     MT196 ↔ camt.029     MT199 ↔ camt.110 (the free-format investigation)
///
/// A FIN message is its blocks: `{1:F01<sender LT>…}{2:I<type><receiver LT>N}{3:{119:COV}{121:<UETR>}}{4:` … `-}`.
/// The bridge reads the type from block 2 (or a caller's hint when block 2 is absent), the UETR and the COV
/// flag from block 3, and the fields of block 4 with the tag parser of LegacyMT. What an MT type does not
/// carry and a record requires is a documented convention (the `note` of the mapping row), never a guess
/// hidden in code: the creation date-time, the settlement method and the message versions come from the
/// caller's options; the charge bearer of an FI transfer is SHAR; an entry without `/UETR/` in its narrative
/// gets the placeholder UUID the statement decoder of LegacyMT uses.
///
/// Every decoder answers the record, or the issues (`schema` tier, rule ids `MT<type>-<field>-<what>`); every
/// encoder answers the FIN text, or the fields a record lacks. The integration kit's bridge runner shows, for
/// each type: MT → record → MT → record equal; record → XML → record equal (the compact codec for pain.001,
/// pain.008, pacs.008, pacs.009, camt.053, camt.054, the investigations; the schema-profile codec for
/// camt.052); and the written MT parsed by Prowide swift-core with the same field values.

import Array "mo:core/Array";
import Char "mo:core/Char";
import Int "mo:core/Int";
import Iter "mo:core/Iter";
import List "mo:core/List";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Nat32 "mo:core/Nat32";
import Result "mo:core/Result";
import Text "mo:core/Text";

import ISO "../ISO20022";
import LegacyMT "../LegacyMT";
import Breadth "IsoBreadth";

module {

  public type Issue = ISO.ValidationIssue;
  public type Field = LegacyMT.Mt103Field;

  /// The blocks of a FIN message the bridge reads.
  public type Envelope = {
    sender : ?Text;      // block 1's logical terminal, as a BIC (8 or 11)
    receiver : ?Text;    // block 2's (input messages)
    mtType : ?Text;      // "202" from block 2
    cov : Bool;          // block 3 field 119 = COV
    uetr : ?Text;        // block 3 field 121
    fields : [Field];    // block 4
  };

  /// What the records carry and MT does not; the caller supplies them once.
  public type Options = {
    creationDateTime : Text;   // the records' CreDtTm; MT has no creation timestamp
    settlementMethod : Text;   // the guideline's (INDA for correspondent banking, CLRG on a clearing system)
    country : Text;            // the country of a party whose address has none (the guideline's)
    versions : Text -> Text;   // message versions by family ("pain.001" → "001.09"), the guideline's
  };

  public type Message = {
    #pain001 : [ISO.CustomerCreditTransferInitiation];   // MT101 (one per sequence B), MT103 (one)
    #pain008 : [ISO.DirectDebitMessage];                 // MT104 (one per sequence B)
    #pacs009 : ISO.Pacs009FinancialInstitutionCreditTransfer;   // MT202
    #cover : ISO.CoverPayment;                           // MT202 COV
    #camt054 : ISO.StatementEntry;                       // MT900 (debit), MT910 (credit)
    #camt053 : [ISO.StatementEntry];                     // MT940, MT950
    #camt052 : Breadth.AccountReport;                    // MT942
    #investigation : ISO.InvestigationMessage;           // MT192 (camt.056), MT196 (camt.029), MT199 (camt.110)
  };

  public type Decoded = { mtType : Text; iso : Text; message : Result.Result<Message, [Issue]> };

  // ─── the mapping tables ───

  public type FieldMap = { field : Text; element : Text; note : Text };
  public type Mapping = { mt : Text; iso : Text; fields : [FieldMap] };

  let ENVELOPE : [FieldMap] = [
    { field = "{1:} sender LT"; element = "the instructing side's BIC (DbtrAgt / InstgAgt / AcctSvcr)"; note = "block 1, logical terminal address; branch XXX dropped" },
    { field = "{2:} receiver LT"; element = "the instructed side's BIC (CdtrAgt / InstdAgt) when no 57a"; note = "block 2 of an input message" },
    { field = "{3:121}"; element = "UETR"; note = "absent → the record's UETR is null (statements: the placeholder UUID)" },
  ];

  public func mappings() : [Mapping] { [
    { mt = "MT101"; iso = "pain.001"; fields = Array.concat(ENVELOPE, [
      { field = "20"; element = "—"; note = "the batch's sender reference; the compact pain.001 carries one transaction, so it is read and dropped, and written back as the first transaction's reference" },
      { field = "28D"; element = "—"; note = "message index/total; written 1/1, not read into the record" },
      { field = "30"; element = "PmtInf/ReqdExctnDt"; note = "sequence A" },
      { field = "50K / 50H / 50F"; element = "Dbtr, DbtrAcct"; note = "sequence B (or A when the batch has one debtor): /account, name, address lines" },
      { field = "52A"; element = "DbtrAgt/FinInstnId/BICFI"; note = "sequence B (or A); absent → the sender" },
      { field = "21"; element = "GrpHdr/MsgId, PmtId/EndToEndId"; note = "sequence B; starts a transaction — the transaction reference is the initiation's message id, unique in the hub's payment index" },
      { field = "32B"; element = "Amt/InstdAmt"; note = "currency and amount, comma decimal" },
      { field = "57A"; element = "CdtrAgt/FinInstnId/BICFI"; note = "absent → the receiver" },
      { field = "59 / 59A / 59F"; element = "Cdtr, CdtrAcct"; note = "/account, name, address lines" },
      { field = "70"; element = "RmtInf/Ustrd"; note = "one line per Ustrd" },
      { field = "71A"; element = "—"; note = "written SHA; pain.001's compact record carries no charge bearer" },
    ]) },
    { mt = "MT103"; iso = "pain.001"; fields = Array.concat(ENVELOPE, [
      { field = "20"; element = "GrpHdr/MsgId, PmtId/EndToEndId"; note = "the hub's bridge convention: MT103 reads into the customer initiation" },
      { field = "23B"; element = "—"; note = "written CRED" },
      { field = "32A"; element = "ReqdExctnDt, Amt/InstdAmt"; note = "YYMMDD, currency, amount" },
      { field = "50K / 50F"; element = "Dbtr, DbtrAcct"; note = "" },
      { field = "52A"; element = "DbtrAgt/FinInstnId/BICFI"; note = "absent → the sender" },
      { field = "57A"; element = "CdtrAgt/FinInstnId/BICFI"; note = "absent → the receiver" },
      { field = "59 / 59F"; element = "Cdtr, CdtrAcct"; note = "" },
      { field = "70"; element = "RmtInf/Ustrd"; note = "" },
      { field = "71A"; element = "—"; note = "written SHA" },
    ]) },
    { mt = "MT104"; iso = "pain.008"; fields = Array.concat(ENVELOPE, [
      { field = "20"; element = "GrpHdr/MsgId"; note = "sequence A" },
      { field = "30"; element = "PmtInf/ReqdColltnDt"; note = "sequence A" },
      { field = "50K / 50A"; element = "Cdtr, CdtrAcct, InitgPty"; note = "sequence B (or A): the creditor collecting" },
      { field = "52A"; element = "CdtrAgt/FinInstnId/BICFI"; note = "sequence B (or A); absent → the sender" },
      { field = "21"; element = "PmtId/EndToEndId"; note = "sequence B; starts a collection" },
      { field = "21C"; element = "DrctDbtTx/MndtRltdInf/MndtId"; note = "the mandate reference; required" },
      { field = "23E"; element = "PmtTpInf/SeqTp"; note = "AUTH/NAUT/OTHR are not a sequence type: the record reads RCUR; written OTHR" },
      { field = "32B"; element = "InstdAmt"; note = "" },
      { field = "57A"; element = "DbtrAgt/FinInstnId/BICFI"; note = "absent → the receiver" },
      { field = "59 / 59A"; element = "Dbtr, DbtrAcct"; note = "" },
      { field = "70"; element = "RmtInf/Ustrd"; note = "" },
    ]) },
    { mt = "MT202"; iso = "pacs.009"; fields = Array.concat(ENVELOPE, [
      { field = "20"; element = "GrpHdr/MsgId, PmtId/InstrId"; note = "" },
      { field = "21"; element = "PmtId/EndToEndId"; note = "" },
      { field = "32A"; element = "IntrBkSttlmDt, IntrBkSttlmAmt"; note = "" },
      { field = "52A"; element = "Dbtr/FinInstnId/BICFI"; note = "the ordering institution; absent → the sender" },
      { field = "53A"; element = "—"; note = "the sender's correspondent; not carried by the compact record" },
      { field = "56A"; element = "IntrmyAgt1/FinInstnId/BICFI"; note = "" },
      { field = "57A"; element = "CdtrAgt/FinInstnId/BICFI"; note = "absent → the receiver" },
      { field = "58A"; element = "Cdtr/FinInstnId/BICFI"; note = "the beneficiary institution; required" },
      { field = "72"; element = "—"; note = "sender to receiver information; not carried by the compact record" },
      { field = "(none)"; element = "ChrgBr"; note = "MT202 carries no charge bearer; the record's is SHAR" },
      { field = "(options)"; element = "SttlmInf/SttlmMtd"; note = "the guideline's settlement method" },
    ]) },
    { mt = "MT202COV"; iso = "pacs.009 COV + pacs.008"; fields = Array.concat(ENVELOPE, [
      { field = "{3:119}"; element = "cover flag"; note = "COV" },
      { field = "20, 21, 32A, 52A, 56A, 57A, 58A"; element = "the cover pacs.009 as MT202"; note = "sequence A; 21 is also the underlying pacs.008's MsgId and EndToEndId" },
      { field = "50K / 50F"; element = "underlying Dbtr, DbtrAcct"; note = "sequence B" },
      { field = "52A"; element = "underlying DbtrAgt"; note = "sequence B; absent → the sender" },
      { field = "57A"; element = "underlying CdtrAgt"; note = "sequence B; absent → the receiver" },
      { field = "59 / 59F"; element = "underlying Cdtr, CdtrAcct"; note = "sequence B" },
      { field = "70"; element = "underlying RmtInf/Ustrd"; note = "sequence B" },
      { field = "33B"; element = "underlying InstdAmt"; note = "sequence B; absent → the cover amount" },
    ]) },
    { mt = "MT900"; iso = "camt.054"; fields = Array.concat(ENVELOPE, [
      { field = "20"; element = "Ntry/NtryRef"; note = "" },
      { field = "21"; element = "—"; note = "the related reference, kept in the narrative only" },
      { field = "25"; element = "Acct/Id (IBAN or Othr)"; note = "" },
      { field = "32A"; element = "BookgDt, Amt"; note = "CdtDbtInd DBIT" },
      { field = "52A"; element = "RltdPties (the ordering institution's BIC as the counterparty name)"; note = "absent → the sender" },
      { field = "72"; element = "RmtInf/Ustrd; /UETR/ token → UETR"; note = "no UETR → the placeholder UUID" },
    ]) },
    { mt = "MT910"; iso = "camt.054"; fields = Array.concat(ENVELOPE, [
      { field = "20"; element = "Ntry/NtryRef"; note = "" },
      { field = "21"; element = "—"; note = "the related reference, kept in the narrative only" },
      { field = "25"; element = "Acct/Id (IBAN or Othr)"; note = "" },
      { field = "32A"; element = "BookgDt, Amt"; note = "CdtDbtInd CRDT" },
      { field = "50K / 52A"; element = "RltdPties (the ordering party's name)"; note = "" },
      { field = "72"; element = "RmtInf/Ustrd; /UETR/ token → UETR"; note = "no UETR → the placeholder UUID" },
    ]) },
    { mt = "MT940"; iso = "camt.053"; fields = Array.concat(ENVELOPE, [
      { field = "20"; element = "—"; note = "the compact camt.053 record has no statement id: read and dropped, written back as the first entry's reference" },
      { field = "25"; element = "Acct/Id"; note = "" },
      { field = "28C"; element = "—"; note = "statement number; written 1/1" },
      { field = "60F"; element = "Bal OPBD"; note = "the currency of the entries; the compact camt.053 carries entries only" },
      { field = "61"; element = "Ntry: ValDt, CdtDbtInd, Amt, NtryRef (//reference)"; note = "" },
      { field = "86"; element = "Ntry/NtryDtls/RmtInf; /UETR/ → UETR"; note = "" },
      { field = "62F"; element = "Bal CLBD"; note = "written from the entries' sum" },
    ]) },
    { mt = "MT950"; iso = "camt.053"; fields = Array.concat(ENVELOPE, [
      { field = "20, 25, 28C, 60F, 61, 62F"; element = "as MT940"; note = "MT950 has no field 86: entries carry no remittance and get the placeholder UUID" },
    ]) },
    { mt = "MT942"; iso = "camt.052"; fields = Array.concat(ENVELOPE, [
      { field = "20"; element = "Rpt/Id, GrpHdr/MsgId"; note = "" },
      { field = "25"; element = "Rpt/Acct/Id"; note = "" },
      { field = "28C"; element = "—"; note = "written 1/1" },
      { field = "34F"; element = "Rpt/Acct/Ccy"; note = "the floor limit's currency; the limit itself is not carried" },
      { field = "13D"; element = "Rpt/FrToDt/ToDtTm (and FrDtTm at the day's start)"; note = "YYMMDDHHMM+offset → ISO date-time" },
      { field = "61"; element = "Ntry: ValDt, CdtDbtInd, Amt, NtryRef"; note = "" },
      { field = "86"; element = "Ntry/NtryDtls/RmtInf, RltdPties"; note = "" },
      { field = "90D / 90C"; element = "—"; note = "written from the entries; not read" },
    ]) },
    { mt = "MT192"; iso = "camt.056"; fields = Array.concat(ENVELOPE, [
      { field = "20"; element = "Assgnmt/Id, GrpHdr/MsgId"; note = "" },
      { field = "21"; element = "Undrlyg/OrgnlGrpInf/OrgnlMsgId"; note = "the reference of the message to cancel" },
      { field = "11S"; element = "—"; note = "MT type and date of the original; written 103 + the creation date" },
      { field = "79"; element = "CxlRsnInf/Rsn/Cd (first line, /code/), AddtlInf (the rest)"; note = "/UETR/ token → OrgnlUETR" },
    ]) },
    { mt = "MT196"; iso = "camt.029"; fields = Array.concat(ENVELOPE, [
      { field = "20"; element = "Assgnmt/Id, GrpHdr/MsgId"; note = "" },
      { field = "21"; element = "OrgnlGrpInfAndSts/OrgnlMsgId"; note = "" },
      { field = "76"; element = "CxlDtls/TxInfAndSts/CxlStsRsnInf: Rsn/Cd (first line, /code/), the action (/action/), AddtlInf"; note = "" },
      { field = "11R"; element = "—"; note = "MT type and date of the message answered; written 192 + the creation date" },
    ]) },
    { mt = "MT199"; iso = "camt.110"; fields = Array.concat(ENVELOPE, [
      { field = "20"; element = "Assgnmt/Id, GrpHdr/MsgId"; note = "" },
      { field = "21"; element = "Undrlyg/OrgnlMsgId"; note = "" },
      { field = "79"; element = "Rsn/Cd (first line, /code/), the action (/action/), AddtlInf"; note = "the free-format investigation" },
    ]) },
  ] };

  public func mapping(mt : Text) : ?Mapping { for (m in mappings().vals()) { if (m.mt == mt) return ?m }; null };

  // ─── the envelope ───

  func between(t : Text, open : Text, close : Text) : ?Text {
    let parts = Iter.toArray(Text.split(t, #text open));
    if (parts.size() < 2) return null;
    let rest = parts[1];
    let ends = Iter.toArray(Text.split(rest, #text close));
    if (ends.size() == 0) null else ?ends[0]
  };
  func slice(t : Text, from : Nat, to : Nat) : Text {
    let a = Text.toArray(t);
    if (from >= a.size()) return "";
    Text.fromIter(Iter.fromArray(Array.tabulate<Char>(Nat.min(to, a.size()) - from, func(i) { a[from + i] })))
  };
  /// A logical terminal address (BIC8 + LT code + branch) as a BIC: the branch kept unless it is XXX.
  func bicOfLt(lt : Text) : ?Text {
    if (Text.size(lt) < 8) return null;
    let branch = slice(lt, 9, 12);
    ?(slice(lt, 0, 8) # (if (branch == "XXX" or branch == "") "" else branch))
  };
  func trim(t : Text) : Text { Text.trim(t, #predicate(func(c : Char) : Bool { c == ' ' or c == '\t' or c == '\r' or c == '\n' })) };

  public func parse(text : Text) : Envelope {
    let b1 = between(text, "{1:", "}");
    let b2 = between(text, "{2:", "}");
    let b3 = between(text, "{3:", "}{4:");
    let sender = switch (b1) { case (?b) { if (Text.startsWith(b, #text "F01")) bicOfLt(slice(b, 3, 15)) else null }; case null null };
    let (mtType, receiver) = switch (b2) {
      case (?b) {
        if (Text.startsWith(b, #text "I")) (?slice(b, 1, 4), bicOfLt(slice(b, 4, 16)))
        else if (Text.startsWith(b, #text "O")) (?slice(b, 1, 4), null)
        else (null, null)
      };
      case null (null, null);
    };
    let cov = switch (b3) { case (?b) Text.contains(b, #text "{119:COV}"); case null false };
    let uetr = switch (b3) { case (?b) { switch (between(b, "{121:", "}")) { case (?u) { if (ISO.validUetr(u)) ?u else null }; case null null } }; case null null };
    let body = switch (between(text, "{4:", "-}")) { case (?b) b; case null text };
    { sender; receiver; mtType; cov; uetr; fields = LegacyMT.parseMt103Fields(body) }
  };

  /// The FIN envelope around a block-4 body.
  func fin(mt : Text, sender : Text, receiver : Text, uetr : ?Text, cov : Bool, body : Text) : Text {
    func lt(bic : Text) : Text { let b8 = slice(bic, 0, 8); let br = if (Text.size(bic) == 11) slice(bic, 8, 11) else "XXX"; b8 # "A" # br };
    let b3 = if (cov or uetr != null) "{3:" # (if (cov) "{119:COV}" else "") # (switch (uetr) { case (?u) "{121:" # u # "}"; case null "" }) # "}" else "";
    "{1:F01" # lt(sender) # "0000000000}{2:I" # mt # lt(receiver) # "N}" # b3 # "{4:\n" # body # "-}"
  };

  // ─── fields ───

  // LegacyMT's parser splits a tag from its option letter: `21C` is tag "21", option "C"
  func field(fs : [Field], tag : Text) : ?Field { for (f in fs.vals()) { if (f.tag == tag) return ?f }; null };
  func fieldOpt(fs : [Field], tag : Text, option : ?Text) : ?Field { for (f in fs.vals()) { if (f.tag == tag and f.option == option) return ?f }; null };
  func value(fs : [Field], tag : Text) : ?Text { switch (field(fs, tag)) { case (?f) ?f.value; case null null } };
  func valueOpt(fs : [Field], tag : Text, option : ?Text) : ?Text { switch (fieldOpt(fs, tag, option)) { case (?f) ?f.value; case null null } };
  func lines(v : Text) : [Text] { Array.filter<Text>(Array.map<Text, Text>(Iter.toArray(Text.split(v, #char '\n')), trim), func(l) { l != "" }) };
  func firstLine(v : Text) : Text { let ls = lines(v); if (ls.size() == 0) "" else ls[0] };
  func digit(c : Char) : Bool { Char.isDigit(c) };
  func upperAlnum(c : Char) : Bool { (c >= 'A' and c <= 'Z') or Char.isDigit(c) };

  /// The sequences of a multi-transaction message: what precedes the first `21` and each `21`-led run.
  func sequences(fs : [Field], startTag : Text) : ([Field], [[Field]]) {
    let a = List.empty<Field>();
    let bs = List.empty<[Field]>();
    var current : ?List.List<Field> = null;
    for (f in fs.vals()) {
      if (f.tag == startTag and f.option == null) { switch (current) { case (?c) List.add(bs, List.toArray(c)); case null {} }; let c = List.empty<Field>(); List.add(c, f); current := ?c }
      else { switch (current) { case (?c) List.add(c, f); case null List.add(a, f) } };
    };
    switch (current) { case (?c) List.add(bs, List.toArray(c)); case null {} };
    (List.toArray(a), List.toArray(bs))
  };

  func issue(rule : Text, path : Text, msg : Text) : Issue { ISO.publicIssue("schema", rule, path, msg) };

  /// `YYMMDD` → ISO date; the century is 2000 (FIN's own convention for its two-digit years).
  func date6(t : Text) : ?Text {
    let a = Text.toArray(t);
    if (a.size() < 6) return null;
    for (i in Nat.range(0, 6)) { if (not digit(a[i])) return null };
    ?("20" # slice(t, 0, 2) # "-" # slice(t, 2, 4) # "-" # slice(t, 4, 6))
  };
  func yymmdd(iso : Text) : Text { slice(iso, 2, 4) # slice(iso, 5, 7) # slice(iso, 8, 10) };

  /// A FIN amount (`12500,00`, at most the currency's fraction digits) in minor units.
  func amountMinor(t : Text, mu : Nat8) : ?Nat {
    let s = Text.replace(t, #char ',', ".");
    Breadth.amountMinor(s, mu)
  };
  func amountFin(minor : Nat, mu : Nat8) : Text { Text.replace(Breadth.amountText(minor, mu), #char '.', ",") };

  type Money = { date : ?Text; currency : Text; minor : Nat };
  /// `32A`: YYMMDD + CCY + amount; `32B` / `33B` / `34F`: CCY + amount (no date).
  func money(v : Text, withDate : Bool, mu : Text -> ?Nat8, tag : Text, mt : Text, issues : List.List<Issue>) : Money {
    let s = firstLine(v);
    let date = if (withDate) date6(s) else null;
    if (withDate and date == null) List.add(issues, issue(mt # "-" # tag # "-DATE", "$." # tag, "field " # tag # " starts with a YYMMDD value date"));
    let off = if (withDate) 6 else 0;
    let ccy = slice(s, off, off + 3);
    if (not ISO.validCurrencyCode(ccy)) List.add(issues, issue(mt # "-" # tag # "-CURRENCY", "$." # tag, "field " # tag # " carries an ISO 4217 currency after the date"));
    let minor = switch (mu(ccy)) {
      case null { List.add(issues, issue(mt # "-" # tag # "-CURRENCY", "$." # tag, "currency " # ccy # " is not one of the guideline")); 0 };
      case (?m) { switch (amountMinor(slice(s, off + 3, Text.size(s)), m)) { case (?n) n; case null { List.add(issues, issue(mt # "-" # tag # "-AMOUNT", "$." # tag, "field " # tag # " amount is a decimal with a comma, within the currency's fraction digits")); 0 } } };
    };
    { date; currency = ccy; minor }
  };

  /// Option A: the BIC on the first line not starting with `/` (an account line may precede it).
  func bicOf(f : ?Field) : ?Text {
    switch (f) {
      case null null;
      case (?x) {
        for (l in lines(x.value).vals()) {
          if (not Text.startsWith(l, #char '/')) {
            let n = Text.size(l);
            if ((n == 8 or n == 11) and Array.foldLeft<Char, Bool>(Text.toArray(l), true, func(ok, c) { ok and upperAlnum(c) })) return ?l;
            return null;
          };
        };
        null
      };
    }
  };
  func agentOr(fs : [Field], tag : Text, fallback : Text, mt : Text, issues : List.List<Issue>) : ISO.FinancialInstitutionIdentification {
    switch (field(fs, tag)) {
      case null { { bicfi = fallback; name = null } };
      case (?f) { switch (bicOf(?f)) { case (?b) { { bicfi = b; name = null } }; case null { List.add(issues, issue(mt # "-" # tag # "-BIC", "$." # tag # "A", "field " # tag # "A carries an 8 or 11 character BIC")); { bicfi = fallback; name = null } } } };
    }
  };
  func requiredAgent(fs : [Field], tag : Text, mt : Text, issues : List.List<Issue>) : ISO.FinancialInstitutionIdentification {
    switch (field(fs, tag)) {
      case null { List.add(issues, issue(mt # "-" # tag # "-REQUIRED", "$." # tag # "A", "field " # tag # "A is required")); { bicfi = ""; name = null } };
      case (?_) agentOr(fs, tag, "", mt, issues);
    }
  };

  /// A party field (50K/50H/50F/59/59F/59A): `/account` first, then the name, then address lines; option F's
  /// numbered lines (`1/`, `2/`, `3/CC/Town`) read the same way with their prefixes dropped.
  func partyOf(f : ?Field, fallbackName : Text, currency : Text, country : Text) : (ISO.PartyIdentification, ISO.CashAccount) {
    let ls = switch (f) { case (?x) lines(x.value); case null [] };
    var account : ?Text = null;
    var name = fallbackName;
    var town = "Legacy";
    var ctry = country;
    let addr = List.empty<Text>();
    var i = 0;
    if (ls.size() > 0 and Text.startsWith(ls[0], #char '/')) { account := ?slice(ls[0], 1, Text.size(ls[0])); i := 1 };
    var named = false;
    while (i < ls.size()) {
      let l = ls[i];
      let body = if (Text.size(l) > 2 and Text.startsWith(slice(l, 1, 2), #char '/') and digit(Text.toArray(l)[0])) slice(l, 2, Text.size(l)) else l;
      if (Text.startsWith(l, #text "3/")) {
        // option F line 3: country/town
        ctry := slice(body, 0, 2);
        if (Text.size(body) > 3) town := slice(body, 3, Text.size(body));
      } else if (not named) { name := body; named := true }
      else List.add(addr, body);
      i += 1;
    };
    let postal : ?ISO.PostalAddress = if (List.size(addr) == 0 and town == "Legacy") null else ?{ country = ctry; townName = town; addressLine = List.toArray(addr); postalCode = null };
    let acct : ISO.CashAccount = switch (account) {
      case (?a) { if (ISO.validIban(a)) ({ iban = ?a; otherId = null; currency = ?currency }) else ({ iban = null; otherId = ?a; currency = ?currency }) };
      case null { { iban = null; otherId = null; currency = ?currency } };
    };
    ({ name; postalAddress = postal; lei = null }, acct)
  };
  /// The party written as option K (account line, name, address lines).
  func partyFin(tag : Text, p : ISO.PartyIdentification, a : ISO.CashAccount) : Text {
    var o = ":" # tag # ":";
    switch (a.iban, a.otherId) { case (?i, _) o #= "/" # i # "\n"; case (null, ?x) o #= "/" # x # "\n"; case (null, null) {} };
    o #= p.name # "\n";
    switch (p.postalAddress) { case (?pa) { for (l in pa.addressLine.vals()) o #= l # "\n"; if (pa.townName != "Legacy") o #= pa.townName # " " # pa.country # "\n" }; case null {} };
    o
  };
  func remittance(fs : [Field]) : ISO.RemittanceInformation {
    let u = switch (value(fs, "70")) { case (?v) lines(v); case null [] };
    { unstructured = u; structuredCreditorReference = null }
  };
  func remittanceFin(r : ISO.RemittanceInformation) : Text { if (r.unstructured.size() == 0) "" else ":70:" # Text.join(r.unstructured.vals(), "\n") # "\n" };
  func agentFin(tag : Text, a : ISO.FinancialInstitutionIdentification) : Text { ":" # tag # "A:" # a.bicfi # "\n" };

  func nonEmpty(v : ?Text, rule : Text, path : Text, what : Text, issues : List.List<Issue>) : Text {
    switch (v) { case (?x) { if (trim(firstLine(x)) == "") { List.add(issues, issue(rule, path, what)); "" } else trim(firstLine(x)) }; case null { List.add(issues, issue(rule, path, what)); "" } }
  };
  func mu2(mu : Text -> ?Nat8, ccy : Text) : Nat8 { switch (mu(ccy)) { case (?m) m; case null 2 } };
  func done<T>(v : T, issues : List.List<Issue>) : Result.Result<T, [Issue]> { if (List.size(issues) > 0) #err(List.toArray(issues)) else #ok(v) };

  // ─── MT101 / MT103 ↔ pain.001 ───

  func creditTransfer(mt : Text, seqA : [Field], seqB : [Field], messageId : Text, env : Envelope, o : Options, mu : Text -> ?Nat8, issues : List.List<Issue>) : ISO.CustomerCreditTransferInitiation {
    let sender = switch (env.sender) { case (?s) s; case null "" };
    let receiver = switch (env.receiver) { case (?r) r; case null "" };
    let fs = Array.concat(seqB, seqA);   // sequence B's fields first: they override sequence A's
    var messageIdOut = messageId;
    let (m, endToEnd, execDate) = if (mt == "MT103") {
      let m = money(nonEmpty(value(fs, "32"), mt # "-32A-REQUIRED", "$.32A", "field 32A is required", issues), true, mu, "32A", mt, issues);
      (m, messageId, m.date)
    } else {
      let m = money(nonEmpty(value(seqB, "32"), mt # "-32B-REQUIRED", "$.32B", "field 32B is required in every sequence B", issues), false, mu, "32B", mt, issues);
      let e2e = nonEmpty(valueOpt(seqB, "21", null), mt # "-21-REQUIRED", "$.21", "field 21 starts every transaction", issues);
      messageIdOut := e2e;   // one initiation per transaction: its reference is its message id
      let d = switch (value(seqA, "30")) { case (?v) { let d = date6(firstLine(v)); if (d == null) List.add(issues, issue(mt # "-30-DATE", "$.30", "field 30 is a YYMMDD requested execution date")); d }; case null { List.add(issues, issue(mt # "-30-REQUIRED", "$.30", "field 30 is required")); null } };
      (m, e2e, d)
    };
    if (field(fs, "50") == null) List.add(issues, issue(mt # "-50-REQUIRED", "$.50", "field 50a (the ordering customer) is required"));
    if (field(fs, "59") == null) List.add(issues, issue(mt # "-59-REQUIRED", "$.59", "field 59a (the beneficiary) is required"));
    let debtorAgent = agentOr(fs, "52", sender, mt, issues);
    let creditorAgent = agentOr(fs, "57", receiver, mt, issues);
    let (debtor, debtorAccount) = partyOf(field(fs, "50"), "legacy debtor", m.currency, o.country);
    let (creditor, creditorAccount) = partyOf(field(fs, "59"), "legacy creditor", m.currency, o.country);
    {
      messageId = messageIdOut; creationDateTime = o.creationDateTime; requestedExecutionDate = execDate;
      initiatingParty = debtor; debtor; debtorAccount; debtorAgent; creditor; creditorAccount; creditorAgent;
      paymentTypeInformation = ?{ serviceLevel = null; localInstrument = ?mt; categoryPurpose = null };
      instructedAmount = { currency = m.currency; minorUnits = m.minor }; endToEndId = endToEnd;
      remittanceInformation = remittance(fs); requestedUetr = env.uetr;
    }
  };

  func decodePain001(mt : Text, env : Envelope, o : Options, mu : Text -> ?Nat8) : Result.Result<Message, [Issue]> {
    let issues = List.empty<Issue>();
    let messageId = nonEmpty(value(env.fields, "20"), mt # "-20-REQUIRED", "$.20", "field 20 is required", issues);
    let out = List.empty<ISO.CustomerCreditTransferInitiation>();
    if (mt == "MT103") List.add(out, creditTransfer(mt, [], env.fields, messageId, env, o, mu, issues))
    else {
      let (a, bs) = sequences(env.fields, "21");
      if (bs.size() == 0) List.add(issues, issue(mt # "-21-REQUIRED", "$.21", "an MT101 carries at least one transaction (sequence B starts with field 21)"));
      for (b in bs.vals()) List.add(out, creditTransfer(mt, a, b, messageId, env, o, mu, issues));
    };
    done<Message>(#pain001(List.toArray(out)), issues)
  };

  func encodePain001(mt : Text, docs : [ISO.CustomerCreditTransferInitiation], mu : Text -> ?Nat8, issues : List.List<Issue>) : Text {
    if (docs.size() == 0) { List.add(issues, issue(mt # "-EMPTY", "$", "nothing to write")); return "" };
    let d0 = docs[0];
    let sender = d0.debtorAgent.bicfi;
    let receiver = d0.creditorAgent.bicfi;
    func m(a : ISO.ActiveCurrencyAndAmount) : Text { a.currency # amountFin(a.minorUnits, mu2(mu, a.currency)) };
    if (mt == "MT103") {
      if (docs.size() != 1) List.add(issues, issue("MT103-ONE", "$", "an MT103 carries one transaction"));
      let date = switch (d0.requestedExecutionDate) { case (?d) d; case null { List.add(issues, issue("MT103-32A-DATE", "$.requestedExecutionDate", "an MT103 needs the value date")); "" } };
      let body = ":20:" # d0.messageId # "\n:23B:CRED\n:32A:" # yymmdd(date) # m(d0.instructedAmount) # "\n" # partyFin("50K", d0.debtor, d0.debtorAccount) # agentFin("52", d0.debtorAgent) # agentFin("57", d0.creditorAgent) # partyFin("59", d0.creditor, d0.creditorAccount) # remittanceFin(d0.remittanceInformation) # ":71A:SHA\n";
      return fin("103", sender, receiver, d0.requestedUetr, false, body)
    };
    let date = switch (d0.requestedExecutionDate) { case (?d) d; case null { List.add(issues, issue("MT101-30-DATE", "$.requestedExecutionDate", "an MT101 needs the requested execution date")); "" } };
    // the batch reference is the first transaction's: the compact record has no place for a batch id
    var body = ":20:" # d0.messageId # "\n:28D:1/1\n:30:" # yymmdd(date) # "\n";
    for (d in docs.vals()) {
      body #= ":21:" # d.endToEndId # "\n:32B:" # m(d.instructedAmount) # "\n" # partyFin("50K", d.debtor, d.debtorAccount) # agentFin("52", d.debtorAgent) # agentFin("57", d.creditorAgent) # partyFin("59", d.creditor, d.creditorAccount) # remittanceFin(d.remittanceInformation) # ":71A:SHA\n";
    };
    fin("101", sender, receiver, d0.requestedUetr, false, body)
  };

  // ─── MT104 ↔ pain.008 ───

  func decodePain008(env : Envelope, o : Options, mu : Text -> ?Nat8) : Result.Result<Message, [Issue]> {
    let mt = "MT104";
    let issues = List.empty<Issue>();
    let sender = switch (env.sender) { case (?s) s; case null "" };
    let receiver = switch (env.receiver) { case (?r) r; case null "" };
    let messageId = nonEmpty(value(env.fields, "20"), mt # "-20-REQUIRED", "$.20", "field 20 is required", issues);
    let (a, bs) = sequences(env.fields, "21");
    if (bs.size() == 0) List.add(issues, issue(mt # "-21-REQUIRED", "$.21", "an MT104 carries at least one collection (sequence B starts with field 21)"));
    let collectionDate = switch (value(a, "30")) { case (?v) { let d = date6(firstLine(v)); if (d == null) List.add(issues, issue(mt # "-30-DATE", "$.30", "field 30 is a YYMMDD requested collection date")); d }; case null null };
    let out = List.empty<ISO.DirectDebitMessage>();
    for (b in bs.vals()) {
      let fs = Array.concat(b, a);
      let m = money(nonEmpty(value(b, "32"), mt # "-32B-REQUIRED", "$.32B", "field 32B is required in every sequence B", issues), false, mu, "32B", mt, issues);
      if (field(fs, "50") == null) List.add(issues, issue(mt # "-50-REQUIRED", "$.50", "field 50a (the creditor) is required"));
      if (field(fs, "59") == null) List.add(issues, issue(mt # "-59-REQUIRED", "$.59", "field 59a (the debtor) is required"));
      let mandateId = nonEmpty(valueOpt(b, "21", ?"C"), mt # "-21C-REQUIRED", "$.21C", "field 21C (the mandate reference) is required in every sequence B", issues);
      let (creditor, creditorAccount) = partyOf(field(fs, "50"), "legacy creditor", m.currency, o.country);
      let (debtor, debtorAccount) = partyOf(field(fs, "59"), "legacy debtor", m.currency, o.country);
      List.add(out, {
        messageKind = "pain.008"; messageVersion = o.versions("pain.008"); businessApplicationHeader = null; messageId; creationDateTime = o.creationDateTime;
        settlementInstruction = null; requestedCollectionDate = collectionDate; initiatingParty = creditor; creditor; creditorAccount;
        creditorAgent = agentOr(fs, "52", sender, mt, issues); debtor; debtorAccount; debtorAgent = agentOr(fs, "57", receiver, mt, issues);
        paymentTypeInformation = ?{ serviceLevel = null; localInstrument = ?mt; categoryPurpose = null };
        instructedAmount = { currency = m.currency; minorUnits = m.minor }; endToEndId = nonEmpty(valueOpt(b, "21", null), mt # "-21-REQUIRED", "$.21", "field 21 starts every collection", issues);
        mandateId; mandateSignatureDate = null; sequenceType = "RCUR"; remittanceInformation = remittance(b); uetr = env.uetr; transactionCount = 1;
      });
    };
    done<Message>(#pain008(List.toArray(out)), issues)
  };

  func encodePain008(docs : [ISO.DirectDebitMessage], mu : Text -> ?Nat8, issues : List.List<Issue>) : Text {
    if (docs.size() == 0) { List.add(issues, issue("MT104-EMPTY", "$", "nothing to write")); return "" };
    let d0 = docs[0];
    var body = ":20:" # d0.messageId # "\n";
    switch (d0.requestedCollectionDate) { case (?d) body #= ":30:" # yymmdd(d) # "\n"; case null {} };
    for (d in docs.vals()) {
      if (d.messageId != d0.messageId) List.add(issues, issue("MT104-20-BATCH", "$.messageId", "every collection of one MT104 carries the same message id"));
      body #= ":21:" # d.endToEndId # "\n:21C:" # d.mandateId # "\n:23E:OTHR\n:32B:" # d.instructedAmount.currency # amountFin(d.instructedAmount.minorUnits, mu2(mu, d.instructedAmount.currency)) # "\n"
        # partyFin("50K", d.creditor, d.creditorAccount) # agentFin("52", d.creditorAgent) # agentFin("57", d.debtorAgent) # partyFin("59", d.debtor, d.debtorAccount) # remittanceFin(d.remittanceInformation);
    };
    fin("104", d0.creditorAgent.bicfi, d0.debtorAgent.bicfi, d0.uetr, false, body)
  };

  // ─── MT202 / MT202 COV ↔ pacs.009 (+ pacs.008) ───

  func fiTransfer(fs : [Field], env : Envelope, o : Options, mu : Text -> ?Nat8, issues : List.List<Issue>, cov : Bool, underlying : ?Text) : ISO.Pacs009FinancialInstitutionCreditTransfer {
    let mt = if (cov) "MT202COV" else "MT202";
    let sender = switch (env.sender) { case (?s) s; case null "" };
    let receiver = switch (env.receiver) { case (?r) r; case null "" };
    let messageId = nonEmpty(value(fs, "20"), mt # "-20-REQUIRED", "$.20", "field 20 is required", issues);
    let endToEndId = nonEmpty(value(fs, "21"), mt # "-21-REQUIRED", "$.21", "field 21 is required", issues);
    let m = money(nonEmpty(value(fs, "32"), mt # "-32A-REQUIRED", "$.32A", "field 32A is required", issues), true, mu, "32A", mt, issues);
    let inter = switch (field(fs, "56")) { case (?_) [agentOr(fs, "56", "", mt, issues)]; case null [] };
    {
      businessApplicationHeader = null; messageId; creationDateTime = o.creationDateTime;
      settlementInstruction = { settlementMethod = o.settlementMethod; clearingSystem = null }; uetr = env.uetr;
      instructionId = messageId; endToEndId; instructedAmount = { currency = m.currency; minorUnits = m.minor };
      debtorAgent = { bicfi = sender; name = null }; creditorAgent = agentOr(fs, "57", receiver, mt, issues);
      debtorInstitution = agentOr(fs, "52", sender, mt, issues); creditorInstitution = requiredAgent(fs, "58", mt, issues);
      routing = { chargeBearer = "SHAR"; charges = []; instructingAgent = { bicfi = sender; name = null }; instructedAgent = { bicfi = receiver; name = null }; intermediaryAgents = inter; settlementDate = m.date; fx = null; regulatoryReporting = [] };
      isCover = cov; underlyingPacs008MessageId = underlying; transactionCount = 1;
    }
  };

  func decodePacs009(env : Envelope, o : Options, mu : Text -> ?Nat8) : Result.Result<Message, [Issue]> {
    let issues = List.empty<Issue>();
    if (not env.cov) return done<Message>(#pacs009(fiTransfer(env.fields, env, o, mu, issues, false, null)), issues);
    // COV: sequence A is the cover, sequence B (from field 50a on) the underlying customer credit transfer
    var split = env.fields.size();
    var i = 0;
    for (f in env.fields.vals()) { if (f.tag == "50" and i < split) split := i; i += 1 };
    let a = Array.tabulate<Field>(split, func(k) { env.fields[k] });
    let b = Array.tabulate<Field>(env.fields.size() - split, func(k) { env.fields[split + k] });
    if (b.size() == 0) List.add(issues, issue("MT202COV-50-REQUIRED", "$.50", "an MT202 COV carries the underlying customer credit transfer (sequence B, from field 50a)"));
    let related = switch (value(a, "21")) { case (?v) trim(firstLine(v)); case null "" };
    let cover = fiTransfer(a, env, o, mu, issues, true, ?related);
    let sender = switch (env.sender) { case (?s) s; case null "" };
    let receiver = switch (env.receiver) { case (?r) r; case null "" };
    let amount = switch (value(b, "33")) { case (?v) { let m = money(v, false, mu, "33B", "MT202COV", issues); { currency = m.currency; minorUnits = m.minor } }; case null cover.instructedAmount };
    if (field(b, "59") == null) List.add(issues, issue("MT202COV-59-REQUIRED", "$.59", "the underlying transfer names its beneficiary (field 59a)"));
    let (debtor, debtorAccount) = partyOf(field(b, "50"), "legacy debtor", amount.currency, o.country);
    let (creditor, creditorAccount) = partyOf(field(b, "59"), "legacy creditor", amount.currency, o.country);
    let direct : ISO.Pacs008CreditTransfer = {
      businessApplicationHeader = null; messageId = related; creationDateTime = o.creationDateTime;
      settlementInstruction = { settlementMethod = "COVE"; clearingSystem = null }; paymentTypeInformation = null; uetr = env.uetr; endToEndId = related;
      instructedAmount = amount; debtor; debtorAccount; debtorAgent = agentOr(b, "52", sender, "MT202COV", issues);
      creditor; creditorAccount; creditorAgent = agentOr(b, "57", receiver, "MT202COV", issues); remittanceInformation = remittance(b); transactionCount = 1;
    };
    done<Message>(#cover({ directMessage = direct; coverMessage = cover; method = "COVER" }), issues)
  };

  func fiBody(d : ISO.Pacs009FinancialInstitutionCreditTransfer, mu : Text -> ?Nat8, issues : List.List<Issue>) : Text {
    let date = switch (d.routing.settlementDate) { case (?x) x; case null { List.add(issues, issue("MT202-32A-DATE", "$.routing.settlementDate", "an MT202 needs the settlement date")); "" } };
    if (d.creditorInstitution.bicfi == "") List.add(issues, issue("MT202-58A-REQUIRED", "$.creditorInstitution", "an MT202 names the beneficiary institution"));
    ":20:" # d.messageId # "\n:21:" # d.endToEndId # "\n:32A:" # yymmdd(date) # d.instructedAmount.currency # amountFin(d.instructedAmount.minorUnits, mu2(mu, d.instructedAmount.currency)) # "\n"
    # agentFin("52", d.debtorInstitution) # (if (d.routing.intermediaryAgents.size() > 0) agentFin("56", d.routing.intermediaryAgents[0]) else "") # agentFin("57", d.creditorAgent) # agentFin("58", d.creditorInstitution)
  };
  func encodePacs009(d : ISO.Pacs009FinancialInstitutionCreditTransfer, mu : Text -> ?Nat8, issues : List.List<Issue>) : Text {
    fin("202", d.debtorAgent.bicfi, d.routing.instructedAgent.bicfi, d.uetr, false, fiBody(d, mu, issues))
  };
  func encodeCover(c : ISO.CoverPayment, mu : Text -> ?Nat8, issues : List.List<Issue>) : Text {
    let d = c.directMessage;
    let body = fiBody(c.coverMessage, mu, issues) # partyFin("50K", d.debtor, d.debtorAccount) # agentFin("52", d.debtorAgent) # agentFin("57", d.creditorAgent) # partyFin("59", d.creditor, d.creditorAccount) # remittanceFin(d.remittanceInformation)
      # ":33B:" # d.instructedAmount.currency # amountFin(d.instructedAmount.minorUnits, mu2(mu, d.instructedAmount.currency)) # "\n";
    fin("202", c.coverMessage.debtorAgent.bicfi, c.coverMessage.routing.instructedAgent.bicfi, c.coverMessage.uetr, true, body)
  };

  // ─── MT900 / MT910 ↔ camt.054, MT940 / MT950 ↔ camt.053, MT942 ↔ camt.052 ───

  /// What follows a `/TOKEN/` in a narrative, on its line, up to the next `/`.
  func afterToken(t : Text, token : Text) : ?Text {
    let parts = Iter.toArray(Text.split(t, #text token));
    if (parts.size() < 2) return null;
    let rest = firstLine(parts[1]);
    ?Iter.toArray(Text.split(rest, #char '/'))[0]
  };
  func uetrOf(narrative : Text, fallbackIndex : Nat) : Text {
    switch (afterToken(narrative, "/UETR/")) { case (?u) { let v = trim(u); if (ISO.validUetr(v)) return v }; case null {} };
    var idx = Nat.toText(fallbackIndex);
    while (Text.size(idx) < 12) idx := "0" # idx;
    "00000000-0000-4000-8000-" # idx
  };
  func dateInt(iso : Text) : Int {
    var n = 0;
    for (c in iso.chars()) { if (Char.isDigit(c)) n := n * 10 + Nat32.toNat(Char.toNat32(c) - 48) };
    n
  };
  func intDate(v : Int) : Text {
    let t = Nat.toText(if (v < 0) 0 else Int.abs(v));
    if (Text.size(t) < 8) return "1970-01-01";
    slice(t, 0, 4) # "-" # slice(t, 4, 6) # "-" # slice(t, 6, 8)
  };
  func accountOf(v : Text) : (?Text, ?Text) {
    let id = trim(firstLine(v));
    let a = if (Text.startsWith(id, #char '/')) slice(id, 1, Text.size(id)) else id;
    if (ISO.validIban(a)) (?a, null) else (null, ?a)
  };
  func accountFin(iban : ?Text, other : ?Text) : Text { switch (iban, other) { case (?i, _) i; case (null, ?o) o; case (null, null) "" } };

  func decodeConfirmation(mt : Text, env : Envelope, o : Options, mu : Text -> ?Nat8) : Result.Result<Message, [Issue]> {
    let issues = List.empty<Issue>();
    let sender = switch (env.sender) { case (?s) s; case null "" };
    let ref = nonEmpty(value(env.fields, "20"), mt # "-20-REQUIRED", "$.20", "field 20 is required", issues);
    let account = nonEmpty(value(env.fields, "25"), mt # "-25-REQUIRED", "$.25", "field 25 (the account) is required", issues);
    let m = money(nonEmpty(value(env.fields, "32"), mt # "-32A-REQUIRED", "$.32A", "field 32A is required", issues), true, mu, "32A", mt, issues);
    let (iban, other) = accountOf(account);
    let narrative = switch (value(env.fields, "72")) { case (?v) v; case null "" };
    let counterparty = if (mt == "MT900") { switch (bicOf(field(env.fields, "52"))) { case (?b) b; case null sender } } else { switch (field(env.fields, "50")) { case (?f) partyOf(?f, "legacy ordering customer", m.currency, o.country).0.name; case null { switch (bicOf(field(env.fields, "52"))) { case (?b) b; case null sender } } } };
    let related = switch (value(env.fields, "21")) { case (?v) [ "/RELATED/" # trim(firstLine(v)) ]; case null [] };
    let rmt = Array.concat(related, Array.filter<Text>(lines(narrative), func(l) { not Text.startsWith(l, #text "/UETR/") }));
    let entry : ISO.StatementEntry = {
      entryId = ref; paymentId = 1; uetr = (switch (env.uetr) { case (?u) u; case null uetrOf(narrative, 1) }); accountIban = iban; accountOtherId = other;
      amount = { currency = m.currency; minorUnits = m.minor }; creditDebit = if (mt == "MT900") "DBIT" else "CRDT"; status = "booked";
      bookedAt = dateInt(switch (m.date) { case (?d) d; case null "1970-01-01" }); counterpartyName = counterparty; remittance = rmt;
    };
    done<Message>(#camt054(entry), issues)
  };
  func encodeConfirmation(e : ISO.StatementEntry, sender : Text, receiver : Text, mu : Text -> ?Nat8, issues : List.List<Issue>) : Text {
    let mt = if (e.creditDebit == "DBIT") "900" else "910";
    var related = "";
    let rest = List.empty<Text>();
    for (l in e.remittance.vals()) { if (Text.startsWith(l, #text "/RELATED/")) related := slice(l, 9, Text.size(l)) else List.add(rest, l) };
    if (related == "") { List.add(issues, issue("MT" # mt # "-21-REQUIRED", "$.remittance", "a confirmation names the related reference (/RELATED/ line of the remittance)")) };
    let body = ":20:" # e.entryId # "\n:21:" # related # "\n:25:" # accountFin(e.accountIban, e.accountOtherId) # "\n:32A:" # yymmdd(intDate(e.bookedAt)) # e.amount.currency # amountFin(e.amount.minorUnits, mu2(mu, e.amount.currency)) # "\n"
      # (if (mt == "900") ":52A:" # e.counterpartyName # "\n" else ":50K:" # e.counterpartyName # "\n")
      # ":72:" # Text.join(Iter.concat(List.values(rest), Iter.fromArray(if (Text.startsWith(e.uetr, #text "00000000-0000-4000-8000-")) [] else ["/UETR/" # e.uetr])), "\n") # "\n";
    fin(mt, sender, receiver, null, false, body)
  };

  /// A `61` line: value date (6), entry date (4, optional), D/C (with an optional R), amount, the transaction
  /// type (4), the owner's reference (//servicer reference).
  func entry61(v : Text, narrative : Text, index : Nat, iban : ?Text, other : ?Text, currency : Text, mu : Text -> ?Nat8, mt : Text, intraday : Bool, issues : List.List<Issue>) : ISO.StatementEntry {
    let s = firstLine(v);
    let a = Text.toArray(s);
    let valueDate = switch (date6(s)) { case (?d) d; case null { List.add(issues, issue(mt # "-61-DATE", "$.61", "a statement line starts with the YYMMDD value date")); "1970-01-01" } };
    var i = 6;
    while (i < a.size() and digit(a[i])) i += 1;   // the optional MMDD entry date
    if (i < a.size() and a[i] == 'R') i += 1;
    let credit = i < a.size() and (a[i] == 'C');
    if (i >= a.size() or not (a[i] == 'C' or a[i] == 'D')) List.add(issues, issue(mt # "-61-MARK", "$.61", "a statement line carries the C/D mark after its dates"));
    i += 1;
    if (i < a.size() and (a[i] >= 'A' and a[i] <= 'Z') and not (a[i] == 'N' or a[i] == 'F' or a[i] == 'S')) i += 1;   // a funds code letter
    let start = i;
    while (i < a.size() and (digit(a[i]) or a[i] == ',')) i += 1;
    let minor = switch (amountMinor(slice(s, start, i), mu2(mu, currency))) { case (?n) n; case null { List.add(issues, issue(mt # "-61-AMOUNT", "$.61", "a statement line's amount is a decimal with a comma")); 0 } };
    let rest = slice(s, i, Text.size(s));
    let reference = switch (afterToken(rest, "//")) { case (?r) trim(r); case null { let owner = slice(rest, 4, Text.size(rest)); if (owner == "") mt # "-" # Nat.toText(index) else trim(owner) } };
    let rmt = Array.filter<Text>(lines(narrative), func(l) { not Text.startsWith(l, #text "/UETR/") and not Text.startsWith(l, #text "/NAME/") });
    let counterparty = switch (afterToken(narrative, "/NAME/")) { case (?n) trim(n); case null "Legacy " # mt # " entry" };
    {
      entryId = reference; paymentId = index; uetr = uetrOf(narrative, index); accountIban = iban; accountOtherId = other;
      amount = { currency; minorUnits = minor }; creditDebit = if (credit) "CRDT" else "DBIT"; status = if (intraday) "intraday" else "booked";
      bookedAt = dateInt(valueDate); counterpartyName = counterparty; remittance = rmt;
    }
  };
  func line61(e : ISO.StatementEntry, mu : Text -> ?Nat8) : Text {
    ":61:" # yymmdd(intDate(e.bookedAt)) # (if (e.creditDebit == "CRDT") "C" else "D") # amountFin(e.amount.minorUnits, mu2(mu, e.amount.currency)) # "NTRFNONREF//" # e.entryId # "\n"
  };
  func line86(e : ISO.StatementEntry) : Text {
    let parts = List.empty<Text>();
    if (not Text.startsWith(e.uetr, #text "00000000-0000-4000-8000-")) List.add(parts, "/UETR/" # e.uetr);
    if (not Text.startsWith(e.counterpartyName, #text "Legacy ")) List.add(parts, "/NAME/" # e.counterpartyName);
    for (l in e.remittance.vals()) List.add(parts, l);
    if (List.size(parts) == 0) "" else ":86:" # Text.join(List.values(parts), "\n") # "\n"
  };

  func statementCurrency(fs : [Field], mt : Text, issues : List.List<Issue>) : Text {
    for (tag in ["60", "62", "34", "90"].vals()) {
      switch (value(fs, tag)) {
        case (?v) {
          let s = firstLine(v);
          // 60F/62F: D/C mark, YYMMDD, CCY; 34F: CCY[D/C]amount; 90D/90C: count, CCY, amount
          let ccy = if (tag == "60" or tag == "62") slice(s, 7, 10) else if (tag == "34") slice(s, 0, 3) else { var i = 0; let a = Text.toArray(s); while (i < a.size() and digit(a[i])) i += 1; slice(s, i, i + 3) };
          if (ISO.validCurrencyCode(ccy)) return ccy;
        };
        case null {};
      };
    };
    List.add(issues, issue(mt # "-CURRENCY", "$.60F", "the statement names its currency (60F/62F, or 34F/90D for an MT942)"));
    ""
  };

  func decodeStatement(mt : Text, env : Envelope, o : Options, mu : Text -> ?Nat8) : Result.Result<Message, [Issue]> {
    let issues = List.empty<Issue>();
    let fs = env.fields;
    let ref = nonEmpty(value(fs, "20"), mt # "-20-REQUIRED", "$.20", "field 20 is required", issues);
    let (iban, other) = accountOf(nonEmpty(value(fs, "25"), mt # "-25-REQUIRED", "$.25", "field 25 (the account) is required", issues));
    let currency = statementCurrency(fs, mt, issues);
    let entries = List.empty<ISO.StatementEntry>();
    var i = 0;
    while (i < fs.size()) {
      if (fs[i].tag == "61") {
        let narrative = if (i + 1 < fs.size() and fs[i + 1].tag == "86") fs[i + 1].value else "";
        List.add(entries, entry61(fs[i].value, narrative, List.size(entries) + 1, iban, other, currency, mu, mt, mt == "MT942", issues));
      };
      i += 1;
    };
    if (mt == "MT942") {
      // camt.052 in the official shape: the report over the account, the period from 13D
      let (from, to) = switch (value(fs, "13")) {
        case (?v) {
          let s = firstLine(v);
          switch (date6(s)) {
            case (?d) {
              let hh = slice(s, 6, 8); let mm = slice(s, 8, 10);
              let sign = slice(s, 10, 11); let oh = slice(s, 11, 13); let om = slice(s, 13, 15);
              let zone = if (oh == "00" and om == "00") "Z" else sign # oh # ":" # om;
              (?(d # "T00:00:00" # zone), ?(d # "T" # hh # ":" # mm # ":00" # zone))
            };
            case null { List.add(issues, issue(mt # "-13D-FORMAT", "$.13D", "field 13D is YYMMDDHHMM with a UTC offset")); (null, null) };
          }
        };
        case null (null, null);
      };
      let account = accountFin(iban, other);
      let report : Breadth.AccountReport = {
        messageId = ref; creationDateTime = o.creationDateTime; reportId = ref; originalQuery = null; accountId = account; currency = ?currency; fromDateTime = from; toDateTime = to; balances = [];
        entries = Array.map<ISO.StatementEntry, Breadth.Entry>(List.toArray(entries), func(e) {
          { reference = e.entryId; amount = { currency = e.amount.currency; minor = e.amount.minorUnits }; credit = e.creditDebit == "CRDT"; bookingDate = intDate(e.bookedAt); valueDate = intDate(e.bookedAt);
            uetr = (if (Text.startsWith(e.uetr, #text "00000000-0000-4000-8000-")) null else ?e.uetr); endToEndId = null; block = 0; counterparty = (if (Text.startsWith(e.counterpartyName, #text "Legacy ")) null else ?e.counterpartyName); remittance = e.remittance }
        });
      };
      return done<Message>(#camt052(report), issues)
    };
    if (List.size(entries) == 0) List.add(issues, issue(mt # "-61-REQUIRED", "$.61", "a statement carries at least one line"));
    done<Message>(#camt053(List.toArray(entries)), issues)
  };

  func encodeStatement(mt : Text, entries : [ISO.StatementEntry], reference : Text, account : Text, sender : Text, receiver : Text, mu : Text -> ?Nat8, issues : List.List<Issue>) : Text {
    if (entries.size() == 0) { List.add(issues, issue(mt # "-61-REQUIRED", "$.entries", "a statement carries at least one line")); return "" };
    let ccy = entries[0].amount.currency;
    let m = mu2(mu, ccy);
    var body = ":20:" # reference # "\n:25:" # account # "\n:28C:1/1\n";
    let date = yymmdd(intDate(entries[0].bookedAt));
    var closing : Int = 0;
    for (e in entries.vals()) { closing += (if (e.creditDebit == "CRDT") 1 else -1) * e.amount.minorUnits };
    body #= ":60F:C" # date # ccy # amountFin(0, m) # "\n";
    for (e in entries.vals()) { body #= line61(e, mu); if (mt == "940") body #= line86(e) };
    body #= ":62F:" # (if (closing < 0) "D" else "C") # date # ccy # amountFin(Int.abs(closing), m) # "\n";
    fin(mt, sender, receiver, null, false, body)
  };
  func encodeReport(r : Breadth.AccountReport, sender : Text, receiver : Text, mu : Text -> ?Nat8, issues : List.List<Issue>) : Text {
    let ccy = switch (r.currency) { case (?c) c; case null { if (r.entries.size() > 0) r.entries[0].amount.currency else { List.add(issues, issue("MT942-34F-CURRENCY", "$.currency", "an MT942 names the account's currency")); "" } } };
    let m = mu2(mu, ccy);
    var body = ":20:" # r.reportId # "\n:25:" # r.accountId # "\n:28C:1/1\n:34F:" # ccy # amountFin(0, m) # "\n";
    switch (r.toDateTime) {
      case (?t) {
        let zone = slice(t, 19, Text.size(t));   // after "YYYY-MM-DDTHH:MM:SS"
        let off = if (zone == "Z" or zone == "") "+0000" else slice(zone, 0, 3) # slice(zone, 4, 6);
        body #= ":13D:" # yymmdd(t) # slice(t, 11, 13) # slice(t, 14, 16) # off # "\n";
      };
      case null {};
    };
    var debits = 0; var credits = 0; var dsum = 0; var csum = 0;
    for (e in r.entries.vals()) {
      let se : ISO.StatementEntry = { entryId = e.reference; paymentId = 0; uetr = (switch (e.uetr) { case (?u) u; case null "00000000-0000-4000-8000-000000000000" }); accountIban = null; accountOtherId = null; amount = { currency = e.amount.currency; minorUnits = e.amount.minor }; creditDebit = if (e.credit) "CRDT" else "DBIT"; status = "intraday"; bookedAt = dateInt(e.valueDate); counterpartyName = (switch (e.counterparty) { case (?c) c; case null "Legacy MT942 entry" }); remittance = e.remittance };
      body #= line61(se, mu) # line86(se);
      if (e.credit) { credits += 1; csum += e.amount.minor } else { debits += 1; dsum += e.amount.minor };
    };
    body #= ":90D:" # Nat.toText(debits) # ccy # amountFin(dsum, m) # "\n:90C:" # Nat.toText(credits) # ccy # amountFin(csum, m) # "\n";
    fin("942", sender, receiver, null, false, body)
  };

  // ─── MT192 / MT196 / MT199 ↔ camt.056 / camt.029 / camt.110 ───

  func decodeInvestigation(mt : Text, env : Envelope, o : Options) : Result.Result<Message, [Issue]> {
    let issues = List.empty<Issue>();
    let kind = switch (mt) { case ("MT192") "camt.056"; case ("MT196") "camt.029"; case (_) "camt.110" };
    let ref = nonEmpty(value(env.fields, "20"), mt # "-20-REQUIRED", "$.20", "field 20 is required", issues);
    let related = nonEmpty(value(env.fields, "21"), mt # "-21-REQUIRED", "$.21", "field 21 (the related reference) is required", issues);
    let narrativeTag = if (mt == "MT196") "76" else "79";
    let narrative = switch (value(env.fields, narrativeTag)) { case (?v) v; case null { List.add(issues, issue(mt # "-" # narrativeTag # "-REQUIRED", "$." # narrativeTag, "field " # narrativeTag # " (the narrative) is required")); "" } };
    var reason = "NARR";
    var action : ?Text = null;
    var uetr : ?Text = env.uetr;
    let info = List.empty<Text>();
    for (l in lines(narrative).vals()) {
      if (Text.startsWith(l, #text "/UETR/")) { let u = slice(l, 6, Text.size(l)); if (ISO.validUetr(u)) uetr := ?u }
      else if (Text.startsWith(l, #text "/ACTION/")) action := ?slice(l, 8, Text.size(l))
      else if (Text.startsWith(l, #char '/') and Text.size(l) > 1 and reason == "NARR") { let code = Iter.toArray(Text.split(slice(l, 1, Text.size(l)), #char '/'))[0]; reason := code; let rest = slice(l, 2 + Text.size(code), Text.size(l)); if (rest != "") List.add(info, rest) }
      else List.add(info, l);
    };
    done<Message>(#investigation({ messageKind = kind; messageVersion = o.versions(kind); messageId = ref; creationDateTime = o.creationDateTime; assignmentId = ref; originalMessageId = related; originalUetr = uetr; reasonCode = reason; requestedAction = action; additionalInfo = List.toArray(info) }), issues)
  };
  func encodeInvestigation(d : ISO.InvestigationMessage, sender : Text, receiver : Text, issues : List.List<Issue>) : Text {
    let (mt, tag) = switch (d.messageKind) { case ("camt.056") ("192", "79"); case ("camt.029") ("196", "76"); case ("camt.110") ("199", "79"); case (k) { List.add(issues, issue("MT-KIND", "$.messageKind", k # " has no MT counterpart in this bridge (camt.056 → MT192, camt.029 → MT196, camt.110 → MT199)")); ("199", "79") } };
    let parts = List.empty<Text>();
    List.add(parts, "/" # d.reasonCode # "/");
    switch (d.requestedAction) { case (?a) List.add(parts, "/ACTION/" # a); case null {} };
    switch (d.originalUetr) { case (?u) List.add(parts, "/UETR/" # u); case null {} };
    for (l in d.additionalInfo.vals()) List.add(parts, l);
    let date = yymmdd(d.creationDateTime);
    let body = ":20:" # d.messageId # "\n:21:" # d.originalMessageId # "\n" # (if (mt == "192") ":11S:103\n" # date # "\n" else if (mt == "196") ":11R:192\n" # date # "\n" else "") # ":" # tag # ":" # Text.join(List.values(parts), "\n") # "\n";
    fin(mt, sender, receiver, null, false, body)
  };

  // ─── the bridge ───

  /// The message type of a FIN text: block 2's, with the COV flag; or the caller's hint for block-4-only text.
  public func typeOf(env : Envelope, hint : ?Text) : ?Text {
    switch (env.mtType) {
      case (?t) ?("MT" # t # (if (t == "202" and env.cov) "COV" else ""));
      case null hint;
    }
  };

  public func decode(payload : Blob, hint : ?Text, o : Options, minorUnitsOf : Text -> ?Nat8) : Decoded {
    let text = switch (Text.decodeUtf8(payload)) { case (?t) t; case null return { mtType = "unknown"; iso = ""; message = #err([issue("MT-UTF8", "$payload", "an MT message is UTF-8 text")]) } };
    let env = parse(text);
    let mt = switch (typeOf(env, hint)) { case (?t) t; case null return { mtType = "unknown"; iso = ""; message = #err([issue("MT-TYPE", "{2:}", "block 2 names the message type (or the caller passes a hint for block-4-only text)")]) } };
    let iso = switch (mapping(mt)) { case (?m) m.iso; case null return { mtType = mt; iso = ""; message = #err([issue("MT-UNSUPPORTED", "{2:}", mt # " is not one of the bridge's twelve types")]) } };
    let message = switch (mt) {
      case ("MT101" or "MT103") decodePain001(mt, env, o, minorUnitsOf);
      case ("MT104") decodePain008(env, o, minorUnitsOf);
      case ("MT202" or "MT202COV") decodePacs009(env, o, minorUnitsOf);
      case ("MT900" or "MT910") decodeConfirmation(mt, env, o, minorUnitsOf);
      case ("MT940" or "MT950" or "MT942") decodeStatement(mt, env, o, minorUnitsOf);
      case (_) decodeInvestigation(mt, env, o);
    };
    { mtType = mt; iso; message }
  };

  /// Where a record does not name the two institutions of the envelope (statements, confirmations,
  /// investigations), the caller does.
  public type Party = { sender : Text; receiver : Text };

  public func encode(m : Message, mt : Text, parties : Party, minorUnitsOf : Text -> ?Nat8) : Result.Result<Text, [Issue]> {
    let issues = List.empty<Issue>();
    let text = switch (m) {
      case (#pain001(docs)) encodePain001(if (mt == "MT103") "MT103" else "MT101", docs, minorUnitsOf, issues);
      case (#pain008(docs)) encodePain008(docs, minorUnitsOf, issues);
      case (#pacs009(d)) encodePacs009(d, minorUnitsOf, issues);
      case (#cover(c)) encodeCover(c, minorUnitsOf, issues);
      case (#camt054(e)) encodeConfirmation(e, parties.sender, parties.receiver, minorUnitsOf, issues);
      case (#camt053(es)) {
        // the compact camt.053 record has no statement id: field 20 is written as the first entry's reference
        let account = if (es.size() > 0) accountFin(es[0].accountIban, es[0].accountOtherId) else "";
        let reference = if (es.size() > 0) es[0].entryId else "";
        encodeStatement(if (mt == "MT950") "950" else "940", es, reference, account, parties.sender, parties.receiver, minorUnitsOf, issues)
      };
      case (#camt052(r)) encodeReport(r, parties.sender, parties.receiver, minorUnitsOf, issues);
      case (#investigation(d)) encodeInvestigation(d, parties.sender, parties.receiver, issues);
    };
    if (List.size(issues) > 0) #err(List.toArray(issues)) else #ok(text)
  };

  /// Structural equality of two readings (records are shared types, compared structurally).
  public func equalMessage(a : Message, b : Message) : Bool { a == b };
}
