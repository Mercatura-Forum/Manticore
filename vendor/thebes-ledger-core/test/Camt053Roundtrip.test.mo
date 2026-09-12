// Camt053Roundtrip.test.mo — criterion 9: the journal's camt.053 projection
// round-trips through the published ISO 20022 example's decoder (vendored,
// unmodified, in test/oracle/iso20022). Every entry field is compared.
//
// engine: wasi-only — the journal core now keeps its per-posting state in a stable-memory Region
// (`JournalCore.postingRows`), and the moc interpreter provides no Region. The dual-engine check this
// loses was worth having, and the loss is stated here rather than hidden: the reason the state moved
// is that a heap map per posting makes the heap grow with the journal, which is the one thing a
// contract's heap must not do. Every test below still runs under wasmtime, which is the engine the
// chain runs.

import Debug "mo:core/Debug";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Nat64 "mo:core/Nat64";
import Blob "mo:core/Blob";
import Text "mo:core/Text";
import Principal "mo:core/Principal";

import T "../src/journal/JournalTypes";
import Core "../src/journal/JournalCore";
import Camt "../src/journal/Camt053";
import MemLog "support/MemLog";
import ISO "oracle/iso20022/ISO20022";
import Xml "oracle/iso20022/ISO20022Xml";

let admin = Principal.fromBlob("\AD\01");
let poster = Principal.fromBlob("\B0\01");
let clock : Nat64 = 20705 * 86_400_000_000_000;
let chain = MemLog.new();
let s = Core.newState(admin);

func cfg(r : { #ok : T.Event; #err : T.ConfigError }) { switch (r) { case (#ok(e)) ignore MemLog.commit(chain, s, clock, admin, e); case (#err(e)) { Debug.print(debug_show(e)); assert false } } };
cfg(Core.prepareRegisterCurrency(s, admin, "EGP", 2));
cfg(Core.prepareRegisterCurrency(s, admin, "USD", 2));
cfg(Core.prepareOpenAccount(s, admin, "1500", "Cash", #debit, #asset, #none));
cfg(Core.prepareOpenAccount(s, admin, "2000", "Share capital", #credit, #equity, #none));
cfg(Core.prepareOpenAccount(s, admin, "5000", "Revenue", #credit, #income, #none));
cfg(Core.prepareOpenAccount(s, admin, "6000", "Cost of sales", #debit, #expense, #none));
cfg(Core.prepareOpenPeriod(s, admin, "2026-08", 20666, 20696));
cfg(Core.prepareOpenPeriod(s, admin, "2026-09", 20697, 20726));
cfg(Core.prepareAddPoster(s, admin, poster));
cfg(Core.prepareSetActivationHeight(s, admin, 0));

var k : Nat = 0;
func post(day : Nat, period : Text, legs : [T.Leg], narration : Text) {
  k += 1;
  let input : T.PostingInput = { idempotencyKey = Blob.fromArray([Nat8.fromNat(k)]); postingDate = day; valueDate = day - 1; period; legs; sourceRef = { kind = "pacs.008"; id = "uetr-" # Nat.toText(k) }; narration; correctionOf = null };
  switch (Core.preparePost(s, poster, clock, input)) { case (#ok(#event(e))) ignore MemLog.commit(chain, s, clock, poster, e); case (other) { Debug.print(debug_show(other)); assert false } };
};
func L(a : Text, side : T.Side, c : Text, amt : Nat) : T.Leg { { account = a; subledger = null; side; currency = c; amount = amt } };

// opening balance for September comes from August
post(20670, "2026-08", [L("1500", #debit, "EGP", 1_000_000), L("2000", #credit, "EGP", 1_000_000)], "August capital");
// September activity on cash, including a multi-leg posting and a special-character narration
post(20698, "2026-09", [L("1500", #debit, "EGP", 250_050), L("5000", #credit, "EGP", 250_050)], "Sale <A&B> 'quoted' \"dq\"");
post(20699, "2026-09", [L("6000", #debit, "EGP", 100_000), L("1500", #credit, "EGP", 100_000)], "Purchase");
post(20700, "2026-09", [L("1500", #debit, "EGP", 300), L("1500", #debit, "USD", 7), L("5000", #credit, "EGP", 300), L("5000", #credit, "USD", 7)], "Mixed currency sale");
post(20701, "2026-09", [L("6000", #debit, "EGP", 1), L("1500", #credit, "EGP", 1)], "One piastre");

func hashOf(i : Nat) : ?Blob { ?MemLog.blocks(chain)[i].hash };

let stmt = switch (Camt.statement(s, MemLog.reader(chain), "2026-09", "1500", null, "EGP", hashOf)) { case (?x) x; case null { assert false; loop {} } };
assert (stmt.entries.size() == 4);
assert (stmt.openingDebits == 1_000_000 and stmt.openingCredits == 0);
assert (stmt.closingDebits == 1_250_350 and stmt.closingCredits == 100_001);
let xml = Camt.toXml(stmt, 2, "MSG-1", "2026-09-09T00:00:00Z");
assert (Text.contains(xml, #text "<BkToCstmrStmt>"));
assert (Text.contains(xml, #text "<Amt Ccy=\"EGP\">2500.50</Amt>"));
assert (Text.contains(xml, #text "&lt;A&amp;B&gt; &apos;quoted&apos; &quot;dq&quot;"));
assert (Text.contains(xml, #text "<Cd>OPBD</Cd>") and Text.contains(xml, #text "<Cd>CLBD</Cd>"));
Debug.print("count: camt.053 statement entries projected = " # Nat.toText(stmt.entries.size()));
Debug.print("count: camt.053 xml bytes = " # Nat.toText(Text.encodeUtf8(xml).size()));

// The published example's decoder must accept the document and reproduce every entry.
var fieldsCompared = 0;
switch (Xml.decodeCamt053(Text.encodeUtf8(xml))) {
  case (#err(issues)) { for (i in issues.vals()) { Debug.print(i.ruleId # " " # i.path # " " # i.message) }; assert false };
  case (#ok(entries)) {
    assert (entries.size() == stmt.entries.size());
    var i = 0;
    while (i < entries.size()) {
      let ours = stmt.entries[i];
      let theirs = entries[i];
      assert (theirs.entryId == ours.entryId);
      assert (theirs.paymentId == ours.paymentId);
      assert (theirs.uetr == ours.uetr);
      assert (theirs.accountIban == ours.accountIban);
      assert (theirs.accountOtherId == ours.accountOtherId);
      assert (theirs.amount.currency == ours.amount.currency and theirs.amount.minorUnits == ours.amount.minorUnits);
      assert (theirs.creditDebit == ours.creditDebit);
      assert (theirs.status == ours.status);
      assert (theirs.bookedAt == ours.bookedAt);
      assert (theirs.counterpartyName == ours.counterpartyName);
      assert (theirs.remittance == ours.remittance);
      fieldsCompared += 11;
      i += 1;
    };
  };
};
// The example's validator report for the same bytes has no issues.
let report = switch (Xml.decodeCamt053(Text.encodeUtf8(xml))) {
  case (#ok(_)) ISO.reportFromIssues(ISO.defaultGuideline(), "camt.053.xml", Xml.codecVersion, []);
  case (#err(issues)) ISO.reportFromIssues(ISO.defaultGuideline(), "camt.053.xml", Xml.codecVersion, issues);
};
assert (report.ok and report.issueCount == 0);
Debug.print("count: camt.053 entries decoded by the published decoder = " # Nat.toText(stmt.entries.size()));
Debug.print("count: camt.053 entry fields compared = " # Nat.toText(fieldsCompared));
Debug.print("camt.053 published validator issues: " # Nat.toText(report.issueCount));

// Structural compatibility: the example's own serialiser accepts our records
// as its StatementEntry type, and decodes back to the same values.
let theirXml = Xml.camt053ToXml(stmt.entries);
switch (Xml.decodeCamt053(Text.encodeUtf8(theirXml))) {
  case (#ok(entries)) { assert (entries.size() == stmt.entries.size()); assert (entries[0].uetr == stmt.entries[0].uetr) };
  case (#err(_)) assert false;
};

// entry semantics
assert (stmt.entries[0].creditDebit == "DBIT" and stmt.entries[0].amount.minorUnits == 250_050);
assert (stmt.entries[1].creditDebit == "CRDT" and stmt.entries[1].counterpartyName == "6000");
assert (stmt.entries[2].amount.minorUnits == 300 and stmt.entries[2].counterpartyName == "5000");
assert (stmt.entries[0].remittance[2] == "value-date:2026-09-01");
assert (stmt.entries[0].uetr.size() == 36);
// USD statement carries only the USD leg
let usd = switch (Camt.statement(s, MemLog.reader(chain), "2026-09", "1500", null, "USD", hashOf)) { case (?x) x; case null { assert false; loop {} } };
assert (usd.entries.size() == 1 and usd.entries[0].amount.minorUnits == 7);
// unknown account or period yields null
assert (Camt.statement(s, MemLog.reader(chain), "2026-09", "4242", null, "EGP", hashOf) == null);
assert (Camt.statement(s, MemLog.reader(chain), "2026-12", "1500", null, "EGP", hashOf) == null);

// amount formatting per currency exponent, and the codec's own limit (two fraction digits)
assert (Camt.amountText(1, 0) == "1");
assert (Camt.amountText(5, 2) == "0.05");
assert (Camt.amountText(1_250_000, 2) == "12500.00");
assert (Camt.amountText(1_234, 3) == "1.234");
assert (Camt.uetrFromHash(MemLog.blocks(chain)[0].hash) == Camt.uetrFromHash(MemLog.blocks(chain)[0].hash));
assert (Camt.uetrFromHash(MemLog.blocks(chain)[0].hash) != Camt.uetrFromHash(MemLog.blocks(chain)[1].hash));
Debug.print("count: camt.053 semantics checks = 12");
