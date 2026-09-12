/// LegacyMT.mo -- verifier-oriented legacy MT compatibility mappers.
///
/// This module intentionally supports a narrow MT103 subset used for education
/// and connector fixtures. Full SWIFT MT coverage requires licensed rulebooks
/// and far more option handling; unsupported branches should dead-letter with
/// stable rule IDs instead of being silently guessed.

import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Text "mo:core/Text";
import ISO "ISO20022";

module {

  public type Mt103Field = {
    tag : Text;
    option : ?Text;
    value : Text;
  };

  public type Mt103Decode = {
    #ok : ISO.CustomerCreditTransferInitiation;
    #err : [ISO.ValidationIssue];
  };

  public type StatementDecode = {
    #ok : [ISO.StatementEntry];
    #err : [ISO.ValidationIssue];
  };

  public type PaymentFileDecode = {
    #ok : [ISO.CustomerCreditTransferInitiation];
    #err : [ISO.ValidationIssue];
  };

  type FieldHeader = {
    tag : Text;
    option : ?Text;
    value : Text;
  };

  type ReqField = {
    field : ?Mt103Field;
    issues : [ISO.ValidationIssue];
  };

  type ReqBic = {
    bic : Text;
    issues : [ISO.ValidationIssue];
  };

  type ReqAmount = {
    valueDate : Text;
    currency : Text;
    minorUnits : Nat;
    issues : [ISO.ValidationIssue];
  };

  type PartyAccount = {
    party : ISO.PartyIdentification;
    account : ISO.CashAccount;
  };

  type ParsedStatementEntry = {
    entry : ISO.StatementEntry;
    issues : [ISO.ValidationIssue];
  };

  public func decodeMt103(payload : Blob, defaultCountry : Text) : Mt103Decode {
    switch (Text.decodeUtf8(payload)) {
      case null {
        #err([ISO.publicIssue("schema", "MT103-UTF8", "$payload", "MT103 payload must be valid UTF-8")]);
      };
      case (?text) {
        let fields = parseMt103Fields(text);
        var issues : [ISO.ValidationIssue] = [];

        let f20 = requiredField(fields, "20", "$.20", "MT103-20-REQUIRED", issues);
        issues := f20.issues;
        let f32 = requiredField(fields, "32", "$.32A", "MT103-32A-REQUIRED", issues);
        issues := f32.issues;
        let f50 = requiredField(fields, "50", "$.50K", "MT103-50-REQUIRED", issues);
        issues := f50.issues;
        let f52 = requiredField(fields, "52", "$.52A", "MT103-52A-REQUIRED", issues);
        issues := f52.issues;
        let f57 = requiredField(fields, "57", "$.57A", "MT103-57A-REQUIRED", issues);
        issues := f57.issues;
        let f59 = requiredField(fields, "59", "$.59", "MT103-59-REQUIRED", issues);
        issues := f59.issues;

        let amount = parse32A(fieldValue(f32.field), issues);
        issues := amount.issues;
        let debtorBic = bicFromField(f52.field, "$.52A", "MT103-52A-BIC", issues);
        issues := debtorBic.issues;
        let creditorBic = bicFromField(f57.field, "$.57A", "MT103-57A-BIC", issues);
        issues := creditorBic.issues;

        if (issues.size() > 0) return #err(issues);

        let debtorCountry = countryFromBic(debtorBic.bic, defaultCountry);
        let creditorCountry = countryFromBic(creditorBic.bic, defaultCountry);
        let debtor = partyAccountFromField(f50.field, "legacy debtor", amount.currency, debtorCountry);
        let creditor = partyAccountFromField(f59.field, "legacy creditor", amount.currency, creditorCountry);
        let messageId = fieldValue(f20.field);
        let remittance = remittanceFromFields(fields);

        #ok({
          messageId;
          creationDateTime = amount.valueDate # "T00:00:00Z";
          requestedExecutionDate = ?amount.valueDate;
          initiatingParty = debtor.party;
          debtor = debtor.party;
          debtorAccount = debtor.account;
          debtorAgent = { bicfi = debtorBic.bic; name = null };
          creditor = creditor.party;
          creditorAccount = creditor.account;
          creditorAgent = { bicfi = creditorBic.bic; name = null };
          paymentTypeInformation = ?{
            serviceLevel = ?"NURG";
            localInstrument = ?"MT103";
            categoryPurpose = ?"CORT";
          };
          instructedAmount = { currency = amount.currency; minorUnits = amount.minorUnits };
          endToEndId = messageId;
          remittanceInformation = remittance;
          requestedUetr = null;
        });
      };
    };
  };

  public func decodeMt940(payload : Blob, defaultCurrency : Text) : StatementDecode {
    decodeMtStatement(payload, "MT940", defaultCurrency);
  };

  public func decodeMt942(payload : Blob, defaultCurrency : Text) : StatementDecode {
    decodeMtStatement(payload, "MT942", defaultCurrency);
  };

  public func decodeCsvPayments(payload : Blob, defaultCountry : Text) : PaymentFileDecode {
    switch (Text.decodeUtf8(payload)) {
      case null {
        #err([ISO.publicIssue("schema", "CSV-UTF8", "$payload", "CSV payment file must be valid UTF-8")]);
      };
      case (?text) {
        var issues : [ISO.ValidationIssue] = [];
        var docs : [ISO.CustomerCreditTransferInitiation] = [];
        var row : Nat = 0;
        var sawHeader = false;
        for (rawLine in Text.split(normalizeLines(text), #char '\n')) {
          let line = trim(rawLine);
          if (line != "" and not Text.startsWith(line, #text "#")) {
            if (not sawHeader) {
              sawHeader := true;
            } else {
              row += 1;
              let cells = splitCsvLine(line);
              if (cells.size() < 11) {
                issues := add(issues, ISO.publicIssue("schema", "CSV-COLUMN-COUNT", "$.rows[" # Nat.toText(row) # "]", "CSV payment row must contain 11 columns"));
              } else {
                switch (parseNatStrict(cells[3])) {
                  case (?minor) {
                    docs := Array.concat<ISO.CustomerCreditTransferInitiation>(docs, [
                      paymentFromParts(
                        "CSV",
                        cells[0],
                        cells[1],
                        cells[2],
                        minor,
                        cells[4],
                        cells[5],
                        cells[6],
                        cells[7],
                        cells[8],
                        cells[9],
                        cells[10],
                        defaultCountry,
                      )
                    ]);
                  };
                  case null {
                    issues := add(issues, ISO.publicIssue("schema", "CSV-AMOUNT-MINOR", "$.rows[" # Nat.toText(row) # "].amountMinor", "CSV amountMinor must be an unsigned integer"));
                  };
                };
              };
            };
          };
        };
        if (not sawHeader) {
          issues := add(issues, ISO.publicIssue("schema", "CSV-HEADER-REQUIRED", "$.header", "CSV payment file must include a header row"));
        };
        if (docs.size() == 0 and issues.size() == 0) {
          issues := add(issues, ISO.publicIssue("schema", "CSV-ROW-REQUIRED", "$.rows", "CSV payment file must include at least one payment row"));
        };
        if (issues.size() > 0) #err(issues) else #ok(docs);
      };
    };
  };

  public func decodeFixedWidthPayments(payload : Blob, defaultCountry : Text) : PaymentFileDecode {
    switch (Text.decodeUtf8(payload)) {
      case null {
        #err([ISO.publicIssue("schema", "FIXED-UTF8", "$payload", "fixed-width payment file must be valid UTF-8")]);
      };
      case (?text) {
        var issues : [ISO.ValidationIssue] = [];
        var docs : [ISO.CustomerCreditTransferInitiation] = [];
        var row : Nat = 0;
        for (rawLine in Text.split(normalizeLines(text), #char '\n')) {
          let line = rawLine;
          let trimmed = trim(line);
          if (trimmed != "" and not Text.startsWith(trimmed, #text "#")) {
            row += 1;
            let bs = bytes(line);
            if (bs.size() < 140) {
              issues := add(issues, ISO.publicIssue("schema", "FIXED-LINE-LENGTH", "$.rows[" # Nat.toText(row) # "]", "fixed-width payment row must be at least 140 bytes"));
            } else {
              let messageId = trim(textSlice(bs, 0, 35));
              let currency = trim(textSlice(bs, 35, 38));
              let amountText = trim(textSlice(bs, 38, 50));
              let debtorBic = trim(textSlice(bs, 50, 61));
              let creditorBic = trim(textSlice(bs, 61, 72));
              let debtorAccount = trim(textSlice(bs, 72, 106));
              let creditorAccount = trim(textSlice(bs, 106, 140));
              switch (parseNatStrict(amountText)) {
                case (?minor) {
                  docs := Array.concat<ISO.CustomerCreditTransferInitiation>(docs, [
                    paymentFromParts(
                      "FIXED",
                      messageId,
                      "1970-01-01",
                      currency,
                      minor,
                      "Fixed-width debtor",
                      debtorAccount,
                      debtorBic,
                      "Fixed-width creditor",
                      creditorAccount,
                      creditorBic,
                      "fixed-width row " # Nat.toText(row),
                      defaultCountry,
                    )
                  ]);
                };
                case null {
                  issues := add(issues, ISO.publicIssue("schema", "FIXED-AMOUNT-MINOR", "$.rows[" # Nat.toText(row) # "].amountMinor", "fixed-width amountMinor must be an unsigned integer"));
                };
              };
            };
          };
        };
        if (docs.size() == 0 and issues.size() == 0) {
          issues := add(issues, ISO.publicIssue("schema", "FIXED-ROW-REQUIRED", "$.rows", "fixed-width payment file must include at least one payment row"));
        };
        if (issues.size() > 0) #err(issues) else #ok(docs);
      };
    };
  };

  public func parseMt103Fields(text : Text) : [Mt103Field] {
    let normalized = normalizeLines(text);
    var fields : [Mt103Field] = [];
    var hasCurrent = false;
    var currentTag = "";
    var currentOption : ?Text = null;
    var currentValue = "";

    for (rawLine in Text.split(normalized, #char '\n')) {
      let line = trim(rawLine);
      if (line != "" and line != "-}") {
        switch (parseFieldHeader(line)) {
          case (?h) {
            if (hasCurrent) {
              fields := Array.concat<Mt103Field>(fields, [{ tag = currentTag; option = currentOption; value = trim(currentValue) }]);
            };
            hasCurrent := true;
            currentTag := h.tag;
            currentOption := h.option;
            currentValue := h.value;
          };
          case null {
            if (hasCurrent) currentValue #= "\n" # line;
          };
        };
      };
    };
    if (hasCurrent) {
      fields := Array.concat<Mt103Field>(fields, [{ tag = currentTag; option = currentOption; value = trim(currentValue) }]);
    };
    fields;
  };

  func decodeMtStatement(payload : Blob, kind : Text, defaultCurrency : Text) : StatementDecode {
    switch (Text.decodeUtf8(payload)) {
      case null {
        #err([ISO.publicIssue("schema", kind # "-UTF8", "$payload", kind # " payload must be valid UTF-8")]);
      };
      case (?text) {
        let fields = parseMt103Fields(text);
        var issues : [ISO.ValidationIssue] = [];
        let f20 = requiredLegacyField(fields, "20", "$.20", kind # "-20-REQUIRED", kind # " transaction reference is required", issues);
        issues := f20.issues;
        let f25 = requiredLegacyField(fields, "25", "$.25", kind # "-25-REQUIRED", kind # " account identification is required", issues);
        issues := f25.issues;
        let accountId = trim(fieldValue(f25.field));
        let currency = statementCurrency(fields, defaultCurrency);
        var entries : [ISO.StatementEntry] = [];
        var i = 0;
        while (i < fields.size()) {
          if (fields[i].tag == "61") {
            let remittanceField = if (i + 1 < fields.size() and fields[i + 1].tag == "86") fields[i + 1].value else "";
            let parsed = statementEntryFrom61(kind, entries.size(), accountId, currency, fields[i].value, remittanceField, issues);
            issues := parsed.issues;
            entries := Array.concat<ISO.StatementEntry>(entries, [parsed.entry]);
          };
          i += 1;
        };
        if (entries.size() == 0) {
          issues := add(issues, ISO.publicIssue("schema", kind # "-61-REQUIRED", "$.61", kind # " must contain at least one statement line"));
        };
        if (issues.size() > 0) #err(issues) else #ok(entries);
      };
    };
  };

  func statementEntryFrom61(
    kind : Text,
    index : Nat,
    accountId : Text,
    currency : Text,
    value : Text,
    remittanceField : Text,
    issues0 : [ISO.ValidationIssue],
  ) : ParsedStatementEntry {
    var issues = issues0;
    let line = firstLine(value);
    let bs = bytes(line);
    var directionIndex : ?Nat = null;
    var i = 6;
    while (i < bs.size()) {
      if (bs[i] == 67 or bs[i] == 68) {
        directionIndex := ?i;
        i := bs.size();
      } else {
        i += 1;
      };
    };
    switch (directionIndex) {
      case null {
        issues := add(issues, ISO.publicIssue("schema", kind # "-61-FORMAT", "$.61", kind # " statement line must contain value date, credit/debit mark, and amount"));
        {
          entry = emptyStatementEntry(kind, index, accountId, currency);
          issues;
        };
      };
      case (?dix) {
        let valueDate = if (bs.size() >= 6) yyMmDdToDate(textSlice(bs, 0, 6)) else "1970-01-01";
        let creditDebit = if (bs[dix] == 67) "CRDT" else "DBIT";
        var amountEnd = dix + 1;
        while (amountEnd < bs.size() and isAmountByte(bs[amountEnd])) amountEnd += 1;
        let amountText = textSlice(bs, dix + 1, amountEnd);
        let minor = switch (parseMinorUnits(amountText)) {
          case (?n) n;
          case null {
            issues := add(issues, ISO.publicIssue("schema", kind # "-61-AMOUNT", "$.61.amount", kind # " statement amount must use decimal format with comma or dot separator"));
            0;
          };
        };
        let details = textSlice(bs, amountEnd, bs.size());
        let entryId = statementReference(kind, index, details);
        let remittance = statementRemittance(details, remittanceField);
        {
          entry = {
            entryId;
            paymentId = index + 1;
            uetr = statementUetr(remittanceField, index);
            accountIban = if (ISO.validIban(accountId)) ?accountId else null;
            accountOtherId = if (ISO.validIban(accountId)) null else ?accountId;
            amount = { currency; minorUnits = minor };
            creditDebit;
            status = if (kind == "MT942") "intraday" else "booked";
            bookedAt = dateInt(valueDate);
            counterpartyName = "Legacy " # kind # " entry";
            remittance;
          };
          issues;
        };
      };
    };
  };

  func emptyStatementEntry(kind : Text, index : Nat, accountId : Text, currency : Text) : ISO.StatementEntry {
    {
      entryId = kind # "-" # Nat.toText(index + 1);
      paymentId = index + 1;
      uetr = statementUetr("", index);
      accountIban = if (ISO.validIban(accountId)) ?accountId else null;
      accountOtherId = if (ISO.validIban(accountId)) null else ?accountId;
      amount = { currency; minorUnits = 0 };
      creditDebit = "CRDT";
      status = "parse-error";
      bookedAt = 0;
      counterpartyName = "Legacy " # kind # " entry";
      remittance = [];
    };
  };

  func statementCurrency(fields : [Mt103Field], fallback : Text) : Text {
    for (tag in ["60", "62"].vals()) {
      switch (fieldByTag(fields, tag)) {
        case (?f) {
          let first = firstLine(f.value);
          let bs = bytes(first);
          if (bs.size() >= 10) {
            let ccy = textSlice(bs, 7, 10);
            if (ISO.validCurrencyCode(ccy)) return ccy;
          };
        };
        case null {};
      };
    };
    fallback;
  };

  func statementReference(kind : Text, index : Nat, details : Text) : Text {
    switch (textAfter(details, "//")) {
      case (?ref) {
        let r = firstToken(ref);
        if (r != "") return r;
      };
      case null {};
    };
    kind # "-" # Nat.toText(index + 1);
  };

  func statementRemittance(details : Text, field86 : Text) : [Text] {
    var lines : [Text] = [];
    switch (textAfter(field86, "/REMI/")) {
      case (?v) {
        let rem = firstSlashToken(v);
        if (rem != "") lines := Array.concat<Text>(lines, [rem]);
      };
      case null {};
    };
    if (lines.size() == 0) {
      for (line in nonEmptyLines(field86).vals()) {
        lines := Array.concat<Text>(lines, [line]);
      };
    };
    if (lines.size() == 0 and details != "") {
      lines := [details];
    };
    lines;
  };

  func statementUetr(field86 : Text, index : Nat) : Text {
    switch (textAfter(field86, "/UETR/")) {
      case (?v) {
        let u = firstSlashToken(v);
        if (ISO.validUetr(u)) return u;
      };
      case null {};
    };
    "00000000-0000-4000-8000-" # padNat(index + 1, 12);
  };

  func splitCsvLine(line : Text) : [Text] {
    var cells : [Text] = [];
    for (part in Text.split(line, #char ',')) {
      cells := Array.concat<Text>(cells, [trim(part)]);
    };
    cells;
  };

  func paymentFromParts(
    localInstrument : Text,
    messageId : Text,
    executionDate : Text,
    currency : Text,
    minorUnits : Nat,
    debtorName : Text,
    debtorAccountText : Text,
    debtorBic : Text,
    creditorName : Text,
    creditorAccountText : Text,
    creditorBic : Text,
    remittance : Text,
    defaultCountry : Text,
  ) : ISO.CustomerCreditTransferInitiation {
    let debtorCountry = countryFromBic(debtorBic, defaultCountry);
    let creditorCountry = countryFromBic(creditorBic, defaultCountry);
    {
      messageId;
      creationDateTime = executionDate # "T00:00:00Z";
      requestedExecutionDate = ?executionDate;
      initiatingParty = legacyParty(debtorName, debtorCountry);
      debtor = legacyParty(debtorName, debtorCountry);
      debtorAccount = legacyAccount(debtorAccountText, currency);
      debtorAgent = { bicfi = debtorBic; name = null };
      creditor = legacyParty(creditorName, creditorCountry);
      creditorAccount = legacyAccount(creditorAccountText, currency);
      creditorAgent = { bicfi = creditorBic; name = null };
      paymentTypeInformation = ?{
        serviceLevel = ?"NURG";
        localInstrument = ?localInstrument;
        categoryPurpose = ?"CORT";
      };
      instructedAmount = { currency; minorUnits };
      endToEndId = messageId;
      remittanceInformation = { unstructured = if (remittance == "") [] else [remittance]; structuredCreditorReference = null };
      requestedUetr = null;
    };
  };

  func legacyParty(name : Text, country : Text) : ISO.PartyIdentification {
    {
      name;
      postalAddress = ?{
        country;
        townName = "Legacy";
        addressLine = [];
        postalCode = null;
      };
      lei = null;
    };
  };

  func legacyAccount(value : Text, currency : Text) : ISO.CashAccount {
    if (ISO.validIban(value)) {
      { iban = ?value; otherId = null; currency = ?currency };
    } else {
      { iban = null; otherId = ?value; currency = ?currency };
    };
  };

  func parseFieldHeader(line : Text) : ?FieldHeader {
    let bs = bytes(line);
    if (bs.size() < 4 or bs[0] != 58) return null;
    var i = 1;
    while (i < bs.size() and bs[i] != 58) i += 1;
    if (i >= bs.size() or i == 1) return null;
    let rawTag = textSlice(bs, 1, i);
    let tagInfo = splitTag(rawTag);
    ?{
      tag = tagInfo.0;
      option = tagInfo.1;
      value = textSlice(bs, i + 1, bs.size());
    };
  };

  func splitTag(rawTag : Text) : (Text, ?Text) {
    let bs = bytes(rawTag);
    if (bs.size() >= 3 and isDigit(bs[0]) and isDigit(bs[1]) and isUpper(bs[2])) {
      (textSlice(bs, 0, 2), ?textSlice(bs, 2, bs.size()));
    } else {
      (rawTag, null);
    };
  };

  func requiredField(fields : [Mt103Field], tag : Text, path : Text, ruleId : Text, issues0 : [ISO.ValidationIssue]) : ReqField {
    switch (fieldByTag(fields, tag)) {
      case (?f) { { field = ?f; issues = issues0 } };
      case null { { field = null; issues = add(issues0, ISO.publicIssue("schema", ruleId, path, "required MT103 field is missing from the supported subset")) } };
    };
  };

  func requiredLegacyField(fields : [Mt103Field], tag : Text, path : Text, ruleId : Text, message : Text, issues0 : [ISO.ValidationIssue]) : ReqField {
    switch (fieldByTag(fields, tag)) {
      case (?f) { { field = ?f; issues = issues0 } };
      case null { { field = null; issues = add(issues0, ISO.publicIssue("schema", ruleId, path, message)) } };
    };
  };

  func parse32A(value : Text, issues0 : [ISO.ValidationIssue]) : ReqAmount {
    var issues = issues0;
    let first = firstLine(value);
    let bs = bytes(first);
    if (bs.size() < 10) {
      return {
        valueDate = "";
        currency = "";
        minorUnits = 0;
        issues = add(issues, ISO.publicIssue("schema", "MT103-32A-FORMAT", "$.32A", "field 32A must contain YYMMDD currency and amount"));
      };
    };
    if (not (isDigit(bs[0]) and isDigit(bs[1]) and isDigit(bs[2]) and isDigit(bs[3]) and isDigit(bs[4]) and isDigit(bs[5]))) {
      issues := add(issues, ISO.publicIssue("schema", "MT103-32A-DATE", "$.32A.date", "field 32A value date must use YYMMDD digits"));
    };
    let currency = textSlice(bs, 6, 9);
    if (not ISO.validCurrencyCode(currency)) {
      issues := add(issues, ISO.publicIssue("schema", "MT103-32A-CURRENCY", "$.32A.currency", "field 32A currency must be ISO 4217 uppercase alpha-3"));
    };
    let amountText = textSlice(bs, 9, bs.size());
    let minor = switch (parseMinorUnits(amountText)) {
      case (?n) n;
      case null {
        issues := add(issues, ISO.publicIssue("schema", "MT103-32A-AMOUNT", "$.32A.amount", "field 32A amount must use decimal format with comma or dot separator"));
        0;
      };
    };
    {
      valueDate = "20" # textSlice(bs, 0, 2) # "-" # textSlice(bs, 2, 4) # "-" # textSlice(bs, 4, 6);
      currency;
      minorUnits = minor;
      issues;
    };
  };

  func bicFromField(field : ?Mt103Field, path : Text, ruleId : Text, issues0 : [ISO.ValidationIssue]) : ReqBic {
    switch (field) {
      case null { { bic = ""; issues = issues0 } };
      case (?f) {
        switch (firstValidBic(f.value)) {
          case (?bic) { { bic; issues = issues0 } };
          case null {
            let fallback = firstLine(f.value);
            { bic = fallback; issues = add(issues0, ISO.publicIssue("schema", ruleId, path, "field must contain an 8 or 11 character BICFI in the supported subset")) };
          };
        };
      };
    };
  };

  func partyAccountFromField(field : ?Mt103Field, fallbackName : Text, currency : Text, country : Text) : PartyAccount {
    let option = switch (field) { case (?f) f.option; case null null };
    let value = fieldValue(field);
    let lines = partyLines(value, option);
    var account : ?Text = null;
    var name = fallbackName;
    var start = 0;
    if (lines.size() > 0 and startsWithSlash(lines[0])) {
      account := ?dropFirstByte(lines[0]);
      start := 1;
    };
    if (start < lines.size()) {
      name := lines[start];
      start += 1;
    };
    var addressLines : [Text] = [];
    while (start < lines.size()) {
      addressLines := Array.concat<Text>(addressLines, [lines[start]]);
      start += 1;
    };
    let postalAddress = if (addressLines.size() == 0) {
      null;
    } else {
      ?{
        country;
        townName = "Legacy";
        addressLine = addressLines;
        postalCode = null;
      };
    };
    let cashAccount = switch (account) {
      case (?a) {
        if (ISO.validIban(a)) {
          { iban = ?a; otherId = null; currency = ?currency };
        } else {
          { iban = null; otherId = ?a; currency = ?currency };
        };
      };
      case null { { iban = null; otherId = null; currency = ?currency } };
    };
    { party = { name; postalAddress; lei = null }; account = cashAccount };
  };

  func remittanceFromFields(fields : [Mt103Field]) : ISO.RemittanceInformation {
    var lines : [Text] = [];
    switch (optionalFieldValue(fields, "70")) {
      case (?v) {
        for (line in nonEmptyLines(v).vals()) {
          lines := Array.concat<Text>(lines, [line]);
        };
      };
      case null {};
    };
    switch (optionalFieldValue(fields, "72")) {
      case (?v) {
        for (line in nonEmptyLines(v).vals()) {
          lines := Array.concat<Text>(lines, ["MT103 sender receiver info " # line]);
        };
      };
      case null {};
    };
    for (tag in ["53", "54", "56"].vals()) {
      switch (fieldByTag(fields, tag)) {
        case (?f) {
          let bic = switch (firstValidBic(f.value)) { case (?b) b; case null firstLine(f.value) };
          if (bic != "") lines := Array.concat<Text>(lines, ["MT103 field " # tag # optionText(f.option) # " " # bic]);
        };
        case null {};
      };
    };
    switch (optionalFieldValue(fields, "71")) {
      case (?v) {
        let mapped = chargeBearerFromMt(firstLine(v));
        if (mapped != "") lines := Array.concat<Text>(lines, ["MT103 charge bearer " # mapped]);
      };
      case null {};
    };
    { unstructured = lines; structuredCreditorReference = null };
  };

  func chargeBearerFromMt(value : Text) : Text {
    if (value == "OUR") "DEBT"
    else if (value == "BEN") "CRED"
    else if (value == "SHA") "SHAR"
    else "";
  };

  func partyLines(value : Text, option : ?Text) : [Text] {
    var out : [Text] = [];
    var skippedBic = false;
    for (line in nonEmptyLines(value).vals()) {
      let normalized = if (option == ?"F") stripNumberedPartyPrefix(line) else line;
      if (option == ?"A" and not skippedBic and ISO.validBicFi(normalized)) {
        skippedBic := true;
      } else {
        out := Array.concat<Text>(out, [normalized]);
      };
    };
    out;
  };

  func stripNumberedPartyPrefix(value : Text) : Text {
    let bs = bytes(value);
    if (bs.size() > 2 and isDigit(bs[0]) and bs[1] == 47) {
      textSlice(bs, 2, bs.size());
    } else {
      value;
    };
  };

  func optionText(option : ?Text) : Text {
    switch (option) {
      case (?o) o;
      case null "";
    };
  };

  func fieldByTag(fields : [Mt103Field], tag : Text) : ?Mt103Field {
    for (f in fields.vals()) {
      if (f.tag == tag) return ?f;
    };
    null;
  };

  func optionalFieldValue(fields : [Mt103Field], tag : Text) : ?Text {
    switch (fieldByTag(fields, tag)) {
      case (?f) ?f.value;
      case null null;
    };
  };

  func fieldValue(field : ?Mt103Field) : Text {
    switch (field) {
      case (?f) f.value;
      case null "";
    };
  };

  func countryFromBic(bic : Text, fallback : Text) : Text {
    switch (ISO.bicCountry(bic)) {
      case (?c) c;
      case null fallback;
    };
  };

  func firstValidBic(value : Text) : ?Text {
    for (line in nonEmptyLines(value).vals()) {
      if (ISO.validBicFi(line)) return ?line;
    };
    null;
  };

  func firstLine(value : Text) : Text {
    for (line in Text.split(value, #char '\n')) {
      let t = trim(line);
      if (t != "") return t;
    };
    "";
  };

  func nonEmptyLines(value : Text) : [Text] {
    var out : [Text] = [];
    for (line in Text.split(value, #char '\n')) {
      let t = trim(line);
      if (t != "") out := Array.concat<Text>(out, [t]);
    };
    out;
  };

  func startsWithSlash(value : Text) : Bool {
    let bs = bytes(value);
    bs.size() > 0 and bs[0] == 47;
  };

  func dropFirstByte(value : Text) : Text {
    let bs = bytes(value);
    if (bs.size() <= 1) return "";
    textSlice(bs, 1, bs.size());
  };

  func parseMinorUnits(value : Text) : ?Nat {
    let bs = bytes(value);
    if (bs.size() == 0) return null;
    var whole : Nat = 0;
    var frac : Nat = 0;
    var fracDigits : Nat = 0;
    var seenSeparator = false;
    var i = 0;
    while (i < bs.size()) {
      let b = bs[i];
      if ((b == 44 or b == 46) and not seenSeparator) {
        seenSeparator := true;
      } else if (isDigit(b)) {
        let d = digitValue(b);
        if (seenSeparator) {
          if (fracDigits >= 2) return null;
          frac := (frac * 10) + d;
          fracDigits += 1;
        } else {
          whole := (whole * 10) + d;
        };
      } else {
        return null;
      };
      i += 1;
    };
    if (fracDigits == 1) frac *= 10;
    ?((whole * 100) + frac);
  };

  func parseNatStrict(value : Text) : ?Nat {
    let bs = bytes(trim(value));
    if (bs.size() == 0) return null;
    var n : Nat = 0;
    var i = 0;
    while (i < bs.size()) {
      if (not isDigit(bs[i])) return null;
      n := (n * 10) + digitValue(bs[i]);
      i += 1;
    };
    ?n;
  };

  func normalizeLines(value : Text) : Text {
    Text.replace(Text.replace(value, #text "\r\n", "\n"), #text "\r", "\n");
  };

  func yyMmDdToDate(value : Text) : Text {
    let bs = bytes(value);
    if (bs.size() < 6) return "1970-01-01";
    "20" # textSlice(bs, 0, 2) # "-" # textSlice(bs, 2, 4) # "-" # textSlice(bs, 4, 6);
  };

  func dateInt(value : Text) : Int {
    let digits = Text.replace(value, #text "-", "");
    switch (parseNatStrict(digits)) {
      case (?n) n;
      case null 0;
    };
  };

  func textAfter(value : Text, marker : Text) : ?Text {
    let bs = bytes(value);
    let ms = bytes(marker);
    if (ms.size() == 0 or bs.size() < ms.size()) return null;
    var i = 0;
    while (i + ms.size() <= bs.size()) {
      var ok = true;
      var j = 0;
      while (j < ms.size()) {
        if (bs[i + j] != ms[j]) ok := false;
        j += 1;
      };
      if (ok) return ?textSlice(bs, i + ms.size(), bs.size());
      i += 1;
    };
    null;
  };

  func firstSlashToken(value : Text) : Text {
    let bs = bytes(value);
    var i = 0;
    while (i < bs.size() and bs[i] != 47 and bs[i] != 10 and bs[i] != 13) i += 1;
    trim(textSlice(bs, 0, i));
  };

  func firstToken(value : Text) : Text {
    let bs = bytes(value);
    var i = 0;
    while (i < bs.size() and bs[i] != 32 and bs[i] != 10 and bs[i] != 13) i += 1;
    trim(textSlice(bs, 0, i));
  };

  func padNat(value : Nat, width : Nat) : Text {
    var out = Nat.toText(value);
    while (out.size() < width) out := "0" # out;
    out;
  };

  func isAmountByte(b : Nat8) : Bool {
    isDigit(b) or b == 44 or b == 46;
  };

  func add(xs : [ISO.ValidationIssue], x : ISO.ValidationIssue) : [ISO.ValidationIssue] {
    Array.concat<ISO.ValidationIssue>(xs, [x]);
  };

  func trim(value : Text) : Text {
    Text.trim(value, #predicate(func(c) { c == ' ' or c == '\n' or c == '\r' or c == '\t' }));
  };

  func bytes(value : Text) : [Nat8] {
    Blob.toArray(Text.encodeUtf8(value));
  };

  func textSlice(source : [Nat8], start : Nat, end : Nat) : Text {
    if (end <= start) return "";
    switch (Text.decodeUtf8(Blob.fromArray(Array.tabulate<Nat8>(end - start, func(i) { source[start + i] })))) {
      case (?t) t;
      case null "";
    };
  };

  func isDigit(b : Nat8) : Bool {
    let n = Nat8.toNat(b);
    n >= 48 and n <= 57;
  };

  func digitValue(b : Nat8) : Nat {
    if (b == 48) 0
    else if (b == 49) 1
    else if (b == 50) 2
    else if (b == 51) 3
    else if (b == 52) 4
    else if (b == 53) 5
    else if (b == 54) 6
    else if (b == 55) 7
    else if (b == 56) 8
    else 9;
  };

  func isUpper(b : Nat8) : Bool {
    let n = Nat8.toNat(b);
    n >= 65 and n <= 90;
  };
};
