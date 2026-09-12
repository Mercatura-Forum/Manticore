import ISO "../ISO20022";
import LegacyMT "../LegacyMT";
import Text "mo:core/Text";

func rightPad(value : Text, width : Nat) : Text {
  var out = value;
  while (out.size() < width) out #= " ";
  out;
};

let mt103 = "{4:\n"
  # ":20:MT103-20260622-0001\n"
  # ":32A:260622EGP12500,00\n"
  # ":50K:/EG380019000500000000263180002\n"
  # "Example Debtor SAE\n"
  # "1 Nile Corniche\n"
  # ":52A:EGBKEGCX\n"
  # ":57A:EXBKEGCX\n"
  # ":59:/EG800002000156789012345180002\n"
  # "Example Creditor LLC\n"
  # "10 Port Road\n"
  # ":70:Invoice INV-2026-001\n"
  # ":71A:SHA\n"
  # "-}";

let fields = LegacyMT.parseMt103Fields(mt103);
assert (fields.size() == 8);
assert (fields[0].tag == "20");
assert (fields[1].tag == "32");
assert (fields[1].option == ?"A");

switch (LegacyMT.decodeMt103(Text.encodeUtf8(mt103), "EG")) {
  case (#ok(doc)) {
    assert (doc.messageId == "MT103-20260622-0001");
    assert (doc.creationDateTime == "2026-06-22T00:00:00Z");
    assert (doc.instructedAmount.currency == "EGP");
    assert (doc.instructedAmount.minorUnits == 1_250_000);
    assert (doc.debtorAgent.bicfi == "EGBKEGCX");
    assert (doc.creditorAgent.bicfi == "EXBKEGCX");
    assert (doc.remittanceInformation.unstructured.size() == 2);
    assert (doc.remittanceInformation.unstructured[1] == "MT103 charge bearer SHAR");
    assert (ISO.validatePain001(ISO.defaultGuideline(), doc, ?Text.encodeUtf8(mt103)).ok);
  };
  case (#err(_)) { assert false };
};

let mt103Options = "{4:\n"
  # ":20:MT103-OPTIONS-20260622-0001\n"
  # ":32A:260622USD2500,00\n"
  # ":50F:/EG380019000500000000263180002\n"
  # "1/Example Debtor SAE\n"
  # "2/1 Nile Corniche\n"
  # "3/EG/Cairo\n"
  # ":52A:EGBKEGCX\n"
  # ":53A:CHASUS33\n"
  # ":54A:DEUTDEFF\n"
  # ":56A:CHASUS33\n"
  # ":57A:DEUTDEFF\n"
  # ":59F:/DE89370400440532013000\n"
  # "1/Example Creditor GmbH\n"
  # "2/10 Market Platz\n"
  # "3/DE/Berlin\n"
  # ":70:Cross-border invoice 2026-001\n"
  # ":71A:SHA\n"
  # ":72:/INS/Adapter should map sender-to-receiver text\n"
  # "-}";

let optionFields = LegacyMT.parseMt103Fields(mt103Options);
assert (optionFields.size() == 12);
assert (optionFields[2].tag == "50");
assert (optionFields[2].option == ?"F");

switch (LegacyMT.decodeMt103(Text.encodeUtf8(mt103Options), "EG")) {
  case (#ok(doc)) {
    assert (doc.messageId == "MT103-OPTIONS-20260622-0001");
    assert (doc.debtor.name == "Example Debtor SAE");
    assert (doc.creditor.name == "Example Creditor GmbH");
    assert (doc.debtorAgent.bicfi == "EGBKEGCX");
    assert (doc.creditorAgent.bicfi == "DEUTDEFF");
    assert (doc.remittanceInformation.unstructured.size() == 6);
    assert (doc.remittanceInformation.unstructured[1] == "MT103 sender receiver info /INS/Adapter should map sender-to-receiver text");
    assert (doc.remittanceInformation.unstructured[2] == "MT103 field 53A CHASUS33");
    assert (ISO.validatePain001(ISO.crossBorderEducationGuideline(), doc, ?Text.encodeUtf8(mt103Options)).ok);
  };
  case (#err(_)) { assert false };
};

let mt940 = "{1:F01EGBKEGCXAXXX0000000000}{2:I940EXBKEGCXXXXN}{4:\n"
  # ":20:STM-20260622-0001\n"
  # ":25:EG800002000156789012345180002\n"
  # ":28C:00001/001\n"
  # ":60F:C260622EGP000000000000,00\n"
  # ":61:2606220622C12500,00NTRFNONREF//ISO-HUB-20260622-000001\n"
  # ":86:/UETR/8f2b5e70-1d44-4e6a-9c4a-2d9c87fd0011/REMI/Invoice INV-2026-001\n"
  # ":62F:C260622EGP0000000012500,00\n"
  # "-}";

switch (LegacyMT.decodeMt940(Text.encodeUtf8(mt940), "EGP")) {
  case (#ok(entries)) {
    assert (entries.size() == 1);
    assert (entries[0].entryId == "ISO-HUB-20260622-000001");
    assert (entries[0].accountIban == ?"EG800002000156789012345180002");
    assert (entries[0].amount.currency == "EGP");
    assert (entries[0].amount.minorUnits == 1_250_000);
    assert (entries[0].uetr == "8f2b5e70-1d44-4e6a-9c4a-2d9c87fd0011");
    assert (entries[0].remittance[0] == "Invoice INV-2026-001");
  };
  case (#err(_)) { assert false };
};

let mt942 = "{1:F01EGBKEGCXAXXX0000000000}{2:I942EXBKEGCXXXXN}{4:\n"
  # ":20:INTRADAY-20260622-0001\n"
  # ":25:EG800002000156789012345180002\n"
  # ":28C:00001/001\n"
  # ":13D:2606221000+0200\n"
  # ":61:2606220622C12500,00NTRFNONREF//ISO-HUB-20260622-000001\n"
  # ":86:/UETR/8f2b5e70-1d44-4e6a-9c4a-2d9c87fd0011/REMI/Invoice INV-2026-001\n"
  # "-}";

switch (LegacyMT.decodeMt942(Text.encodeUtf8(mt942), "EGP")) {
  case (#ok(entries)) {
    assert (entries.size() == 1);
    assert (entries[0].status == "intraday");
    assert (entries[0].creditDebit == "CRDT");
  };
  case (#err(_)) { assert false };
};

let csv = "messageId,executionDate,currency,amountMinor,debtorName,debtorIban,debtorBic,creditorName,creditorIban,creditorBic,remittance\n"
  # "CSV-20260622-000001,2026-06-22,EGP,1250000,Example Debtor SAE,EG380019000500000000263180002,EGBKEGCX,Example Creditor LLC,EG800002000156789012345180002,EXBKEGCX,Invoice INV-2026-001\n";

switch (LegacyMT.decodeCsvPayments(Text.encodeUtf8(csv), "EG")) {
  case (#ok(docs)) {
    assert (docs.size() == 1);
    assert (docs[0].messageId == "CSV-20260622-000001");
    assert (ISO.validatePain001(ISO.defaultGuideline(), docs[0], ?Text.encodeUtf8(csv)).ok);
  };
  case (#err(_)) { assert false };
};

let fixedLine = rightPad("FW-20260622-000001", 35)
  # "EGP"
  # "000001250000"
  # rightPad("EGBKEGCX", 11)
  # rightPad("EXBKEGCX", 11)
  # rightPad("EG380019000500000000263180002", 34)
  # rightPad("EG800002000156789012345180002", 34);

switch (LegacyMT.decodeFixedWidthPayments(Text.encodeUtf8(fixedLine), "EG")) {
  case (#ok(docs)) {
    assert (docs.size() == 1);
    assert (docs[0].messageId == "FW-20260622-000001");
    assert (docs[0].instructedAmount.minorUnits == 1_250_000);
    assert (ISO.validatePain001(ISO.defaultGuideline(), docs[0], ?Text.encodeUtf8(fixedLine)).ok);
  };
  case (#err(_)) { assert false };
};

let missing32A = ":20:ONLY-ID\n:50K:/EG380019000500000000263180002\n";
switch (LegacyMT.decodeMt103(Text.encodeUtf8(missing32A), "EG")) {
  case (#ok(_)) { assert false };
  case (#err(issues)) {
    assert (issues.size() > 0);
    assert (issues[0].ruleId == "MT103-32A-REQUIRED");
  };
};
