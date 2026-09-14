// Entitlements.test.mo; scope is evaluated against the operation's own data.
//
// The property worth proving adversarially is that a caller cannot get past a
// ceiling by splitting an amount across legs, by naming a currency the grant
// does not cover, or by holding a second role that happens to carry the
// permission without the scope. Union semantics (NIST RBAC) mean any one grant
// may permit the operation; the failure reported when none does must be the
// specific one, never a generic "no grant".
//
// engine: wasi-only; the journal core now keeps its per-posting state in a stable-memory Region, and
// the moc interpreter provides no Region. The dual-engine check this loses was worth having, and the
// loss is stated rather than hidden: the reason the state moved is that a heap map per posting makes
// the heap grow with the journal. Every test below still runs under wasmtime, the engine the chain runs.

import Debug "mo:core/Debug";
import Nat "mo:core/Nat";
import Text "mo:core/Text";
import Array "mo:core/Array";

import JT "mo:journal/JournalTypes";
import T "../src/bank/BankTypes";
import E "../src/bank/Entitlements";

func leg(account : Text, side : JT.Side, currency : Text, amount : Nat) : JT.Leg {
  { account; subledger = null; side; currency; amount }
};

let noConsumption = func(_ : Text) : Nat { 0 };

// ─── legTotals: debits per currency, deterministic order ────────────────────
let mixed : [JT.Leg] = [
  leg("1001", #debit, "EGP", 600_00),
  leg("1001", #debit, "EGP", 400_00),
  leg("2110", #credit, "EGP", 1_000_00),
  leg("1002", #debit, "USD", 250_00),
  leg("2111", #credit, "USD", 250_00),
];
let totals = E.legTotals(mixed);
assert (totals.size() == 2);
assert (totals[0].0 == "EGP" and totals[0].1 == 1_000_00);
assert (totals[1].0 == "USD" and totals[1].1 == 250_00);
// order is deterministic regardless of leg order
let shuffled : [JT.Leg] = [mixed[3], mixed[0], mixed[4], mixed[2], mixed[1]];
let totals2 = E.legTotals(shuffled);
assert (totals2[0] == totals[0] and totals2[1] == totals[1]);
Debug.print("count: leg-total currency groups = " # Nat.toText(totals.size()));

// credits alone do not count as the operation's amount (debits == credits, and
// the ceiling is written against one side)
assert (E.legTotals([leg("2110", #credit, "EGP", 999_00)]).size() == 0);
Debug.print("count: credit-only leg sets contributing no total = 1");

// ─── a scoped grant ─────────────────────────────────────────────────────────
let tellerScope : T.Scope = {
  books = ?["BR01"];
  currencies = ?["EGP"];
  ceiling = ?[{ currency = "EGP"; amount = 50_000_00 }];
  dailyLimit = ?[{ currency = "EGP"; amount = 200_000_00 }];
};
let teller : E.ResolvedGrant = { role = "teller"; permissions = ["journal.entry.create"]; scope = tellerScope };
let unrestricted : E.ResolvedGrant = { role = "treasury"; permissions = ["journal.entry.create"]; scope = E.emptyScope() };
let wrongPermission : E.ResolvedGrant = { role = "reader"; permissions = ["command.approve"]; scope = E.emptyScope() };

func op(book : ?Text, totals_ : [(Text, Nat)]) : E.Operation {
  { permission = "journal.entry.create"; book; totals = totals_ }
};

// inside every dimension
switch (E.evaluate([teller], op(?"BR01", [("EGP", 40_000_00)]), noConsumption)) {
  case (#allow(x)) assert (Text.equal(x.role, "teller"));
  case (#deny(e)) { Debug.print("unexpected deny " # debug_show (e)); assert false };
};

// ─── every dimension refuses, with its own typed failure ───────────────────
var denials = 0;
func expectDeny(grants : [E.ResolvedGrant], o : E.Operation, consumed : (Text) -> Nat, want : Text) {
  switch (E.evaluate(grants, o, consumed)) {
    case (#allow(x)) { Debug.print("expected deny (" # want # "), allowed by " # x.role); assert false };
    case (#deny(e)) {
      let got = debug_show (e);
      if (Text.contains(got, #text want)) { denials += 1 } else { Debug.print("wanted " # want # " got " # got); assert false };
    };
  };
};

expectDeny([teller], op(?"BR02", [("EGP", 1_00)]), noConsumption, "OutsideBookScope");
expectDeny([teller], op(?"BR01", [("USD", 1_00)]), noConsumption, "OutsideCurrencyScope");
expectDeny([teller], op(?"BR01", [("EGP", 50_000_01)]), noConsumption, "OverCeiling");
expectDeny([teller], op(?"BR01", [("EGP", 10_000_00)]), func(c) { if (Text.equal(c, "EGP")) 195_000_00 else 0 }, "OverDailyLimit");
expectDeny([wrongPermission], op(?"BR01", [("EGP", 1_00)]), noConsumption, "NoGrant");
expectDeny([], op(?"BR01", [("EGP", 1_00)]), noConsumption, "NoGrant");
Debug.print("count: scope dimensions that refused with a typed failure = " # Nat.toText(denials));
assert (denials == 6);

// the boundary itself is allowed; one minor unit past it is not
switch (E.evaluate([teller], op(?"BR01", [("EGP", 50_000_00)]), noConsumption)) {
  case (#allow(_)) {};
  case (#deny(e)) { Debug.print("the ceiling itself was refused: " # debug_show (e)); assert false };
};
switch (E.evaluate([teller], op(?"BR01", [("EGP", 200_000_00)]), func(_) { 0 })) {
  case (#deny(_)) {};   // over the ceiling, though exactly at the daily limit
  case (#allow(_)) { Debug.print("ceiling not enforced at the daily limit"); assert false };
};
// exactly at the daily limit, in two operations
switch (E.evaluate([teller], op(?"BR01", [("EGP", 5_000_00)]), func(_) { 195_000_00 })) {
  case (#allow(_)) {};
  case (#deny(e)) { Debug.print("the daily limit itself was refused: " # debug_show (e)); assert false };
};
Debug.print("count: ceiling and daily-limit boundary checks = 3");

// ─── splitting an amount across legs does not evade the ceiling ─────────────
// 128 legs of 400.00 EGP each on the debit side total 51,200.00; over the
// 50,000.00 ceiling; while every individual leg is far below it.
var many : [JT.Leg] = [];

let build = func() : [JT.Leg] {
  var acc : [JT.Leg] = [];
  var i = 0;
  while (i < 128) {
    acc := Array.concat(acc, [leg("1001", #debit, "EGP", 400_00)]);
    i += 1;
  };
  acc
};
many := build();
let splitTotals = E.legTotals(many);
assert (splitTotals.size() == 1 and splitTotals[0].1 == 128 * 400_00);
expectDeny([teller], op(?"BR01", splitTotals), noConsumption, "OverCeiling");
Debug.print("count: legs in the split-amount evasion attempt = " # Nat.toText(many.size()));
assert (denials == 7);

// ─── union semantics: a second grant that does permit it wins ──────────────
switch (E.evaluate(E.sortGrants([teller, unrestricted]), op(?"BR02", [("USD", 900_000_00)]), noConsumption)) {
  case (#allow(x)) assert (Text.equal(x.role, "treasury"));
  case (#deny(e)) { Debug.print("union semantics failed: " # debug_show (e)); assert false };
};
// and the reported failure is the specific one, not NoGrant, when a grant held
// the permission but no grant satisfied the scope
expectDeny(E.sortGrants([teller, wrongPermission]), op(?"BR02", [("EGP", 1_00)]), noConsumption, "OutsideBookScope");
Debug.print("count: union-semantics checks = 2");

// evaluation order is deterministic: the same grants in any input order report
// the same failure
let a = E.sortGrants([teller, wrongPermission]);
let b = E.sortGrants([wrongPermission, teller]);
assert (a.size() == b.size());
var same = 0;
var k = 0;
while (k < a.size()) { assert (Text.equal(a[k].role, b[k].role)); same += 1; k += 1 };
Debug.print("count: grant positions equal after sorting either input order = " # Nat.toText(same));

// an operation with no book is not constrained by the book dimension
switch (E.evaluate([teller], { permission = "journal.entry.create"; book = null; totals = [] }, noConsumption)) {
  case (#allow(_)) {};
  case (#deny(e)) { Debug.print("a bookless operation was refused: " # debug_show (e)); assert false };
};
Debug.print("count: bookless operations admitted under a book-scoped grant = 1");

// ─── scope validation ───────────────────────────────────────────────────────
var scopeRefusals = 0;
func badScope(s : T.Scope, want : Text) {
  switch (E.validateScope(s)) {
    case null { Debug.print("scope should have been refused: " # want); assert false };
    case (?r) { if (Text.contains(r, #text want)) scopeRefusals += 1 else { Debug.print("wanted " # want # " got " # r); assert false } };
  };
};
badScope({ E.emptyScope() with books = ?[] }, "empty");
badScope({ E.emptyScope() with books = ?["HQ", "HQ"] }, "duplicate");
badScope({ E.emptyScope() with currencies = ?[] }, "empty");
badScope({ E.emptyScope() with currencies = ?["EGP", "EGP"] }, "duplicate");
badScope({ E.emptyScope() with ceiling = ?[] }, "empty");
badScope({ E.emptyScope() with ceiling = ?[{ currency = "EGP"; amount = 0 }] }, "zero");
badScope({ E.emptyScope() with ceiling = ?[{ currency = "EGP"; amount = 1 }, { currency = "EGP"; amount = 2 }] }, "duplicate");
badScope({ E.emptyScope() with dailyLimit = ?[{ currency = "EGP"; amount = 0 }] }, "zero");
Debug.print("count: invalid scopes refused with a reason = " # Nat.toText(scopeRefusals));
assert (scopeRefusals == 8);
assert (E.validateScope(E.emptyScope()) == null);
assert (E.validateScope(tellerScope) == null);

// over the bound
var bigBooks : [Text] = [];
var m = 0;
while (m <= T.MAX_SCOPE_ENTRIES) { bigBooks := Array.concat(bigBooks, [Nat.toText(m)]); m += 1 };
badScope({ E.emptyScope() with books = ?bigBooks }, "bound");
Debug.print("count: scope entries in the over-bound attempt = " # Nat.toText(bigBooks.size()));
assert (scopeRefusals == 9);

// ─── permissionsOf deduplicates across grants ──────────────────────────────
let perms = E.permissionsOf([teller, unrestricted, wrongPermission]);
assert (perms.size() == 2);
Debug.print("count: distinct permissions across three grants = " # Nat.toText(perms.size()));

Debug.print("ENTITLEMENTS TEST GREEN");
