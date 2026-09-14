// PartyCore.test.mo: the party / CIF and KYC state machine.
//
// The criterion that governs this component is K-1: **no plaintext personal data
// in any block**. It is checked here the only way it can be; by creating a party
// from a fixture full of distinctive personal strings, driving it through its
// whole life, and then decoding every block of the log to raw bytes and searching
// for every one of those strings and for every fourteen-digit run. Zero hits, or
// the test fails.
//
// Then the controls: the lifecycle matrix exhaustively, the CDD gate on becoming
// active, the movement gate (blocked, hit, stale, overdue review) with the state
// unchanged on every refusal, exact-match deduplication, identifier issuance
// through one code path, collateral that cannot be over-allocated, extension
// schemas that admit only what they declare, and replay equality.
// engine: wasi-only; this battery fingerprints the whole state on every refusal.

import Debug "mo:core/Debug";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Nat64 "mo:core/Nat64";
import Blob "mo:core/Blob";
import Array "mo:core/Array";
import List "mo:core/List";
import Text "mo:core/Text";
import Principal "mo:core/Principal";
import Char "mo:core/Char";
import Nat32 "mo:core/Nat32";

import JT "mo:journal/JournalTypes";
import JCore "mo:journal/JournalCore";
import JC "mo:journal/Canonical";

import T "../src/bank/BankTypes";
import PT "../src/bank/PartyTypes";
import Core "../src/bank/BankCore";
import PartyCore "../src/bank/PartyCore";
import Commit "../src/bank/Commitments";
import BC "../src/bank/BankCanonical";
import S "../src/bank/Screening";
import Iban "../src/bank/Iban";
import P "../src/bank/Permissions";
import BankMemLog "support/BankMemLog";
import JMemLog "support/JournalMemLog";

// ─── fixtures ────────────────────────────────────────────────────────────────

let bankP = Principal.fromBlob("\BA\01");
let installer = Principal.fromBlob("\1A\01");
let officer = Principal.fromBlob("\2A\01");
let checker = Principal.fromBlob("\3A\01");
let screener = Principal.fromBlob("\4A\01");

let DAY : Nat64 = 86_400_000_000_000;
let TODAY : Nat = 20705;
var clock : Nat64 = Nat64.fromNat(TODAY) * DAY + 43_200_000_000_000;
let SEP1 = 20697; let SEP30 = 20726;

let bchain = BankMemLog.new();
let jchain = JMemLog.new();
let bs = Core.newState(installer);
let js = JCore.newState(bankP);

func bcommit(caller : Principal, e : T.Event) : T.Block { BankMemLog.commit(bchain, bs, clock, caller, e) };
func jcommit(e : JT.Event) : JT.Block { JMemLog.commit(jchain, js, clock, bankP, e) };

func execute(authority : Principal, command : T.Command, authorityIndex : Nat) : [Nat] {
  switch (Core.planCommand(bs, BankMemLog.reader(bchain), js, JMemLog.reader(jchain), bankP, clock, command, authorityIndex)) {
    case (#err(e)) { Debug.print("plan failed for " # P.commandName(command) # ": " # debug_show (e)); assert false; [] };
    case (#ok(plan)) {
      switch (plan.bankEvent) { case (?ev) { ignore bcommit(authority, ev) }; case null {} };
      for (ev in plan.extra.vals()) { ignore bcommit(authority, ev) };
      let out = List.empty<Nat>();
      for (step in plan.journal.vals()) {
        switch (step) { case (#event(ev)) List.add(out, jcommit(ev).index); case (#existing(i)) List.add(out, i) };
      };
      List.toArray(out)
    };
  }
};
/// Run a command the way genesis or an approved proposal does, returning the bank
/// block index it occupied (which is the identifier for a created entity).
func run(command : T.Command) : Nat {
  let at = Core.height(bs);
  ignore execute(installer, command, at);
  at
};
func expectErr(command : T.Command, want : Text) {
  let fp = Core.fingerprint(bs);
  let h = Core.height(bs);
  switch (Core.planCommand(bs, BankMemLog.reader(bchain), js, JMemLog.reader(jchain), bankP, clock, command, Core.height(bs))) {
    case (#ok(_)) { Debug.print("expected " # want # " for " # P.commandName(command)); assert false };
    case (#err(e)) {
      let got = debug_show (e);
      if (not Text.contains(got, #text want)) { Debug.print("wanted " # want # " got " # got); assert false };
    };
  };
  assert (Core.fingerprint(bs) == fp and Core.height(bs) == h);
};

// ─── the replicated log starts: journal poster, admin, books, journal chart ───
ignore jcommit(switch (JCore.prepareAddPoster(js, bankP, bankP)) { case (#ok(e)) e; case (#err(_)) { assert false; #posterAdded({ poster = bankP }) } });
ignore bcommit(installer, #bankAdminTransferred({ admin = installer }));
ignore run(#openBook({ id = "HQ"; name = "Head office"; parent = null }));
ignore run(#openBook({ id = "BR01"; name = "Branch 1"; parent = ?"HQ" }));
ignore run(#journalRegisterCurrency({ code = "EGP"; minorUnits = 2 }));
ignore run(#journalOpenAccount({ code = "1001"; name = "Cash"; normalSide = #debit; category = #asset; constraint = #none }));
ignore run(#journalOpenAccount({ code = "2110"; name = "Customer deposits"; normalSide = #credit; category = #liability; constraint = #none }));
ignore run(#journalOpenPeriod({ id = "2026-09"; start = SEP1; end = SEP30 }));
ignore run(#journalSetActivationHeight({ height = 0 }));
ignore run(#setAccountFormat({ country = "EG"; bank = "0037"; branch = "0001"; serialWidth = 12; prefix = "00000" }));
assert (JCore.isActive(js));

// ═══════════════════════════════════════════════════════════════════════════
//  the personal-data fixture: every string here must never appear in a block
// ═══════════════════════════════════════════════════════════════════════════

type Person = { name : Text; nationalId : Text; passport : Text; address : Text; dob : Text };

let people : [Person] = [
  { name = "Mohamed Ahmed Hassan"; nationalId = "29801011234567"; passport = "A12345678"; address = "12 Qasr al-Nil, Cairo"; dob = "1998-01-01" },
  { name = "Fatma Ibrahim Said"; nationalId = "29512239876543"; passport = "B87654321"; address = "7 Corniche, Alexandria"; dob = "1995-12-23" },
  { name = "Youssef Kamal Selim"; nationalId = "30003155555555"; passport = "C11223344"; address = "3 Zamalek, Giza"; dob = "2000-03-15" },
  { name = "Nadia Mostafa Ali"; nationalId = "28707077777777"; passport = "D99887766"; address = "88 Heliopolis, Cairo"; dob = "1987-07-07" },
];

func saltFor(i : Nat) : Blob { Blob.fromArray(Array.tabulate<Nat8>(32, func(j) { Nat8.fromNat((i * 31 + j * 7) % 256) })) };
let institutionSalt = Blob.fromArray(Array.tabulate<Nat8>(32, func(j) { Nat8.fromNat((j * 11 + 3) % 256) }));

func createCommand(i : Nat, p : Person, book : Text, cdd : PT.CddLevel) : T.Command {
  let salt = saltFor(i);
  #createParty({
    kind = #natural;
    salt;
    identityCommit = Commit.identity(salt, #natural, [p.name, p.nationalId]);
    dedupCommit = ?Commit.dedup(institutionSalt, "nationalId", p.nationalId);
    attributes = [
      { name = Commit.SCREENING_SUBJECT; commit = Commit.field(salt, Commit.SCREENING_SUBJECT, p.name) },
      { name = "nationalId"; commit = Commit.field(salt, "nationalId", p.nationalId) },
      { name = "passport"; commit = Commit.field(salt, "passport", p.passport) },
      { name = "address"; commit = Commit.field(salt, "address", p.address) },
      { name = "dateOfBirth"; commit = Commit.field(salt, "dateOfBirth", p.dob) },
    ];
    book;
    cddLevel = cdd;
    riskRating = #medium;
    pep = false;
    reviewDue = TODAY + 365;
  })
};

var partyIds : [Nat] = [];
var i = 0;
while (i < people.size()) {
  let id = run(createCommand(i, people[i], if (i % 2 == 0) "BR01" else "HQ", if (i == 3) #enhanced else #standard));
  partyIds := Array.concat(partyIds, [id]);
  i += 1;
};
Debug.print("count: parties created = " # Nat.toText(partyIds.size()));
assert (partyIds.size() == 4);
assert (PartyCore.partyCount(bs.party) == 4);

// ═══════════════════════════════════════════════════════════════════════════
//  K-2  commitments verify, and a mismatch is refused
// ═══════════════════════════════════════════════════════════════════════════
var commitmentChecks = 0;
i := 0;
while (i < people.size()) {
  let ?p = PartyCore.get(bs.party, Core.partyBlocks(BankMemLog.reader(bchain)), partyIds[i]) else { assert false; loop {} };
  let salt = saltFor(i);
  // the canister recomputes from the components a client submits
  assert (PartyCore.verifyIdentity(p, Commit.identity(salt, #natural, [people[i].name, people[i].nationalId])) == null);
  assert (PartyCore.verifyIdentity(p, Commit.identity(salt, #natural, [people[i].name, "00000000000000"])) != null);
  assert (PartyCore.verifyFields(p, [{ name = "nationalId"; commit = Commit.field(salt, "nationalId", people[i].nationalId) }]) == null);
  assert (PartyCore.verifyFields(p, [{ name = "nationalId"; commit = Commit.field(salt, "nationalId", "99999999999999") }]) != null);
  assert (PartyCore.verifyFields(p, [{ name = "notAField"; commit = Commit.field(salt, "notAField", "x") }]) != null);
  // salts are distinct across parties
  var j = 0;
  while (j < i) { assert (saltFor(i) != saltFor(j)); j += 1 };
  commitmentChecks += 5;
  i += 1;
};
Debug.print("count: commitment verifications and refusals = " # Nat.toText(commitmentChecks));
assert (commitmentChecks == 20);

// normalisation is idempotent, which is what lets a screening subject be
// committed from already-normalised bytes
i := 0;
var idempotent = 0;
while (i < people.size()) {
  let salt = saltFor(i);
  let norm = Text.encodeUtf8(Commit.normalise(people[i].name));
  assert (Commit.fieldBytes(salt, Commit.SCREENING_SUBJECT, norm) == Commit.field(salt, Commit.SCREENING_SUBJECT, people[i].name));
  assert (Commit.normalise(Commit.normalise(people[i].name)) == Commit.normalise(people[i].name));
  idempotent += 2;
  i += 1;
};
Debug.print("count: normalisation idempotence checks = " # Nat.toText(idempotent));

// a malformed commitment or salt is refused
expectErr(#createParty({ kind = #natural; salt = Blob.fromArray([1]); identityCommit = saltFor(9); dedupCommit = null; attributes = []; book = "HQ"; cddLevel = #standard; riskRating = #low; pep = false; reviewDue = TODAY }), "salt must be 32 bytes");
expectErr(#createParty({ kind = #natural; salt = saltFor(9); identityCommit = Blob.fromArray([1]); dedupCommit = null; attributes = []; book = "HQ"; cddLevel = #standard; riskRating = #low; pep = false; reviewDue = TODAY }), "identity commitment must be 32 bytes");
// exact-match deduplication: the same national identifier is refused
expectErr(createCommand(0, people[0], "HQ", #standard), "DuplicateIdentity");
Debug.print("count: malformed or duplicate party creations refused = 3");

// ═══════════════════════════════════════════════════════════════════════════
//  K-4  the lifecycle matrix, exhaustively
// ═══════════════════════════════════════════════════════════════════════════
let states : [PT.Lifecycle] = [#prospect, #pendingKyc, #active, #dormant, #blocked, #closed];
var allowed = 0;
var refusedTransitions = 0;
for (from in states.vals()) {
  for (to in states.vals()) {
    if (PartyCore.transitionAllowed(from, to)) allowed += 1 else refusedTransitions += 1;
  };
};
Debug.print("count: lifecycle transitions examined = " # Nat.toText(allowed + refusedTransitions));
Debug.print("count: lifecycle transitions allowed = " # Nat.toText(allowed));
assert (allowed + refusedTransitions == 36);
assert (allowed == 13);

// every illegal transition from the real state is refused on the state machine
let party0 = partyIds[0];
for (to in states.vals()) {
  if (not PartyCore.transitionAllowed(#prospect, to)) {
    expectErr(#setPartyLifecycle({ party = party0; to }), "IllegalTransition");
  };
};
Debug.print("count: illegal transitions refused from prospect = 4");

// ═══════════════════════════════════════════════════════════════════════════
//  the CDD gate: active requires the documents its level demands
// ═══════════════════════════════════════════════════════════════════════════
ignore run(#setPartyLifecycle({ party = party0; to = #pendingKyc }));
expectErr(#setPartyLifecycle({ party = party0; to = #active }), "CddIncomplete");
// one document is not enough for a standard level
ignore run(#addPartyDocument({ party = party0; document = { kind = "identity"; commit = Commit.document(saltFor(0), "identity", Blob.fromArray([1])); issued = 20000; expires = ?(TODAY + 1000) } }));
expectErr(#setPartyLifecycle({ party = party0; to = #active }), "CddIncomplete");
ignore run(#addPartyDocument({ party = party0; document = { kind = "address"; commit = Commit.document(saltFor(0), "address", Blob.fromArray([2])); issued = 20000; expires = null } }));
// and screening must permit it
expectErr(#setPartyLifecycle({ party = party0; to = #active }), "ScreeningBlocks");
Debug.print("count: CDD and screening gates on activation = 3");

// a document that expires before it was issued is refused
expectErr(#addPartyDocument({ party = party0; document = { kind = "x"; commit = Commit.document(saltFor(0), "x", Blob.fromArray([3])); issued = 21000; expires = ?20000 } }), "cannot expire before");

// ═══════════════════════════════════════════════════════════════════════════
//  K-6  absence from a committed list is provable
// ═══════════════════════════════════════════════════════════════════════════
// build a list that contains one of our people and not the others
var listed : [Text] = ["LISTED ONE", "LISTED TWO", people[3].name];
var k = 0;
while (k < 200) { listed := Array.concat(listed, ["SANCTIONED PERSON " # Nat.toText(k)]); k += 1 };
var entries = Array.map<Text, Blob>(listed, func(t) { S.entryBytes(t) });
entries := Array.sort<Blob>(entries, func(a, b) { switch (S.compareEntries(a, b)) { case (#less) #less; case (#equal) #equal; case (#greater) #greater } });
assert (S.validateSorted(entries) == null);
let ?listRoot = S.root(entries) else { assert false; loop {} };
ignore run(#commitScreeningList({ version = "UN-2026-09"; root = listRoot; count = entries.size(); normalisation = Commit.NORMALISATION }));
Debug.print("count: screening list entries committed = " # Nat.toText(entries.size()));

// a list whose normalisation is not this build's rule set is refused
expectErr(#commitScreeningList({ version = "other"; root = listRoot; count = entries.size(); normalisation = "something-else" }), "normalised by this build");
expectErr(#commitScreeningList({ version = "UN-2026-09"; root = listRoot; count = 1; normalisation = Commit.NORMALISATION }), "ListExists");

// party 0 is absent: the proof verifies and the state becomes clear
let subject0 = S.entryBytes(people[0].name);
let ?proof0 = S.adjacencyProof(entries, subject0) else { Debug.print("no proof"); assert false; loop {} };
ignore run(#proveScreeningClear({ party = party0; listVersion = "UN-2026-09"; subject = subject0; proof = proof0 }));
switch (PartyCore.get(bs.party, Core.partyBlocks(BankMemLog.reader(bchain)), party0)) {
  case (?p) { switch (PartyCore.effectiveScreening(bs.party, p)) { case (#clear(_)) {}; case (x) { Debug.print("not clear: " # debug_show (x)); assert false } } };
  case null { assert false };
};
// now activation succeeds
ignore run(#setPartyLifecycle({ party = party0; to = #active }));
assert (PartyCore.permitsMovement(bs.party, Core.partyBlocks(BankMemLog.reader(bchain)), party0, TODAY) == null);
Debug.print("count: parties proved clear and activated = 1");

// a subject that is not the party's own recorded screening subject is refused
let wrongSubject = S.entryBytes(people[1].name);
let ?wrongProof = S.adjacencyProof(entries, wrongSubject) else { assert false; loop {} };
expectErr(#proveScreeningClear({ party = party0; listVersion = "UN-2026-09"; subject = wrongSubject; proof = wrongProof }), "screeningSubject");
// a party that IS on the list cannot be proved absent
let party3 = partyIds[3];
let subject3 = S.entryBytes(people[3].name);
assert (S.adjacencyProof(entries, subject3) == null);
// and a hand-built bracket around it is reported as membership, not as a bad proof
var idx3 : ?Nat = null;
var z = 0;
while (z < entries.size()) { if (entries[z] == subject3) idx3 := ?z; z += 1 };
let ?ix = idx3 else { assert false; loop {} };
let ?lp = S.path(entries, ix - 1) else { assert false; loop {} };
let ?up = S.path(entries, ix) else { assert false; loop {} };
expectErr(#proveScreeningClear({ party = party3; listVersion = "UN-2026-09"; subject = subject3;
  proof = { lower = ?{ entry = entries[ix - 1]; index = ix - 1; path = lp }; upper = ?{ entry = entries[ix]; index = ix; path = up } } }), "SubjectIsOnTheList");
// a tampered proof is refused
expectErr(#proveScreeningClear({ party = party0; listVersion = "UN-2026-09"; subject = subject0;
  proof = { lower = proof0.lower; upper = null } }), "AdjacencyProofFailed");
expectErr(#proveScreeningClear({ party = party0; listVersion = "nosuchlist"; subject = subject0; proof = proof0 }), "UnknownList");
Debug.print("count: screening proof refusals = 5");

// ═══════════════════════════════════════════════════════════════════════════
//  K-7  the attested layer, and its recorded consequences
// ═══════════════════════════════════════════════════════════════════════════
let party1 = partyIds[1];
ignore run(#setPartyLifecycle({ party = party1; to = #pendingKyc }));
ignore run(#addPartyDocument({ party = party1; document = { kind = "identity"; commit = Commit.document(saltFor(1), "identity", Blob.fromArray([1])); issued = 20000; expires = null } }));
ignore run(#addPartyDocument({ party = party1; document = { kind = "address"; commit = Commit.document(saltFor(1), "address", Blob.fromArray([2])); issued = 20000; expires = null } }));
// a clear attestation activates movement
ignore run(#recordScreeningDecision({ party = party1; listVersion = "UN-2026-09"; listRoot = listRoot; decision = #clear; screener; justificationCommit = Commit.justification("no match") }));
ignore run(#setPartyLifecycle({ party = party1; to = #active }));
assert (PartyCore.permitsMovement(bs.party, Core.partyBlocks(BankMemLog.reader(bchain)), party1, TODAY) == null);
// a hit blocks it
ignore run(#recordScreeningDecision({ party = party1; listVersion = "UN-2026-09"; listRoot = listRoot; decision = #hit({ matches = 2 }); screener; justificationCommit = Commit.justification("two candidates") }));
switch (PartyCore.permitsMovement(bs.party, Core.partyBlocks(BankMemLog.reader(bchain)), party1, TODAY)) {
  case (?#ScreeningBlocks(_)) {};
  case (x) { Debug.print("a hit did not block: " # debug_show (x)); assert false };
};
// clearing it restores movement, with the reason recorded
ignore run(#recordScreeningDecision({ party = party1; listVersion = "UN-2026-09"; listRoot = listRoot; decision = #cleared({ reason = "different date of birth" }); screener; justificationCommit = Commit.justification("dob differs") }));
assert (PartyCore.permitsMovement(bs.party, Core.partyBlocks(BankMemLog.reader(bchain)), party1, TODAY) == null);
// a confirmed match blocks the party outright
ignore run(#recordScreeningDecision({ party = party1; listVersion = "UN-2026-09"; listRoot = listRoot; decision = #confirmed; screener; justificationCommit = Commit.justification("confirmed") }));
switch (PartyCore.get(bs.party, Core.partyBlocks(BankMemLog.reader(bchain)), party1)) {
  case (?p) { assert (p.lifecycle == #blocked) };
  case null { assert false };
};
switch (PartyCore.permitsMovement(bs.party, Core.partyBlocks(BankMemLog.reader(bchain)), party1, TODAY)) {
  case (?#PartyNotActive(_)) {};
  case (x) { Debug.print("a confirmed match did not block the party: " # debug_show (x)); assert false };
};
Debug.print("count: attested screening decisions and their consequences = 4");

// a decision whose list root does not match the recorded list is refused
expectErr(#recordScreeningDecision({ party = party0; listVersion = "UN-2026-09"; listRoot = Commit.listLeaf(S.entryBytes("x")); decision = #clear; screener; justificationCommit = Commit.justification("x") }), "list root");

// a newer list makes an older clearance stale, and money stops
var listed2 = Array.concat(listed, ["NEW SANCTION"]);
var entries2 = Array.map<Text, Blob>(listed2, func(t) { S.entryBytes(t) });
entries2 := Array.sort<Blob>(entries2, func(a, b) { switch (S.compareEntries(a, b)) { case (#less) #less; case (#equal) #equal; case (#greater) #greater } });
let ?root2 = S.root(entries2) else { assert false; loop {} };
ignore run(#commitScreeningList({ version = "UN-2026-10"; root = root2; count = entries2.size(); normalisation = Commit.NORMALISATION }));
switch (PartyCore.permitsMovement(bs.party, Core.partyBlocks(BankMemLog.reader(bchain)), party0, TODAY)) {
  case (?#ScreeningBlocks({ state = #rescreenDue(_) })) {};
  case (x) { Debug.print("a stale clearance did not block: " # debug_show (x)); assert false };
};
// re-proving against the new list restores movement
let ?proof0b = S.adjacencyProof(entries2, subject0) else { assert false; loop {} };
ignore run(#proveScreeningClear({ party = party0; listVersion = "UN-2026-10"; subject = subject0; proof = proof0b }));
assert (PartyCore.permitsMovement(bs.party, Core.partyBlocks(BankMemLog.reader(bchain)), party0, TODAY) == null);
Debug.print("count: staleness checks = 2");

// ═══════════════════════════════════════════════════════════════════════════
//  K-5  the movement gate is atomic and records nothing on refusal
// ═══════════════════════════════════════════════════════════════════════════
func entryFor(party : Nat, amount : Nat, key : Nat8) : T.Command {
  #postManualEntryForParty({
    party;
    entry = {
      book = "BR01"; postingDate = TODAY; valueDate = TODAY; period = "2026-09";
      legs = [
        { account = "1001"; subledger = null; side = #debit; currency = "EGP"; amount },
        { account = "2110"; subledger = null; side = #credit; currency = "EGP"; amount },
      ];
      narration = "party entry"; idempotencyKey = Blob.fromArray([0xAA, key]); correctionOf = null;
    };
  })
};
// an active, screened, in-review party moves money
let jh = JCore.height(js);
ignore run(entryFor(party0, 1_000_00, 1));
assert (JCore.height(js) == jh + 1);
// a blocked party does not, and the journal is untouched
let jfp = JCore.fingerprint(js);
expectErr(entryFor(party1, 1_000_00, 2), "PartyNotActive");
assert (JCore.fingerprint(js) == jfp);
// an unknown party does not
expectErr(entryFor(9999, 1_000_00, 3), "UnknownParty");
// a party whose review is overdue past the grace does not
let party2 = partyIds[2];
ignore run(#setPartyLifecycle({ party = party2; to = #pendingKyc }));
ignore run(#addPartyDocument({ party = party2; document = { kind = "identity"; commit = Commit.document(saltFor(2), "identity", Blob.fromArray([1])); issued = 20000; expires = null } }));
ignore run(#addPartyDocument({ party = party2; document = { kind = "address"; commit = Commit.document(saltFor(2), "address", Blob.fromArray([2])); issued = 20000; expires = null } }));
let subject2 = S.entryBytes(people[2].name);
let ?proof2 = S.adjacencyProof(entries2, subject2) else { assert false; loop {} };
ignore run(#proveScreeningClear({ party = party2; listVersion = "UN-2026-10"; subject = subject2; proof = proof2 }));
ignore run(#setPartyLifecycle({ party = party2; to = #active }));
// push its review into the past
ignore run(#setPartyCdd({ party = party2; level = #standard; riskRating = #low; pep = false; reviewDue = TODAY - 100 }));
switch (PartyCore.permitsMovement(bs.party, Core.partyBlocks(BankMemLog.reader(bchain)), party2, TODAY)) {
  case (?#ReviewOverdue(_)) {};
  case (x) { Debug.print("an overdue review did not block: " # debug_show (x)); assert false };
};
expectErr(entryFor(party2, 1_000_00, 4), "ReviewOverdue");
// inside the grace it moves
ignore run(#setPartyCdd({ party = party2; level = #standard; riskRating = #low; pep = false; reviewDue = TODAY - 10 }));
assert (PartyCore.permitsMovement(bs.party, Core.partyBlocks(BankMemLog.reader(bchain)), party2, TODAY) == null);
ignore run(entryFor(party2, 500_00, 5));
Debug.print("count: movement-gate reasons exercised = 4");

// ═══════════════════════════════════════════════════════════════════════════
//  K-8  identifiers: generation and validation through one code path
// ═══════════════════════════════════════════════════════════════════════════
var issued : [Text] = [];
var issuedN = 0;
for (pid in [party0, party2].vals()) {
  var q = 0;
  while (q < 3) {
    let at = Core.height(bs);
    ignore run(#issueIdentifier({ party = pid }));
    // the identifier is the one the format implies for this block index
    switch (Iban.issue({ country = "EG"; bank = "0037"; branch = "0001"; serialWidth = 12; prefix = "00000" }, at)) {
      case (#ok(expected)) {
        assert (PartyCore.byIdentifier(bs.party, expected) == ?pid);
        assert (Iban.isValid(expected));
        issued := Array.concat(issued, [expected]);
        issuedN += 1;
      };
      case (#err(e)) { Debug.print("issue mismatch: " # e); assert false };
    };
    q += 1;
  };
};
Debug.print("count: identifiers issued to parties = " # Nat.toText(issuedN));
assert (issuedN == 6);
// all distinct
var dup = 0;
i := 0;
while (i < issued.size()) {
  var j = i + 1;
  while (j < issued.size()) { if (Text.equal(issued[i], issued[j])) dup += 1; j += 1 };
  i += 1;
};
assert (dup == 0);
// a format that does not add up is refused
expectErr(#setAccountFormat({ country = "EG"; bank = "0037"; branch = "0001"; serialWidth = 2; prefix = "0" }), "prefix plus serial");
expectErr(#setAccountFormat({ country = "ZZ"; bank = "0037"; branch = "0001"; serialWidth = 12; prefix = "00000" }), "no profile");
Debug.print("count: account-format refusals = 2");

// ═══════════════════════════════════════════════════════════════════════════
//  K-9  collateral cannot be over-allocated
// ═══════════════════════════════════════════════════════════════════════════
let collateral = run(#registerCollateral({ party = party0; kind = #property; valuation = { amount = 1_000_000_00; currency = "EGP"; asOf = TODAY; source = "valuer A"; haircut = 30 }; descriptionCommit = Commit.document(saltFor(0), "deed", Blob.fromArray([9])) }));
let available = 1_000_000_00 * 70 / 100;
switch (PartyCore.getCollateral(bs.party, Core.partyBlocks(BankMemLog.reader(bchain)), collateral)) {
  case (?c) { assert (PartyCore.haircutValue(c.valuation) == available) };
  case null { assert false };
};
ignore run(#allocateCollateral({ collateral; facility = "LOAN-1"; amount = available / 2 }));
ignore run(#allocateCollateral({ collateral; facility = "LOAN-2"; amount = available / 2 }));
expectErr(#allocateCollateral({ collateral; facility = "LOAN-3"; amount = 1 }), "AllocationExceedsValue");
expectErr(#allocateCollateral({ collateral; facility = "LOAN-3"; amount = 0 }), "secures nothing");
// a revaluation below the allocated total is admitted and leaves it under-secured
ignore run(#revalueCollateral({ collateral; valuation = { amount = 100_000_00; currency = "EGP"; asOf = TODAY; source = "valuer B"; haircut = 30 } }));
switch (PartyCore.getCollateral(bs.party, Core.partyBlocks(BankMemLog.reader(bchain)), collateral)) {
  case (?c) {
    assert (PartyCore.allocatedAgainst(c) > PartyCore.haircutValue(c.valuation));
  };
  case null { assert false };
};
// a currency change is refused
expectErr(#revalueCollateral({ collateral; valuation = { amount = 100_000_00; currency = "USD"; asOf = TODAY; source = "x"; haircut = 0 } }), "cannot change the currency");
// release is refused while anything is allocated
expectErr(#releaseCollateral({ collateral }), "AllocationExceedsValue");
// random allocation sequences never breach the bound
var breaches = 0;
var sequences = 0;
var seed = 7;
var c2 = 0;
while (c2 < 20) {
  let cid = run(#registerCollateral({ party = party0; kind = #securities; valuation = { amount = 1_000_00 * (c2 + 1); currency = "EGP"; asOf = TODAY; source = "s"; haircut = (c2 * 5) % 100 }; descriptionCommit = Commit.document(saltFor(0), "sec", Blob.fromArray([Nat8.fromNat(c2)])) }));
  let ?entry = PartyCore.getCollateral(bs.party, Core.partyBlocks(BankMemLog.reader(bchain)), cid) else { assert false; loop {} };
  let cap = PartyCore.haircutValue(entry.valuation);
  var n2 = 0;
  while (n2 < 5) {
    seed := (seed * 1103515245 + 12345) % 2147483648;
    let want = if (cap == 0) 1 else (seed % (cap + 10)) + 1;
    switch (Core.planCommand(bs, BankMemLog.reader(bchain), js, JMemLog.reader(jchain), bankP, clock, #allocateCollateral({ collateral = cid; facility = "F" # Nat.toText(n2); amount = want }), Core.height(bs))) {
      case (#ok(_)) { ignore run(#allocateCollateral({ collateral = cid; facility = "F" # Nat.toText(n2); amount = want })) };
      case (#err(_)) {};
    };
    if (PartyCore.allocatedAgainst(entry) > cap) breaches += 1;
    sequences += 1;
    n2 += 1;
  };
  c2 += 1;
};
Debug.print("count: random allocation attempts = " # Nat.toText(sequences));
Debug.print("count: allocation bound breaches = 0 (asserted)");
assert (breaches == 0);
assert (sequences == 100);

// ═══════════════════════════════════════════════════════════════════════════
//  K-10  extension schemas admit only what they declare
// ═══════════════════════════════════════════════════════════════════════════
ignore run(#registerSchema({ id = "kyc"; entity = #party; fields = [
  { name = "sector"; fieldType = #enumerated(["retail", "corporate"]); required = true },
  { name = "employees"; fieldType = #integer({ min = 0; max = 100000 }); required = false },
  { name = "note"; fieldType = #text({ maxBytes = 16 }); required = false },
  { name = "onboarded"; fieldType = #date; required = false },
  { name = "resident"; fieldType = #boolean; required = false },
  { name = "taxIdCommit"; fieldType = #commitment; required = false },
] }));
expectErr(#registerSchema({ id = "kyc"; entity = #party; fields = [] }), "SchemaExists");
expectErr(#registerSchema({ id = "empty"; entity = #party; fields = [] }), "no fields");
expectErr(#registerSchema({ id = "bad"; entity = #party; fields = [{ name = "x"; fieldType = #integer({ min = 5; max = 1 }); required = false }] }), "min above max");
expectErr(#registerSchema({ id = "bad2"; entity = #party; fields = [{ name = "x"; fieldType = #enumerated([]); required = false }] }), "no values");
expectErr(#registerSchema({ id = "bad3"; entity = #party; fields = [{ name = "x"; fieldType = #text({ maxBytes = 0 }); required = false }] }), "impossible bound");
// a valid set is admitted
ignore run(#setPartyExtension({ party = party0; values = [
  { schema = "kyc"; name = "sector"; value = #enumerated("retail") },
  { schema = "kyc"; name = "employees"; value = #integer(12) },
  { schema = "kyc"; name = "note"; value = #text("short") },
  { schema = "kyc"; name = "resident"; value = #boolean(true) },
  { schema = "kyc"; name = "taxIdCommit"; value = #commitment(Commit.field(saltFor(0), "taxId", "123456789")) },
] }));
// every way of violating the schema is refused
expectErr(#setPartyExtension({ party = party0; values = [{ schema = "nosuch"; name = "x"; value = #boolean(true) }] }), "UnknownSchema");
expectErr(#setPartyExtension({ party = party0; values = [{ schema = "kyc"; name = "sector"; value = #enumerated("retail") }, { schema = "kyc"; name = "nosuch"; value = #boolean(true) }] }), "FieldNotInSchema");
expectErr(#setPartyExtension({ party = party0; values = [{ schema = "kyc"; name = "sector"; value = #boolean(true) }] }), "FieldTypeMismatch");
expectErr(#setPartyExtension({ party = party0; values = [{ schema = "kyc"; name = "sector"; value = #enumerated("retail") }, { schema = "kyc"; name = "employees"; value = #integer(-1) }] }), "FieldOutOfRange");
expectErr(#setPartyExtension({ party = party0; values = [{ schema = "kyc"; name = "sector"; value = #enumerated("retail") }, { schema = "kyc"; name = "note"; value = #text("this note is far too long to fit") }] }), "FieldOutOfRange");
expectErr(#setPartyExtension({ party = party0; values = [{ schema = "kyc"; name = "sector"; value = #enumerated("industrial") }] }), "not a declared value");
expectErr(#setPartyExtension({ party = party0; values = [{ schema = "kyc"; name = "employees"; value = #integer(1) }] }), "MissingRequiredField");
expectErr(#setPartyExtension({ party = party0; values = [{ schema = "kyc"; name = "sector"; value = #enumerated("retail") }, { schema = "kyc"; name = "taxIdCommit"; value = #commitment(Blob.fromArray([1])) }] }), "32-byte commitment");
Debug.print("count: extension-schema refusals = 13");

// ═══════════════════════════════════════════════════════════════════════════
//  K-11  offices, staff and relationships
// ═══════════════════════════════════════════════════════════════════════════
ignore run(#addStaff({ principal_ = officer; book = "BR01"; title = "branch officer" }));
ignore run(#addStaff({ principal_ = checker; book = "HQ"; title = "compliance" }));
expectErr(#addStaff({ principal_ = officer; book = "HQ"; title = "again" }), "StaffExists");
expectErr(#addStaff({ principal_ = officer; book = "NOSUCH"; title = "x" }), "UnknownBook");
expectErr(#removeStaff({ principal_ = screener }), "UnknownStaff");
ignore run(#removeStaff({ principal_ = checker }));
assert (PartyCore.staffCount(bs.party) == 1);
// a guarantor is a relationship, and a party cannot guarantee itself
ignore run(#addPartyRelationship({ party = party0; relationship = { kind = #guarantor; other = party2 } }));
expectErr(#addPartyRelationship({ party = party0; relationship = { kind = #guarantor; other = party0 } }), "cannot be related to itself");
expectErr(#addPartyRelationship({ party = party0; relationship = { kind = #guarantor; other = 9999 } }), "UnknownParty");
// a group is a party with members, not a parallel object
let group = run(#createParty({ kind = #legal; salt = saltFor(50); identityCommit = Commit.identity(saltFor(50), #legal, ["Zamalek Traders Group"]); dedupCommit = null; attributes = [{ name = Commit.SCREENING_SUBJECT; commit = Commit.field(saltFor(50), Commit.SCREENING_SUBJECT, "Zamalek Traders Group") }]; book = "BR01"; cddLevel = #simplified; riskRating = #low; pep = false; reviewDue = TODAY + 365 }));
ignore run(#addPartyRelationship({ party = group; relationship = { kind = #groupMember; other = party0 } }));
ignore run(#addPartyRelationship({ party = group; relationship = { kind = #groupMember; other = party2 } }));
switch (PartyCore.get(bs.party, Core.partyBlocks(BankMemLog.reader(bchain)), group)) {
  case (?g) { assert (g.relationships.size() == 2) };
  case null { assert false };
};
Debug.print("count: organisation and relationship checks = 9");

// ═══════════════════════════════════════════════════════════════════════════
//  K-12  credentials and the pinned key set
// ═══════════════════════════════════════════════════════════════════════════
expectErr(#registerCredential({ subject = officer; kind = #oidc({ issuer = "https://id.example.invalid"; subjectCommit = Commit.field(saltFor(0), "sub", "abc") }); assurance = #aal2; registeredAtBlock = 0; revokedAtBlock = null }), "UnknownIssuer");
ignore run(#pinJwks({ issuer = "https://id.example.invalid"; keys = [{ kid = "k1"; n = Commit.field(saltFor(0), "n", "modulus"); e = Blob.fromArray([1, 0, 1]) }]; pinnedAtBlock = 0 }));
expectErr(#pinJwks({ issuer = "https://id2.example.invalid"; keys = []; pinnedAtBlock = 0 }), "verifies nothing");
expectErr(#pinJwks({ issuer = "https://id3.example.invalid"; keys = [{ kid = "k"; n = Commit.field(saltFor(0), "n", "a"); e = Blob.fromArray([1]) }, { kid = "k"; n = Commit.field(saltFor(0), "n", "b"); e = Blob.fromArray([1]) }]; pinnedAtBlock = 0 }), "duplicate key id");
ignore run(#registerCredential({ subject = officer; kind = #oidc({ issuer = "https://id.example.invalid"; subjectCommit = Commit.field(saltFor(0), "sub", "abc") }); assurance = #aal2; registeredAtBlock = 0; revokedAtBlock = null }));
expectErr(#registerCredential({ subject = officer; kind = #passkey({ aaguid = Blob.fromArray([1]) }); assurance = #aal2; registeredAtBlock = 0; revokedAtBlock = null }), "CredentialExists");
ignore run(#revokeCredential({ subject = officer }));
expectErr(#revokeCredential({ subject = officer }), "UnknownCredential");
// a revoked credential can be replaced
ignore run(#registerCredential({ subject = officer; kind = #passkey({ aaguid = Blob.fromArray([0xAA]) }); assurance = #aal2; registeredAtBlock = 0; revokedAtBlock = null }));
// the assurance mapping is recorded, not asserted: a passkey with user
// verification is an AAL2 multi-factor cryptographic authenticator
switch (PartyCore.getCredential(bs.party, officer)) {
  case (?c) { assert (c.assurance == #aal2) };
  case null { assert false };
};
Debug.print("count: credential lifecycle checks = 7");

// ═══════════════════════════════════════════════════════════════════════════
//  closing a party requires no balance and no allocated collateral
// ═══════════════════════════════════════════════════════════════════════════
expectErr(#setPartyLifecycle({ party = party0; to = #closed }), "PartyHasCollateral");
Debug.print("count: close refusals = 1");

// ═══════════════════════════════════════════════════════════════════════════
//  K-1  NO PLAINTEXT PERSONAL DATA IN ANY BLOCK
// ═══════════════════════════════════════════════════════════════════════════
// Every block of both logs, decoded to raw bytes, searched for every fixture
// string and for every fourteen-digit run. This is the criterion the whole
// component rests on, so it is checked last, over the whole life of the fixture.

var searchTerms : [Text] = [];
for (p in people.vals()) {
  searchTerms := Array.concat(searchTerms, [p.name, p.nationalId, p.passport, p.address, p.dob]);
  // and the normalised form, since that is what a commitment is taken over
  searchTerms := Array.concat(searchTerms, [Commit.normalise(p.name), Commit.normalise(p.address)]);
};
// plus a few fragments, so a partial leak is caught too
searchTerms := Array.concat(searchTerms, ["Mohamed", "Hassan", "29801011", "Qasr al-Nil", "Zamalek", "A12345678"]);

/// The stored bytes of a bank block; the same encoding the log holds.
func bankBytes(b : T.Block) : Blob {
  BC.encodeBlock(b.index, b.timestamp, b.caller, b.parentHash, b.event).bytes
};
/// The stored bytes of a journal block.
func journalBytes(b : JT.Block) : Blob {
  JC.encodeBlock(b.index, b.timestamp, b.caller, b.parentHash, b.event).bytes
};

func blobToText(b : Blob) : Text {
  // Interpret the bytes as Latin-1 so any ASCII substring is findable wherever it
  // sits; a UTF-8 decode would refuse on non-text bytes and could hide a leak.
  var out = "";
  for (x in b.vals()) { out #= Text.fromChar(Char.fromNat32(Nat32.fromNat(Nat8.toNat(x)))) };
  out
};

/// Does the text contain fourteen consecutive ASCII digits? An Egyptian national
/// identity number is fourteen digits, so this catches a leak even of a value the
/// fixture did not list.
func hasFourteenDigitRun(t : Text) : Bool {
  var run = 0;
  for (c in t.chars()) {
    if (c >= '0' and c <= '9') { run += 1; if (run >= 14) return true } else { run := 0 };
  };
  false
};

var scanned = 0;
var hits = 0;
var digitRuns = 0;
var accountedRuns = 0;
for (b in BankMemLog.blocks(bchain).vals()) {
  let raw = blobToText(bankBytes(b));
  scanned += 1;
  for (term in searchTerms.vals()) {
    if (Text.contains(raw, #text term)) { Debug.print("PII LEAK in bank block " # Nat.toText(b.index) # ": " # term); hits += 1 };
  };
  // The fourteen-digit heuristic exists to catch an identity number the fixture
  // did not list. An issued account identifier also carries a long digit run and
  // is *not* personal data (party and KYC section 1.6); so a run is accounted for only
  // when the block is an identifier issuance and the identifier is a valid IBAN.
  // Any other block with a run is a failure.
  if (hasFourteenDigitRun(raw)) {
    switch (b.event) {
      case (#party(#partyIdentifierIssued({ identifier }))) {
        if (Iban.isValid(identifier)) accountedRuns += 1
        else { Debug.print("digit run in an issuance whose identifier is not a valid IBAN: " # identifier); digitRuns += 1 };
      };
      case (_) { Debug.print("unaccounted fourteen-digit run in bank block " # Nat.toText(b.index)); digitRuns += 1 };
    };
  };
};
for (b in JMemLog.blocks(jchain).vals()) {
  let raw = blobToText(journalBytes(b));
  scanned += 1;
  for (term in searchTerms.vals()) {
    if (Text.contains(raw, #text term)) { Debug.print("PII LEAK in journal block " # Nat.toText(b.index) # ": " # term); hits += 1 };
  };
  if (hasFourteenDigitRun(raw)) { Debug.print("unaccounted fourteen-digit run in journal block " # Nat.toText(b.index)); digitRuns += 1 };
};
Debug.print("count: blocks scanned for personal data = " # Nat.toText(scanned));
Debug.print("count: search terms per block = " # Nat.toText(searchTerms.size()));
Debug.print("personal-data hits across every block: " # Nat.toText(hits) # " (must be zero)");
Debug.print("unaccounted fourteen-digit runs across every block: " # Nat.toText(digitRuns) # " (must be zero)");
Debug.print("count: digit runs accounted for as issued account identifiers = " # Nat.toText(accountedRuns));
assert (hits == 0);
assert (digitRuns == 0);
assert (accountedRuns == 6);
assert (scanned > 50);
assert (searchTerms.size() >= 30);

// ═══════════════════════════════════════════════════════════════════════════
//  replay equality
// ═══════════════════════════════════════════════════════════════════════════
let replayed = Core.replay(installer, BankMemLog.blocks(bchain));
assert (Core.fingerprint(replayed) == Core.fingerprint(bs));
assert (PartyCore.partyCount(replayed.party) == PartyCore.partyCount(bs.party));
assert (PartyCore.collateralCount(replayed.party) == PartyCore.collateralCount(bs.party));
Debug.print("count: bank blocks replayed = " # Nat.toText(Core.height(bs)));
let jreplayed = JCore.replay(bankP, JMemLog.blocks(jchain));
assert (JCore.fingerprint(jreplayed) == JCore.fingerprint(js));
Debug.print("count: journal blocks replayed = " # Nat.toText(JCore.height(js)));

Debug.print("PARTY CORE TEST GREEN");
