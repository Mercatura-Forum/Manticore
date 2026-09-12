/// Entitlements.mo — scope evaluation, as a pure function of the operation.
///
/// A grant is (subject, role, scope). A role is a set of permission
/// identifiers. A scope narrows a grant along the dimensions a bank actually
/// delegates on: books, currencies, a per-operation ceiling and a per-business-date
/// limit. `null` in a dimension means unrestricted.
///
/// The rule this module exists to enforce is that **scope is evaluated against
/// the operation's own data**, never against what the caller claims. The book
/// comes from the command, the currencies and the amounts from the command's
/// legs, and the consumed figure from the log. A caller cannot pass a smaller
/// number than the one it is about to post, because the number is read out of
/// the posting.
///
/// A subject may hold several roles; the operation is allowed if any one grant
/// permits it (the union semantics of NIST RBAC, ANSI/INCITS 359-2004). When no
/// grant permits it, the failure reported is the most specific one among the
/// grants that did carry the permission, so "you are over your ceiling" is never
/// reported as "you have no grant".

import Text "mo:core/Text";
import Map "mo:core/Map";
import List "mo:core/List";
import Array "mo:core/Array";

import JT "mo:journal/JournalTypes";

import T "BankTypes";

module {

  /// One of the subject's grants, already resolved to its role's permissions.
  public type ResolvedGrant = {
    role : T.RoleId;
    permissions : [T.PermissionId];
    scope : T.Scope;
  };

  /// What the operation is, as read from the command itself.
  public type Operation = {
    permission : T.PermissionId;
    /// The book the operation acts in, when it acts in one.
    book : ?T.BookId;
    /// Per-currency total of the operation's debit legs. Empty for an operation
    /// that moves no money.
    totals : [(JT.Currency, Nat)];
  };

  public type Decision = { #allow : { role : T.RoleId }; #deny : T.BankError };

  func holds(g : ResolvedGrant, permission : T.PermissionId) : Bool {
    for (p in g.permissions.vals()) { if (Text.equal(p, permission)) return true };
    false
  };

  func inList(xs : [Text], x : Text) : Bool {
    for (y in xs.vals()) { if (Text.equal(y, x)) return true };
    false
  };

  func moneyFor(xs : [T.Money], currency : Text) : ?Nat {
    for (m in xs.vals()) { if (Text.equal(m.currency, currency)) return ?m.amount };
    null
  };

  /// Check one grant against one operation. `consumed` answers how much the
  /// subject has already used in this currency on this business date.
  public func checkGrant(g : ResolvedGrant, op : Operation, consumed : (JT.Currency) -> Nat) : ?T.BankError {
    // book dimension
    switch (g.scope.books, op.book) {
      case (?allowed, ?book) { if (not inList(allowed, book)) return ?#OutsideBookScope({ book }) };
      case (?_, null) {};   // an operation with no book is not constrained by the book dimension
      case (null, _) {};
    };
    // currency dimension
    switch (g.scope.currencies) {
      case (?allowed) {
        for ((ccy, _) in op.totals.vals()) {
          if (not inList(allowed, ccy)) return ?#OutsideCurrencyScope({ currency = ccy });
        };
      };
      case null {};
    };
    // per-operation ceiling, per currency
    switch (g.scope.ceiling) {
      case (?ceilings) {
        for ((ccy, amount) in op.totals.vals()) {
          switch (moneyFor(ceilings, ccy)) {
            case (?c) { if (amount > c) return ?#OverCeiling({ currency = ccy; amount; ceiling = c }) };
            case null {};
          };
        };
      };
      case null {};
    };
    // per-business-date limit, per currency
    switch (g.scope.dailyLimit) {
      case (?limits) {
        for ((ccy, amount) in op.totals.vals()) {
          switch (moneyFor(limits, ccy)) {
            case (?limit) {
              let used = consumed(ccy);
              if (used + amount > limit) return ?#OverDailyLimit({ currency = ccy; amount; consumed = used; limit });
            };
            case null {};
          };
        };
      };
      case null {};
    };
    null
  };

  /// Evaluate every grant the subject holds. Grants are examined in the order
  /// given, which the caller fixes by sorting on the role identifier, so the
  /// decision and the reported failure are deterministic.
  public func evaluate(grants : [ResolvedGrant], op : Operation, consumed : (JT.Currency) -> Nat) : Decision {
    var sawPermission = false;
    var firstFailure : ?T.BankError = null;
    for (g in grants.vals()) {
      if (holds(g, op.permission)) {
        sawPermission := true;
        switch (checkGrant(g, op, consumed)) {
          case null return #allow({ role = g.role });
          case (?e) { if (firstFailure == null) firstFailure := ?e };
        };
      };
    };
    if (not sawPermission) return #deny(#NoGrant({ permission = op.permission }));
    switch (firstFailure) {
      case (?e) #deny(e);
      case null #deny(#NoGrant({ permission = op.permission }));   // unreachable: a grant that held it either allowed or failed
    }
  };

  /// The reason code recorded in an `#operationRefused` block.
  public func refusalReason(e : T.BankError) : T.RefusalReason {
    switch (e) {
      case (#NoGrant(_)) #noGrant;
      case (#OutsideBookScope(_)) #outsideBook;
      case (#OutsideSubjectScope(_)) #outsideBook;
      case (#OutsideCurrencyScope(_)) #outsideCurrency;
      case (#OverCeiling(_)) #overCeiling;
      case (#OverDailyLimit(_)) #overDailyLimit;
      case (#NotEligibleChecker(_)) #notEligibleChecker;
      case (#SelfApproval(_)) #selfApproval;
      case (#CommandHashMismatch(_)) #commandHashMismatch;
      case (#ProposalExpired(_)) #proposalExpired;
      case (#FeatureInactive(_)) #featureInactive;
      case (#BookClosed(_)) #bookClosed;
      case (#WitnessRequired) #noWitness;
      case (#WitnessIsActor) #noWitness;
      case (#WitnessNotEligible(_)) #noWitness;
      case (#NotBankAdmin) #notAdmin;
      case (_) #noGrant;
    }
  };

  // ═══════════════════════════════════════════════════════
  //  WHAT AN OPERATION IS, READ OUT OF THE COMMAND
  // ═══════════════════════════════════════════════════════

  /// The book a command acts in. For `#openBook` it is the parent, because the
  /// new book does not exist yet and the authority needed is authority over the
  /// place it is being created; creating a root book needs an unrestricted book
  /// scope, which is what `null` here produces when there is no parent.
  public func commandBook(c : T.Command) : ?T.BookId {
    switch (c) {
      case (#openBook(x)) x.parent;
      case (#closeBook(x)) ?x.id;
      case (#postManualEntry(x)) ?x.book;
      case (#reverseManualEntry(x)) ?x.book;
      case (_) null;
    }
  };

  /// Per-currency total of the debit legs of whatever the command posts. Debits
  /// equal credits in every admitted posting, so either side measures the
  /// operation; debits are used because that is the side a limit is written
  /// against in practice.
  public func commandTotals(c : T.Command) : [(JT.Currency, Nat)] {
    switch (c) {
      case (#postManualEntry(x)) legTotals(x.legs);
      case (_) [];
    }
  };

  public func legTotals(legs : [JT.Leg]) : [(JT.Currency, Nat)] {
    let sums = Map.empty<JT.Currency, Nat>();
    for (l in legs.vals()) {
      switch (l.side) {
        case (#debit) {
          let prev = switch (Map.get(sums, Text.compare, l.currency)) { case (?n) n; case null 0 };
          Map.add(sums, Text.compare, l.currency, prev + l.amount);
        };
        case (#credit) {};
      };
    };
    // deterministic order: Map.toArray over a Text-ordered map is sorted
    Map.toArray(sums)
  };

  /// Sort grants by role identifier so evaluation order, and therefore the
  /// reported failure, is deterministic.
  public func sortGrants(gs : [ResolvedGrant]) : [ResolvedGrant] {
    Array.sort<ResolvedGrant>(gs, func(a, b) { Text.compare(a.role, b.role) })
  };

  /// Validate a scope's shape. Bounds keep a grant from becoming a denial of
  /// service, and a duplicate or an empty list is a mistake worth refusing
  /// rather than interpreting.
  public func validateScope(s : T.Scope) : ?Text {
    func checkTexts(o : ?[Text], what : Text) : ?Text {
      switch (o) {
        case null null;
        case (?xs) {
          if (xs.size() == 0) return ?(what # " list is empty; omit the dimension to leave it unrestricted");
          if (xs.size() > T.MAX_SCOPE_ENTRIES) return ?(what # " list exceeds the bound");
          var i = 0;
          while (i < xs.size()) {
            var j = i + 1;
            while (j < xs.size()) { if (Text.equal(xs[i], xs[j])) return ?("duplicate " # what # " " # xs[i]); j += 1 };
            i += 1;
          };
          null
        };
      }
    };
    func checkMoney(o : ?[T.Money], what : Text) : ?Text {
      switch (o) {
        case null null;
        case (?xs) {
          if (xs.size() == 0) return ?(what # " list is empty; omit the dimension to leave it unrestricted");
          if (xs.size() > T.MAX_SCOPE_ENTRIES) return ?(what # " list exceeds the bound");
          var i = 0;
          while (i < xs.size()) {
            if (xs[i].amount == 0) return ?(what # " of zero would refuse every operation in " # xs[i].currency);
            var j = i + 1;
            while (j < xs.size()) { if (Text.equal(xs[i].currency, xs[j].currency)) return ?("duplicate " # what # " currency " # xs[i].currency); j += 1 };
            i += 1;
          };
          null
        };
      }
    };
    switch (checkTexts(s.books, "book")) { case (?e) return ?e; case null {} };
    switch (checkTexts(s.currencies, "currency")) { case (?e) return ?e; case null {} };
    switch (checkMoney(s.ceiling, "ceiling")) { case (?e) return ?e; case null {} };
    switch (checkMoney(s.dailyLimit, "daily limit")) { case (?e) return ?e; case null {} };
    null
  };

  public func emptyScope() : T.Scope { { books = null; currencies = null; ceiling = null; dailyLimit = null } };

  public func permissionsOf(gs : [ResolvedGrant]) : [T.PermissionId] {
    let out = List.empty<T.PermissionId>();
    for (g in gs.vals()) {
      for (p in g.permissions.vals()) {
        var seen = false;
        for (q in List.values(out)) { if (Text.equal(p, q)) seen := true };
        if (not seen) List.add(out, p);
      };
    };
    List.toArray(out)
  };
};
