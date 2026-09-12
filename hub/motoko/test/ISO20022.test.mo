import ISO "../ISO20022";

let g = ISO.defaultGuideline();
let pain = ISO.demoPain001();
let painReport = ISO.validatePain001(g, pain, null);
assert (painReport.ok);

switch (pain.debtorAccount.iban) {
  case (?iban) {
    assert (ISO.validIban(iban));
    assert (ISO.validEgyptianIbanShape(iban));
  };
  case null { assert false };
};
switch (pain.creditorAccount.iban) {
  case (?iban) {
    assert (ISO.validIban(iban));
    assert (ISO.validEgyptianIbanShape(iban));
  };
  case null { assert false };
};
assert (ISO.bicCountry(pain.debtorAgent.bicfi) == ?"EG");
assert (ISO.bicCountry(pain.creditorAgent.bicfi) == ?"EG");

let uetr = switch (pain.requestedUetr) {
  case (?value) value;
  case null "8f2b5e70-1d44-4e6a-9c4a-2d9c87fd0011";
};
let pacs = ISO.pacs008FromPain001(g, pain, uetr, pain.creationDateTime);
let pacsReport = ISO.validatePacs008(g, pacs, null);
assert (pacsReport.ok);
assert (pacs.messageId == pain.messageId);
assert (pacs.instructedAmount.currency == "EGP");
assert (pacs.transactionCount == 1);

let foreignPain = {
  pain with
  debtorAgent = { bicfi = "WESTGB2L"; name = ?"Foreign Example Bank" };
  debtorAccount = { iban = ?"GB82WEST12345698765432"; otherId = null; currency = ?"EGP" };
};
let foreignReport = ISO.validatePain001(g, foreignPain, null);
assert (not foreignReport.ok);

let status = ISO.pain002FromValidation(g, "PAIN002-TEST", pain.messageId, uetr, pain.creationDateTime, pacsReport);
assert (ISO.validateStatusReport(g, status, "pain.002").ok);

let ret = ISO.pacs004(g, "PACS004-TEST", pain.messageId, uetr, "return: beneficiary account closed", pain.creationDateTime);
assert (ISO.validateStatusReport(g, ret, "pacs.004").ok);
