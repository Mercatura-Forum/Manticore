// BankCore.test.mo — the four-eyes state machine, adversarially.
//
// The battery for proposal entitlements and maker-checker's criteria A-2, A-3, A-4, A-6 … A-14 on the pure
// core. What is proved here, and what each check exists to stop:
//
//   * a maker's proposal changes nothing a command would change (A-6);
//   * the approval that completes the policy executes in the same step, and
//     there is no state in which a command is approved and unexecuted (A-7);
//   * the bytes the checker approved are the bytes that execute: a tampered
//     recorded command is refused, not substituted (A-8);
//   * self-approval and double-approval are impossible even when the maker holds
//     the checker role (A-9);
//   * N-of-M, expiry, and an unsatisfiable policy refused when written (A-10);
//   * no permission in the catalogue lets a dual command through single-handed,
//     the bank administrator included (A-11);
//   * dual control governs its own configuration and the activation heights (A-12);
//   * an override needs a distinct permission and an eligible witness, and opens
//     a review that does not go away (A-13);
//   * the consumed figures are the fold of the log: replay reproduces them (A-4);
//   * an authority refusal is recorded; a malformed-input refusal is not (the
//     line BankCore's header draws).
// engine: wasi-only — the battery fingerprints the whole state on every refusal.

import Debug "mo:core/Debug";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Nat64 "mo:core/Nat64";
import Text "mo:core/Text";
import Blob "mo:core/Blob";
import Array "mo:core/Array";
import List "mo:core/List";
import Principal "mo:core/Principal";

import JT "mo:journal/JournalTypes";
import JCore "mo:journal/JournalCore";

import T "../src/bank/BankTypes";
import C "../src/bank/BankCanonical";
import Core "../src/bank/BankCore";
import P "../src/bank/Permissions";
import E "../src/bank/Entitlements";
import BankMemLog "support/BankMemLog";
import Reconstruct "../src/bank/Reconstruct";
import JMemLog "support/JournalMemLog";

// ─── fixtures ────────────────────────────────────────────────────────────────

let bankP = Principal.fromBlob("\BA\01");      // the canister itself
let installer = Principal.fromBlob("\1A\01");
let maker = Principal.fromBlob("\2A\01");
let checker1 = Principal.fromBlob("\3A\01");
let checker2 = Principal.fromBlob("\3A\02");
let outsider = Principal.fromBlob("\0F\0F");
let teller2 = Principal.fromBlob("\2A\02");   // holds only the book-scoped teller role
let anon = Principal.fromText("2vxsx-fae");

let SECOND : Nat64 = 1_000_000_000;
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

/// Commit a planned command the way Bank.mo's executeCommand does.
func execute(authority : Principal, command : T.Command, authorityIndex : Nat) : [Nat] {
  switch (Core.planCommand(bs, BankMemLog.reader(bchain), js, JMemLog.reader(jchain), bankP, clock, command, authorityIndex)) {
    case (#err(e)) { Debug.print("plan failed: " # debug_show (e)); assert false; [] };
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

/// Genesis, exactly as Bank.mo does it: the bank is the journal's poster, block 0
/// records the administrator, then books, roles, grants and policies.
ignore jcommit(switch (JCore.prepareAddPoster(js, bankP, bankP)) { case (#ok(e)) e; case (#err(e)) { Debug.print(debug_show (e)); assert false; #posterAdded({ poster = bankP }) } });
ignore bcommit(installer, #bankAdminTransferred({ admin = installer }));

func genesis(command : T.Command) { ignore execute(installer, command, Core.height(bs)) };

genesis(#openBook({ id = "HQ"; name = "Head office"; parent = null }));
genesis(#openBook({ id = "BR01"; name = "Branch 1"; parent = ?"HQ" }));
genesis(#openBook({ id = "BR02"; name = "Branch 2"; parent = ?"HQ" }));
genesis(#defineRole({ id = "checker"; name = "Checker"; permissions = ["command.approve", "command.reject", "override.review"] }));
genesis(#defineRole({
  id = "teller"; name = "Teller";
  permissions = ["command.create", "command.perform", "journal.entry.create", "journal.entry.reverse"];
}));
genesis(#defineRole({
  id = "config"; name = "Configuration";
  permissions = [
    "command.create", "command.perform", "role.create", "role.grant", "role.revoke",
    "policy.update", "policy.delete", "book.create", "book.close", "bank.admin.update",
    "feature.activate", "journal.currency.create", "journal.account.create",
    "journal.account.close", "journal.period.create", "journal.period.close",
    "journal.activation.update", "journal.leadsheet.update", "journal.poster.create",
    "journal.poster.delete", "journal.posterscope.update", "journal.businessdate.update",
    "journal.calendar.update", "journal.calendar.authority",
  ];
}));
genesis(#defineRole({ id = "breaker"; name = "Break glass"; permissions = ["command.breakGlass", "command.create", "journal.entry.create"] }));

let tellerScope : T.Scope = {
  books = ?["BR01"];
  currencies = ?["EGP"];
  ceiling = ?[{ currency = "EGP"; amount = 50_000_00 }];
  dailyLimit = ?[{ currency = "EGP"; amount = 120_000_00 }];
};
genesis(#grantRole({ subject = maker; role = "teller"; scope = tellerScope }));
genesis(#grantRole({ subject = maker; role = "config"; scope = E.emptyScope() }));
genesis(#grantRole({ subject = teller2; role = "teller"; scope = tellerScope }));
genesis(#grantRole({ subject = checker1; role = "checker"; scope = E.emptyScope() }));
genesis(#grantRole({ subject = checker2; role = "checker"; scope = E.emptyScope() }));
// Every dual-by-default permission gets a policy, so the table is complete.
var policiesWritten = 0;
for (perm in P.catalogue().vals()) {
  if (perm.dualByDefault) {
    genesis(#setDualPolicy({ permission = perm.id; required = 1; eligibleRole = "checker"; ttlSeconds = 3600 }));
    policiesWritten += 1;
  };
};
Debug.print("count: dual-authorisation policies written at genesis = " # Nat.toText(policiesWritten));
assert (policiesWritten == P.dualByDefaultCount());

// the books the journal needs, through the four-eyes path below
func proposeOk(caller : Principal, command : T.Command, why : Text) : Nat {
  switch (Core.prepareProposal(bs, BankMemLog.reader(bchain), js, JMemLog.reader(jchain), bankP, caller, clock, command, why)) {
    case (#ok(out)) bcommit(caller, out.event).index;
    case (#err(r)) { Debug.print("propose failed: " # debug_show (r.error)); assert false; 0 };
  }
};
func approveOk(caller : Principal, index : Nat) : { executed : Bool; postings : [Nat] } {
  switch (Core.prepareApprove(bs, js, JMemLog.reader(jchain), BankMemLog.reader(bchain), bankP, caller, clock, index)) {
    case (#err(r)) { Debug.print("approve failed: " # debug_show (r.error)); assert false; { executed = false; postings = [] } };
    case (#ok(out)) {
      ignore bcommit(caller, out.approval);
      switch (out.execute) {
        case null { { executed = false; postings = [] } };
        case (?ex) {
          let postings = execute(ex.maker, ex.command, ex.proposal);
          ignore bcommit(caller, #commandExecuted({ proposal = ex.proposal; commandHash = ex.commandHash; postings; charge = Core.chargeOf(bs, ex.command) }));
          { executed = true; postings }
        };
      }
    };
  }
};
func fourEyes(command : T.Command) : { executed : Bool; postings : [Nat] } {
  let p = proposeOk(maker, command, "setup");
  approveOk(checker1, p)
};

ignore fourEyes(#journalRegisterCurrency({ code = "EGP"; minorUnits = 2 }));
ignore fourEyes(#journalOpenAccount({ code = "1001"; name = "Cash"; normalSide = #debit; category = #asset; constraint = #none }));
ignore fourEyes(#journalOpenAccount({ code = "2110"; name = "Customer deposits"; normalSide = #credit; category = #liability; constraint = #none }));
ignore fourEyes(#journalOpenAccount({ code = "4100"; name = "Fee income"; normalSide = #credit; category = #income; constraint = #none }));
ignore fourEyes(#journalOpenPeriod({ id = "2026-09"; start = SEP1; end = SEP30 }));
ignore fourEyes(#journalSetActivationHeight({ height = 0 }));
assert (JCore.isActive(js));
Debug.print("count: journal configuration commands through four eyes = 6");

// ─── helpers for money ──────────────────────────────────────────────────────
var keyCounter : Nat = 0;
func key() : Blob { keyCounter += 1; Blob.fromArray([0xEE, Nat8.fromNat(keyCounter / 256), Nat8.fromNat(keyCounter % 256)]) };
func entry(book : Text, amount : Nat) : T.Command {
  #postManualEntry({
    book; postingDate = TODAY; valueDate = TODAY; period = "2026-09";
    legs = [
      { account = "1001"; subledger = null; side = #debit; currency = "EGP"; amount },
      { account = "2110"; subledger = null; side = #credit; currency = "EGP"; amount },
    ];
    narration = "manual entry"; idempotencyKey = key(); correctionOf = null;
  })
};

func longText(n : Nat) : Text {
  var t = "";
  var i = 0;
  while (i < n) { t #= "x"; i += 1 };
  t
};

func fp() : Blob { Core.fingerprint(bs) };
func jfp() : Blob { JCore.fingerprint(js) };
func heights() : (Nat, Nat) { (Core.height(bs), JCore.height(js)) };

// ═══════════════════════════════════════════════════════════════════════════
//  A-6  the maker's command does not execute
// ═══════════════════════════════════════════════════════════════════════════
let beforeJ = jfp();
let (bh0, jh0) = heights();
let prop1 = proposeOk(maker, entry("BR01", 10_000_00), "customer deposit");
assert (JCore.height(js) == jh0);            // no journal block
assert (jfp() == beforeJ);                   // no journal state change
assert (Core.height(bs) == bh0 + 1);         // exactly one bank block
switch (Core.getProposal(bs, BankMemLog.reader(bchain), prop1)) {
  case (?v) { switch (v.status) { case (#awaitingApproval(x)) assert (x.approvals.size() == 0); case (_) { assert false } } };
  case null { assert false };
};
// Not a `count:` line: the coverage gate fails a count of zero, and zero is the
// correct answer here. The count below is the number of properties checked.
Debug.print("journal blocks created by a proposal: 0 (journal height and fingerprint unchanged)");
Debug.print("count: proposal-creates-no-posting properties checked = 4");

// ═══════════════════════════════════════════════════════════════════════════
//  A-9  self-approval, and double approval
// ═══════════════════════════════════════════════════════════════════════════
// give the maker the checker role too: it still cannot approve its own proposal
genesis(#grantRole({ subject = maker; role = "checker"; scope = E.emptyScope() }));
var selfChecks = 0;
func expectApproveErr(caller : Principal, index : Nat, want : Text) {
  let f = fp(); let jf = jfp(); let h = heights();
  switch (Core.prepareApprove(bs, js, JMemLog.reader(jchain), BankMemLog.reader(bchain), bankP, caller, clock, index)) {
    case (#ok(_)) { Debug.print("expected approve error " # want); assert false };
    case (#err(r)) {
      let got = debug_show (r.error);
      if (not Text.contains(got, #text want)) { Debug.print("wanted " # want # " got " # got); assert false };
    };
  };
  assert (fp() == f and jfp() == jf and heights() == h);
};
expectApproveErr(maker, prop1, "SelfApproval"); selfChecks += 1;
expectApproveErr(outsider, prop1, "NotEligibleChecker"); selfChecks += 1;
expectApproveErr(anon, prop1, "NotEligibleChecker"); selfChecks += 1;
Debug.print("count: ineligible approval attempts refused = " # Nat.toText(selfChecks));
assert (selfChecks == 3);

// ═══════════════════════════════════════════════════════════════════════════
//  A-7  the completing approval executes in the same step
// ═══════════════════════════════════════════════════════════════════════════
let r1 = approveOk(checker1, prop1);
assert r1.executed;
assert (r1.postings.size() == 1);
switch (Core.getProposal(bs, BankMemLog.reader(bchain), prop1)) {
  case (?v) { switch (v.status) { case (#executed(x)) { assert (x.postings == r1.postings) }; case (_) { Debug.print("not executed"); assert false } } };
  case null { assert false };
};
// the posting names the proposal as its authority
switch (JCore.postingView(js, JMemLog.reader(jchain), r1.postings[0])) {
  case (?pv) { assert (pv.record.sourceRef.kind == "manual" and pv.record.sourceRef.id == Nat.toText(prop1)) };
  case null { assert false };
};
// no proposal is ever in an approved-and-unexecuted state
var awaitingWithFullApprovals = 0;
for (v in Core.listProposals(bs, BankMemLog.reader(bchain)).vals()) {
  switch (v.status) {
    case (#awaitingApproval(x)) { if (x.approvals.size() >= v.required) awaitingWithFullApprovals += 1 };
    case (_) {};
  };
};
Debug.print("proposals approved but unexecuted: " # Nat.toText(awaitingWithFullApprovals) # " (must be zero)");
Debug.print("count: proposals examined for an approved-and-unexecuted state = " # Nat.toText(Core.proposalCount(bs)));
assert (awaitingWithFullApprovals == 0);
assert (Core.proposalCount(bs) > 0);
// a resolved proposal cannot be approved again
expectApproveErr(checker2, prop1, "ProposalNotAwaiting");
Debug.print("count: re-approval of a resolved proposal refused = 1");

// ═══════════════════════════════════════════════════════════════════════════
//  A-8  the approved bytes execute, or nothing does
// ═══════════════════════════════════════════════════════════════════════════
// A proposal whose recorded command hash does not match the command must be
// refused. The only way to create that state is to write a block with a wrong
// hash, which is what a store that could be altered would produce.
let tamperProposals = List.empty<Nat>();
let baseEntry = entry("BR01", 1_000_00);
var mutationRefusals = 0;
var mutants = 0;
for (delta in [1, 2, 3, 5, 8, 13, 21, 34, 55, 89, 144, 233, 377, 610, 987, 1597, 2584, 4181, 6765, 10946].vals()) {
  let bad : T.Event = #commandProposed({
    command = ?baseEntry;
    commandHash = Blob.fromArray(Array.tabulate<Nat8>(32, func(i) { Nat8.fromNat((i + delta) % 256) }));
    permission = P.commandName(baseEntry); book = null;
    maker; required = 1; eligibleRole = "checker";
    expiresAt = clock + 3600 * SECOND; justification = "tampered";
  });
  let idx = bcommit(maker, bad).index;
  List.add(tamperProposals, idx);
  mutants += 1;
  let f = fp(); let jf = jfp(); let h = heights();
  switch (Core.prepareApprove(bs, js, JMemLog.reader(jchain), BankMemLog.reader(bchain), bankP, checker1, clock, idx)) {
    case (#err(r)) {
      switch (r.error) {
        case (#CommandHashMismatch(d)) { assert (d.recomputed == C.commandHash(baseEntry)); mutationRefusals += 1 };
        case (other) { Debug.print("wanted CommandHashMismatch, got " # debug_show (other)); assert false };
      };
    };
    case (#ok(_)) { Debug.print("a tampered command was approved"); assert false };
  };
  assert (fp() == f and jfp() == jf and heights() == h);
};
Debug.print("count: tampered command hashes refused at approval = " # Nat.toText(mutationRefusals));
assert (mutationRefusals == mutants and mutants == 20);
// the untampered command of the same shape approves and executes
let good = proposeOk(maker, entry("BR01", 1_000_00), "good");
assert ((approveOk(checker1, good)).executed);
Debug.print("count: untampered commands of the same shape executed = 1");

// ═══════════════════════════════════════════════════════════════════════════
//  A-3  scope on the operation's own data
// ═══════════════════════════════════════════════════════════════════════════
var scopeRefusals = 0;
func expectProposeErr(caller : Principal, command : T.Command, want : Text) {
  let f = fp(); let jf = jfp(); let h = heights();
  switch (Core.prepareProposal(bs, BankMemLog.reader(bchain), js, JMemLog.reader(jchain), bankP, caller, clock, command, "attempt")) {
    case (#ok(_)) { Debug.print("expected propose error " # want); assert false };
    case (#err(r)) {
      let got = debug_show (r.error);
      if (not Text.contains(got, #text want)) { Debug.print("wanted " # want # " got " # got); assert false };
    };
  };
  assert (fp() == f and jfp() == jf and heights() == h);
};
expectProposeErr(maker, entry("BR02", 1_00), "OutsideBookScope"); scopeRefusals += 1;
expectProposeErr(maker, entry("BR01", 50_000_01), "OverCeiling"); scopeRefusals += 1;
expectProposeErr(outsider, entry("BR01", 1_00), "NoGrant"); scopeRefusals += 1;
// a 128-leg batch totalling over the ceiling whose individual legs are far under
let splitLegs = Array.tabulate<JT.Leg>(128, func(i) {
  if (i % 2 == 0) { { account = "1001"; subledger = null; side = #debit; currency = "EGP"; amount = 800_00 } }
  else { { account = "2110"; subledger = null; side = #credit; currency = "EGP"; amount = 800_00 } }
});
expectProposeErr(maker, #postManualEntry({
  book = "BR01"; postingDate = TODAY; valueDate = TODAY; period = "2026-09";
  legs = splitLegs; narration = "split"; idempotencyKey = key(); correctionOf = null;
}), "OverCeiling");
scopeRefusals += 1;
Debug.print("count: scope refusals on the operation's own data = " # Nat.toText(scopeRefusals));
assert (scopeRefusals == 4);

// ═══════════════════════════════════════════════════════════════════════════
//  A-4  the daily limit is the fold of the log
// ═══════════════════════════════════════════════════════════════════════════
// Two manual entries have executed for this maker on this day: 10,000.00 and
// 1,000.00. The twenty tampered proposals were refused at approval, so they
// consumed nothing — which is itself worth asserting, because a limit charged at
// proposal time rather than at execution would read 31,000.00 here.
let usedSoFar = Core.consumedFor(bs, maker, "EGP", TODAY);
Debug.print("count: consumed minor units so far = " # Nat.toText(usedSoFar));
assert (usedSoFar == 10_000_00 + 1_000_00);
// Spend up to the limit. The per-operation ceiling is 50,000.00, so the
// remaining 109,000.00 takes three operations — which also proves the daily
// limit accumulates across operations rather than being a per-operation bound.
var remaining : Nat = 120_000_00 - usedSoFar;
var topUps = 0;
while (remaining > 0) {
  let amount = if (remaining > 50_000_00) 50_000_00 else remaining;
  let pN = proposeOk(maker, entry("BR01", amount), "to the limit");
  assert ((approveOk(checker1, pN)).executed);
  remaining -= amount;
  topUps += 1;
};
Debug.print("count: operations used to reach the daily limit = " # Nat.toText(topUps));
assert (topUps == 3);
assert (Core.consumedFor(bs, maker, "EGP", TODAY) == 120_000_00);
// one minor unit more is refused
expectProposeErr(maker, entry("BR01", 1), "OverDailyLimit");
// a different day is unaffected
switch (Core.prepareProposal(bs, BankMemLog.reader(bchain), js, JMemLog.reader(jchain), bankP, maker, clock, #postManualEntry({
  book = "BR01"; postingDate = TODAY - 1; valueDate = TODAY - 1; period = "2026-09";
  legs = [
    { account = "1001"; subledger = null; side = #debit; currency = "EGP"; amount = 1_000_00 },
    { account = "2110"; subledger = null; side = #credit; currency = "EGP"; amount = 1_000_00 },
  ];
  narration = "yesterday"; idempotencyKey = key(); correctionOf = null;
}), "other day")) {
  case (#ok(_)) {};
  case (#err(r)) { Debug.print("another day was refused: " # debug_show (r.error)); assert false };
};
Debug.print("count: daily-limit boundary checks = 3");

// replay reproduces the consumed figures exactly
let replayed = Core.replay(installer, BankMemLog.blocks(bchain));
assert (Core.fingerprint(replayed) == fp());
assert (Core.consumedFor(replayed, maker, "EGP", TODAY) == 120_000_00);
// and an independent walk of the blocks agrees
var independent : Nat = 0;
for (b in BankMemLog.blocks(bchain).vals()) {
  switch (b.event) {
    case (#commandExecuted(x)) {
      switch (Core.getProposal(bs, BankMemLog.reader(bchain), x.proposal)) {
        case (?v) {
          switch (v.command) {
            case (?#postManualEntry(m)) {
              if (Principal.equal(v.maker, maker) and m.postingDate == TODAY) {
                for ((ccy, amt) in E.legTotals(m.legs).vals()) { if (Text.equal(ccy, "EGP")) independent += amt };
              };
            };
            case (_) {};
          };
        };
        case null {};
      };
    };
    case (_) {};
  };
};
Debug.print("count: independently folded consumption (minor units) = " # Nat.toText(independent));
assert (independent == 120_000_00);

// ═══════════════════════════════════════════════════════════════════════════
//  A-10  N-of-M, expiry, and an unsatisfiable policy
// ═══════════════════════════════════════════════════════════════════════════
// six eyes on the manual entry
ignore fourEyes(#setDualPolicy({ permission = "journal.entry.create"; required = 2; eligibleRole = "checker"; ttlSeconds = 3600 }));
// the maker's limit is spent, so use a fresh day for the six-eyes case
func entryOn(book : Text, day : Nat, amount : Nat) : T.Command {
  #postManualEntry({
    book; postingDate = day; valueDate = day; period = "2026-09";
    legs = [
      { account = "1001"; subledger = null; side = #debit; currency = "EGP"; amount },
      { account = "2110"; subledger = null; side = #credit; currency = "EGP"; amount },
    ];
    narration = "six eyes"; idempotencyKey = key(); correctionOf = null;
  })
};
let p3 = proposeOk(maker, entryOn("BR01", TODAY - 2, 2_000_00), "six eyes");
let firstApproval = approveOk(checker1, p3);
assert (not firstApproval.executed);
// the same checker cannot approve twice
expectApproveErr(checker1, p3, "AlreadyApproved");
let secondApproval = approveOk(checker2, p3);
assert secondApproval.executed;
Debug.print("count: six-eyes approvals required and given = 2");

// a policy requiring more approvals than there are holders is refused when written
var policyRefusals = 0;
func expectPolicyErr(command : T.Command, want : Text) {
  switch (Core.planCommand(bs, BankMemLog.reader(bchain), js, JMemLog.reader(jchain), bankP, clock, command, Core.height(bs))) {
    case (#ok(_)) { Debug.print("expected policy error " # want); assert false };
    case (#err(e)) {
      let got = debug_show (e);
      if (Text.contains(got, #text want)) policyRefusals += 1 else { Debug.print("wanted " # want # " got " # got); assert false };
    };
  };
};
expectPolicyErr(#setDualPolicy({ permission = "journal.entry.create"; required = 8; eligibleRole = "checker"; ttlSeconds = 3600 }), "only");
expectPolicyErr(#setDualPolicy({ permission = "no.such.permission"; required = 1; eligibleRole = "checker"; ttlSeconds = 3600 }), "unknown permission");
expectPolicyErr(#setDualPolicy({ permission = "journal.entry.create"; required = 1; eligibleRole = "nosuchrole"; ttlSeconds = 3600 }), "unknown role");
expectPolicyErr(#setDualPolicy({ permission = "journal.entry.create"; required = 0; eligibleRole = "checker"; ttlSeconds = 3600 }), "at least one");
expectPolicyErr(#setDualPolicy({ permission = "journal.entry.create"; required = 1; eligibleRole = "checker"; ttlSeconds = 1 }), "shorter than the minimum");
expectPolicyErr(#setDualPolicy({ permission = "journal.entry.create"; required = 1; eligibleRole = "checker"; ttlSeconds = T.MAX_PROPOSAL_TTL_SECONDS + 1 }), "exceeds the maximum");
// a money-moving permission's policy may not be cleared
expectPolicyErr(#clearDualPolicy({ permission = "journal.entry.create" }), "money-moving");
// Revoking a grant a policy depends on is refused once it would leave too few
// holders. Three principals hold `checker` at this point (the maker was given it
// for the self-approval check), and the manual-entry policy needs two, so the
// first revocation is allowed and the second is not.
assert (Core.roleHolderCount(bs, "checker") == 3);
ignore fourEyes(#revokeRole({ subject = maker; role = "checker" }));
assert (Core.roleHolderCount(bs, "checker") == 2);
expectPolicyErr(#revokeRole({ subject = checker1; role = "checker" }), "would leave too few holders");
Debug.print("count: unsatisfiable or unsafe policy changes refused = " # Nat.toText(policyRefusals));
assert (policyRefusals == 8);

// expiry: a proposal past its lifetime cannot be approved and is recorded expired
let p4 = proposeOk(maker, entryOn("BR01", TODAY - 3, 1_00), "will expire");
let savedClock = clock;
clock := clock + 7200 * SECOND;
expectApproveErr(checker1, p4, "ProposalExpired");
// The twenty tampered proposals are also open and also past their lifetime, so
// the sweep returns a batch; it must include p4, and sweeping until it is empty
// must close every one of them. The sweep is bounded per call, which is what the
// loop exercises.
var sweepBatches = 0;
var sweptTotal = 0;
var sawP4 = false;
label sweeping loop {
  let batch = Core.expiredProposals(bs, clock, 10);
  if (batch.size() == 0) break sweeping;
  for (idx in batch.vals()) {
    if (idx == p4) sawP4 := true;
    ignore bcommit(bankP, Core.expiryEvent(idx));
    sweptTotal += 1;
  };
  sweepBatches += 1;
};
Debug.print("count: expiry sweep batches = " # Nat.toText(sweepBatches));
Debug.print("count: proposals recorded expired = " # Nat.toText(sweptTotal));
assert sawP4;
assert (sweptTotal == 21);   // p4 plus the twenty tampered proposals
assert (sweepBatches == 3);  // bounded at ten per call
switch (Core.getProposal(bs, BankMemLog.reader(bchain), p4)) {
  case (?v) { switch (v.status) { case (#expired) {}; case (_) { Debug.print("not expired"); assert false } } };
  case null { assert false };
};
expectApproveErr(checker1, p4, "ProposalNotAwaiting");
assert (Core.expiredProposals(bs, clock, 10).size() == 0);
assert (Core.openProposalCount(bs) == 0);
clock := savedClock;
Debug.print("count: expiry checks = 5");

// ═══════════════════════════════════════════════════════════════════════════
//  A-11  no bypass: every permission enumerated
// ═══════════════════════════════════════════════════════════════════════════
// For every dual-authorised permission, no principal — the bank administrator
// included — can perform its command single-handed.
var bypassAttempts = 0;
let dualCommands : [T.Command] = [
  #defineRole({ id = "x"; name = "X"; permissions = ["command.read"] }),
  #grantRole({ subject = outsider; role = "checker"; scope = E.emptyScope() }),
  #revokeRole({ subject = checker2; role = "checker" }),
  #setDualPolicy({ permission = "book.create"; required = 1; eligibleRole = "checker"; ttlSeconds = 3600 }),
  #openBook({ id = "BR03"; name = "Branch 3"; parent = ?"HQ" }),
  #closeBook({ id = "BR02" }),
  #transferBankAdmin({ admin = outsider }),
  #setFeatureActivation({ feature = "manual-entry"; height = 0 }),
  #journalRegisterCurrency({ code = "USD"; minorUnits = 2 }),
  #journalOpenAccount({ code = "1002"; name = "Nostro"; normalSide = #debit; category = #asset; constraint = #none }),
  #journalOpenPeriod({ id = "2026-10"; start = SEP30 + 1; end = SEP30 + 30 }),
  #journalAddPoster({ poster = outsider }),
  #journalRollBusinessDate({ day = TODAY }),
  entry("BR01", 1_00),
];
for (command in dualCommands.vals()) {
  for (who in [installer, maker, checker1, checker2, outsider, bankP].vals()) {
    let f = fp(); let jf = jfp(); let h = heights();
    switch (Core.preparePerform(bs, BankMemLog.reader(bchain), js, JMemLog.reader(jchain), bankP, who, clock, command)) {
      case (#ok(_)) { Debug.print("performed a dual command single-handed: " # P.commandName(command)); assert false };
      case (#err(_)) bypassAttempts += 1;
    };
    assert (fp() == f and jfp() == jf and heights() == h);
  };
};
Debug.print("count: single-handed attempts on dual commands refused = " # Nat.toText(bypassAttempts));
assert (bypassAttempts == dualCommands.size() * 6);

// ═══════════════════════════════════════════════════════════════════════════
//  A-12  dual control governs its own configuration and the activation heights
// ═══════════════════════════════════════════════════════════════════════════
// the feature gate is off until a recorded height at or below the bank's own
assert (Core.featureActivation(bs, "manual-entry") == T.ACTIVATION_OFF);
assert (not Core.featureActive(bs, "manual-entry"));
ignore fourEyes(#setFeatureActivation({ feature = "manual-entry"; height = Nat64.fromNat(Core.height(bs)) }));
assert (Core.featureActive(bs, "manual-entry"));
// A height above the bank's own leaves the feature inactive. The target is
// captured before the four-eyes path, which itself appends blocks.
let laterTarget = Nat64.fromNat(Core.height(bs) + 1_000);
ignore fourEyes(#setFeatureActivation({ feature = "later"; height = laterTarget }));
assert (Core.featureActivation(bs, "later") == laterTarget);
assert (not Core.featureActive(bs, "later"));
assert (Nat64.fromNat(Core.height(bs)) < laterTarget);
// switching a feature back off is a recorded act and takes effect at once
ignore fourEyes(#setFeatureActivation({ feature = "manual-entry"; height = T.ACTIVATION_OFF }));
assert (not Core.featureActive(bs, "manual-entry"));
ignore fourEyes(#setFeatureActivation({ feature = "manual-entry"; height = Nat64.fromNat(Core.height(bs)) }));
assert (Core.featureActive(bs, "manual-entry"));
Debug.print("count: feature activation height checks = 6");

// ═══════════════════════════════════════════════════════════════════════════
//  A-13  the override costs what it should
// ═══════════════════════════════════════════════════════════════════════════
genesis(#grantRole({ subject = outsider; role = "breaker"; scope = { E.emptyScope() with books = ?["BR01"]; currencies = ?["EGP"] } }));
var overrideRefusals = 0;
func expectOverrideErr(caller : Principal, command : T.Command, witness : Principal, why : Text, want : Text) {
  let f = fp(); let jf = jfp(); let h = heights();
  switch (Core.prepareOverride(bs, BankMemLog.reader(bchain), js, JMemLog.reader(jchain), bankP, caller, clock, command, witness, why)) {
    case (#ok(_)) { Debug.print("expected override error " # want); assert false };
    case (#err(r)) {
      let got = debug_show (r.error);
      if (Text.contains(got, #text want)) overrideRefusals += 1 else { Debug.print("wanted " # want # " got " # got); assert false };
    };
  };
  assert (fp() == f and jfp() == jf and heights() == h);
};
let ovEntry = entryOn("BR01", TODAY - 4, 500_00);
expectOverrideErr(outsider, ovEntry, outsider, "no witness", "WitnessIsActor");
expectOverrideErr(outsider, ovEntry, maker, "", "requires a justification");
expectOverrideErr(outsider, ovEntry, maker, longText(T.MAX_JUSTIFICATION_BYTES + 1), "exceeds the bound");
// a witness who could not have approved is refused
expectOverrideErr(outsider, ovEntry, installer, "unreachable", "WitnessNotEligible");
// a principal without the break-glass permission cannot override
expectOverrideErr(maker, ovEntry, checker1, "unreachable", "NoGrant");
Debug.print("count: override refusals = " # Nat.toText(overrideRefusals));
assert (overrideRefusals == 5);

// a valid override executes and opens a review
let ovIndex = switch (Core.prepareOverride(bs, BankMemLog.reader(bchain), js, JMemLog.reader(jchain), bankP, outsider, clock, ovEntry, checker1, "checker unreachable at close")) {
  case (#ok(out)) bcommit(outsider, out.event).index;
  case (#err(r)) { Debug.print("override failed: " # debug_show (r.error)); assert false; 0 };
};
let ovPostings = execute(outsider, ovEntry, ovIndex);
ignore bcommit(outsider, #commandExecuted({ proposal = ovIndex; commandHash = C.commandHash(ovEntry); postings = ovPostings; charge = Core.chargeOf(bs, ovEntry) }));
assert (ovPostings.size() == 1);
assert (Core.openOverrideCount(bs) == 1);
// the actor cannot review its own override
switch (Core.prepareReviewOverride(bs, BankMemLog.reader(bchain), outsider, ovIndex, "fine")) {
  case (#err(#SelfApproval(_))) {};
  case (x) { Debug.print("self-review allowed: " # debug_show (x)); assert false };
};
// an empty disposition is refused
switch (Core.prepareReviewOverride(bs, BankMemLog.reader(bchain), checker1, ovIndex, "")) {
  case (#err(_)) {};
  case (#ok(_)) { Debug.print("empty disposition accepted"); assert false };
};
// a reviewer closes it; a second review is refused
switch (Core.prepareReviewOverride(bs, BankMemLog.reader(bchain), checker1, ovIndex, "accepted; rate limit reviewed")) {
  case (#ok(ev)) { ignore bcommit(checker1, ev) };
  case (#err(e)) { Debug.print("review failed: " # debug_show (e)); assert false };
};
assert (Core.openOverrideCount(bs) == 0);
switch (Core.prepareReviewOverride(bs, BankMemLog.reader(bchain), checker2, ovIndex, "again")) {
  case (#err(#OverrideAlreadyReviewed(_))) {};
  case (x) { Debug.print("double review allowed: " # debug_show (x)); assert false };
};
Debug.print("count: override review checks = 4");

// ═══════════════════════════════════════════════════════════════════════════
//  what a refusal records
// ═══════════════════════════════════════════════════════════════════════════
// an authority refusal by an onboarded principal is recordable
assert (Core.recordableRefusal(bs, maker));
// an unknown principal cannot grow the log
assert (not Core.recordableRefusal(bs, outsider) == false);   // outsider now holds `breaker`
let stranger = Principal.fromBlob("\99\99");
assert (not Core.recordableRefusal(bs, stranger));
assert (not Core.recordableRefusal(bs, anon));
// a scope refusal is flagged for recording; a malformed-input refusal is not
switch (Core.prepareProposal(bs, BankMemLog.reader(bchain), js, JMemLog.reader(jchain), bankP, maker, clock, entry("BR02", 1_00), "x")) {
  case (#err(r)) { assert r.record };
  case (#ok(_)) { assert false };
};
switch (Core.prepareProposal(bs, BankMemLog.reader(bchain), js, JMemLog.reader(jchain), bankP, maker, clock, #openBook({ id = "!!bad!!"; name = "x"; parent = null }), "x")) {
  case (#err(r)) { assert (not r.record) };
  case (#ok(_)) { assert false };
};
let refusedBefore = Core.refusedCount(bs);
ignore bcommit(maker, Core.refusalEvent(maker, "journal.entry.create", #OutsideBookScope({ book = "BR02" }), "BR02"));
assert (Core.refusedCount(bs) == refusedBefore + 1);
Debug.print("count: refusal-recording checks = 6");

// ═══════════════════════════════════════════════════════════════════════════
//  the audit view matches the blocks
// ═══════════════════════════════════════════════════════════════════════════
let rows = Core.auditTrail(bs, BankMemLog.reader(bchain));
var processed = 0; var awaiting = 0; var rejected = 0; var expiredRows = 0;
for (r in rows.vals()) {
  if (Text.equal(r.result, "Processed")) processed += 1;
  if (Text.equal(r.result, "Awaiting Approval")) awaiting += 1;
  if (Text.equal(r.result, "Rejected")) rejected += 1;
  if (Text.equal(r.result, "Expired")) expiredRows += 1;
  // every row names its maker and its permission
  assert (Text.size(r.permission) > 0);
};
Debug.print("count: audit rows = " # Nat.toText(rows.size()));
Debug.print("count: audit rows processed = " # Nat.toText(processed));
Debug.print("count: audit rows expired = " # Nat.toText(expiredRows));
assert (rows.size() == Core.proposalCount(bs));
assert (expiredRows == 21);
assert (processed > 10);

// a rejection is recorded and the proposal is closed
let p5 = proposeOk(maker, entryOn("BR01", TODAY - 5, 1_00), "to be rejected");
switch (Core.prepareReject(bs, BankMemLog.reader(bchain), checker1, clock, p5, "wrong account")) {
  case (#ok(ev)) { ignore bcommit(checker1, ev) };
  case (#err(r)) { Debug.print("reject failed: " # debug_show (r.error)); assert false };
};
switch (Core.getProposal(bs, BankMemLog.reader(bchain), p5)) {
  case (?v) { switch (v.status) { case (#rejected(x)) assert (Text.equal(x.reason, "wrong account")); case (_) { assert false } } };
  case null { assert false };
};
expectApproveErr(checker1, p5, "ProposalNotAwaiting");
Debug.print("count: rejection checks = 2");

// ═══════════════════════════════════════════════════════════════════════════
//  replay and the read scope
// ═══════════════════════════════════════════════════════════════════════════
// ═══════════════════════════════════════════════════════════════════════════
//  proposal bodies reconstructed from the act's events (block format 2)
// ═══════════════════════════════════════════════════════════════════════════
// Every executed proposal whose family the reconstruction covers rebuilds to a command that hashes to the
// hash its block keeps; every other executed proposal reports no reconstruction, never a wrong one.
// three acts whose events are their image, through four eyes, so the covered side is exercised here too
ignore fourEyes(#openBook({ id = "BR09"; name = "Ninth branch"; parent = null }));
ignore fourEyes(#defineRole({ id = "auditor"; name = "Auditor"; permissions = ["command.approve"] }));
ignore fourEyes(#setFeatureActivation({ feature = "some.feature"; height = 0 }));
var executedProposals = 0;
var rebuilt = 0;
var notCovered = 0;
var familiesSeen = List.empty<Text>();
var pi = 0;
while (pi < Core.height(bs)) {
  switch (Core.getProposal(bs, BankMemLog.reader(bchain), pi)) {
    case (?v) {
      switch (v.status) {
        case (#executed(_)) {
          executedProposals += 1;
          let ?r = Core.reconstructProposal(bs, BankMemLog.reader(bchain), pi) else { assert false; loop {} };
          let ?body = v.command else { assert false; loop {} };   // the live log still carries every body
          let covered = Array.find<Text>(Reconstruct.families(), func(f) { f == P.commandName(body) }) != null;
          if (covered) {
            assert (r.matches);
            switch (r.command) { case (?c) { assert (C.commandHash(c) == v.commandHash) }; case null { assert false } };
            rebuilt += 1;
            if (not List.contains(familiesSeen, Text.equal, r.family)) List.add(familiesSeen, r.family);
          } else {
            assert (not r.matches);
            notCovered += 1;
          };
        };
        case (_) {};
      };
    };
    case null {};
  };
  pi += 1;
};
Debug.print("count: executed proposals examined for reconstruction = " # Nat.toText(executedProposals));
Debug.print("count: proposal bodies rebuilt from their acts to the kept hash = " # Nat.toText(rebuilt));
Debug.print("count: command families rebuilt = " # Nat.toText(List.size(familiesSeen)));
Debug.print("proposals of families the reconstruction does not cover (bodies carried): " # Nat.toText(notCovered));
assert (rebuilt >= 3 and List.size(familiesSeen) >= 3);

// ═══════════════════════════════════════════════════════════════════════════
//  what a pack keeps of each block (measure 2, §18.3): the body leaves only where it rebuilds
// ═══════════════════════════════════════════════════════════════════════════
// `keptBytes` over every block's stored bytes: the whole block, except for an executed proposal whose
// command the act's events rebuild to the kept hash, which keeps its preimage and hash with the empty
// trailer. What it keeps still decodes to the same block, hash for hash, and a replay over the kept
// blocks alone reaches the fingerprint of the live state: the fold never needed the bodies.
var bodiesDropped = 0;
var blocksKeptWhole = 0;
let keptBlocks = List.empty<T.Block>();
var tamperedFixtures = 0;
label keptWalk for (b in BankMemLog.blocks(bchain).vals()) {
  let raw = C.encodeBlock(b.index, b.timestamp, b.caller, b.parentHash, b.event).bytes;
  let kept = Core.keptBytes(bs, BankMemLog.reader(bchain), b.index, raw);
  // this file also commits proposals whose commandHash is deliberately not the body's (the approve-side
  // mutation refusals above): the encoder never produces such a block, the decoder refuses its trailer,
  // and a pack keeps its bytes untouched
  let ?decoded = C.decodeBlock(kept) else {
    switch (b.event) { case (#commandProposed(x)) { switch (x.command) { case (?c) assert (C.commandHash(c) != x.commandHash); case null assert false } }; case (_) assert false };
    assert (kept == raw);
    tamperedFixtures += 1;
    List.add(keptBlocks, b);
    continue keptWalk;
  };
  assert (decoded.hash == b.hash and decoded.index == b.index and decoded.parentHash == b.parentHash);
  let shouldDrop = switch (b.event) {
    case (#commandProposed(x)) {
      switch (Core.getProposal(bs, BankMemLog.reader(bchain), b.index)) {
        case (?v) { switch (v.status) { case (#executed(_)) { switch (Core.reconstructProposal(bs, BankMemLog.reader(bchain), b.index)) { case (?r) r.matches and x.command != null; case null false } }; case (_) false } };
        case null false;
      }
    };
    case (_) false;
  };
  if (shouldDrop) {
    assert (kept.size() < raw.size());
    let ?parts = C.splitTrailer(raw) else { assert false; loop {} };
    assert (kept == Blob.fromArray(Array.concat<Nat8>(Blob.toArray(parts.head), [0])));
    switch (decoded.event) { case (#commandProposed(y)) assert (y.command == null); case (_) assert false };
    bodiesDropped += 1;
  } else {
    assert (kept == raw and decoded.event == b.event);
    blocksKeptWhole += 1;
  };
  List.add(keptBlocks, decoded);
};
Debug.print("count: proposal bodies a pack drops = " # Nat.toText(bodiesDropped));
Debug.print("count: blocks a pack keeps whole = " # Nat.toText(blocksKeptWhole));
Debug.print("count: mismatched-hash fixture proposals kept untouched = " # Nat.toText(tamperedFixtures));
assert (bodiesDropped == rebuilt);
let keptReplay = Core.replay(installer, List.toArray(keptBlocks));
assert (Core.fingerprint(keptReplay) == fp() and Core.height(keptReplay) == Core.height(bs));
Debug.print("count: bank blocks replayed from what a pack keeps, to the live fingerprint = " # Nat.toText(List.size(keptBlocks)));

// ═══════════════════════════════════════════════════════════════════════════
//  the calendar's authority through the bank (the Thebes clock finding of 12 September)
// ═══════════════════════════════════════════════════════════════════════════
// On Thebes Time.now() is the block height in seconds: the journal's clock day is 0 and a 2026 business date
// is "in the future". The dual act `journalSetCalendarAuthority` makes the rolled business date the calendar
// and carries the first one; under it the roll never consults the clock and is bounded per roll.
let thebesClock : Nat64 = 21_794_000_000_000;   // the height measured on the bed: 1970-01-01
let clockBefore = clock;
clock := thebesClock;
expectProposeErr(maker, #journalRollBusinessDate({ day = TODAY + 1 }), "BusinessDateInFuture");
expectProposeErr(maker, #journalSetCalendarAuthority({ authority = #businessDate; maxRollDays = 0; businessDate = ?(TODAY + 1) }), "InvalidCalendarAuthority");
assert (fourEyes(#journalSetCalendarAuthority({ authority = #businessDate; maxRollDays = 31; businessDate = ?(TODAY + 1) })).executed);
assert (JCore.effectiveToday(js, thebesClock) == TODAY + 1 and JCore.calendarAuthority(js) == { authority = #businessDate; maxRollDays = 31 });
assert (fourEyes(#journalRollBusinessDate({ day = TODAY + 20 })).executed);   // past the clock's day: the clock is not asked
expectProposeErr(maker, #journalRollBusinessDate({ day = TODAY + 60 }), "BusinessDateRollTooFar");
expectProposeErr(maker, #journalRollBusinessDate({ day = TODAY + 19 }), "BusinessDateBackwards");
assert (fourEyes(#journalSetCalendarAuthority({ authority = #substrateClock; maxRollDays = 0; businessDate = null })).executed);
expectProposeErr(maker, #journalRollBusinessDate({ day = TODAY + 21 }), "BusinessDateInFuture");
clock := clockBefore;
Debug.print("count: calendar-authority acts through the bank = 8");

let finalReplay = Core.replay(installer, BankMemLog.blocks(bchain));
assert (Core.fingerprint(finalReplay) == fp());
assert (Core.height(finalReplay) == Core.height(bs));
Debug.print("count: bank blocks replayed = " # Nat.toText(Core.height(bs)));
let jReplay = JCore.replay(bankP, JMemLog.blocks(jchain));
assert (JCore.fingerprint(jReplay) == jfp());
Debug.print("count: journal blocks replayed = " # Nat.toText(JCore.height(js)));

// Read scope: a principal holding only the book-scoped teller role sees BR01
// only. The maker also holds `config` with no book dimension, so the union rule
// makes it unrestricted — which is the behaviour to assert, not to work around.
switch (Core.readableBooks(bs, teller2)) {
  case null { Debug.print("teller2 should be book-scoped"); assert false };
  case (?books) { assert (books.size() == 1 and Text.equal(books[0], "BR01")) };
};
assert (Core.readableBooks(bs, maker) == null);             // union with an unscoped grant
assert (Core.readableBooks(bs, checker1) == null);          // unrestricted grant
assert (Core.readableBooks(bs, stranger) == ?[]);            // no grant: reads nothing
assert (Core.mayReadBook(?["BR01"], "BR01"));
assert (not Core.mayReadBook(?["BR01"], "BR02"));
assert (Core.mayReadBook(null, "anything"));
assert (Core.mayReadOptBook(?["BR01"], null));               // a row with no book
Debug.print("count: read-scope checks = 7");

// the trial balance balances, and every posting came from an authority
switch (JCore.trialBalance(js, "2026-09")) {
  case (?tb) { assert tb.balanced; Debug.print("count: trial balance rows = " # Nat.toText(tb.rows.size())); assert (tb.rows.size() >= 2) };
  case null { assert false };
};
var postingsWithAuthority = 0;
var i2 = 0;
while (i2 < JCore.height(js)) {
  switch (JCore.postingView(js, JMemLog.reader(jchain), i2)) {
    case (?pv) {
      if (Text.equal(pv.record.sourceRef.kind, "manual") or Text.equal(pv.record.sourceRef.kind, "manual-rev")) {
        // the authority block exists and is a proposal or an override
        let authIdx = switch (Nat.fromText(pv.record.sourceRef.id)) { case (?n) n; case null { assert false; 0 } };
        let isProposal = Core.getProposal(bs, BankMemLog.reader(bchain), authIdx) != null;
        var isOverride = false;
        for (o in Core.listOverrides(bs, BankMemLog.reader(bchain)).vals()) { if (o.index == authIdx) isOverride := true };
        assert (isProposal or isOverride);
        postingsWithAuthority += 1;
      };
    };
    case null {};
  };
  i2 += 1;
};
Debug.print("count: postings whose authority block exists = " # Nat.toText(postingsWithAuthority));
assert (postingsWithAuthority >= 6);

Debug.print("BANK CORE TEST GREEN");
