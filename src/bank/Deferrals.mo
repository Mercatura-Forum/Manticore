/// Deferrals.mo — unearned income and prepaid expense, amortised on a schedule.
///
/// A deferral is the mirror image of an accrual: money received or paid for a period
/// that has not yet elapsed. Unearned income sits in a liability until it is earned;
/// prepaid expense sits in an asset until it is consumed. Both amortise on a
/// recorded schedule, one posting per (schedule, period), and the unamortised
/// balance is always exactly the schedule's own arithmetic rather than a figure that
/// drifts.
///
/// The arithmetic is deliberately the simplest thing that closes to zero: the
/// amount is divided over the periods and the **final period absorbs the residue**,
/// so the column sums to the amount advanced and the closing balance is zero. That
/// is the same discipline the loan schedule uses, for the same reason — a deferral
/// that does not close to zero is a balance nobody can explain at the next audit.

import Nat "mo:core/Nat";
import Text "mo:core/Text";
import List "mo:core/List";

import JT "mo:journal/JournalTypes";

import Posting "Posting";

module {

  public type Day = JT.Day;

  public type Kind = {
    /// Received in advance: a liability until earned. Amortising it debits the
    /// liability and credits income.
    #unearnedIncome;
    /// Paid in advance: an asset until consumed. Amortising it debits expense and
    /// credits the asset.
    #prepaidExpense;
  };

  public func kindText(k : Kind) : Text {
    switch (k) { case (#unearnedIncome) "unearnedIncome"; case (#prepaidExpense) "prepaidExpense" }
  };

  /// A deferral schedule. `periods` is the number of accounting periods it amortises
  /// over; `from` is the first period it amortises in. Both the deferral account and
  /// the recognition account are named, because a schedule whose counterpart is
  /// inferred is a schedule that posts somewhere nobody chose.
  public type Schedule = {
    id : Text;
    kind : Kind;
    currency : JT.Currency;
    amount : Nat;
    periods : Nat;
    deferralAccount : JT.AccountCode;       // the liability or the asset
    recognitionAccount : JT.AccountCode;    // the income or the expense
    book : Text;
    openedOn : Day;
  };

  public type Fault = {
    #invalid : { reason : Text };
    #alreadyAmortised : { schedule : Text; period : Nat };
    #beyondSchedule : { schedule : Text; periods : Nat; asked : Nat };
  };

  public let MAX_PERIODS : Nat = 480;
  public let MAX_ID_BYTES : Nat = 64;

  public func validate(s : Schedule) : ?Fault {
    let n = Text.encodeUtf8(s.id).size();
    if (n == 0 or n > MAX_ID_BYTES) return ?#invalid({ reason = "a schedule id must be 1.." # Nat.toText(MAX_ID_BYTES) # " bytes" });
    if (s.amount == 0) return ?#invalid({ reason = "a deferral of zero defers nothing" });
    if (s.periods == 0 or s.periods > MAX_PERIODS) return ?#invalid({ reason = "periods must be 1.." # Nat.toText(MAX_PERIODS) });
    if (s.amount < s.periods) return ?#invalid({ reason = "a deferral cannot amortise less than one minor unit in a period" });
    if (Text.equal(s.deferralAccount, s.recognitionAccount)) return ?#invalid({ reason = "the deferral and recognition accounts must differ" });
    if (Text.encodeUtf8(s.currency).size() != 3) return ?#invalid({ reason = "the currency must be a three-letter code" });
    null
  };

  /// The amount to amortise in period `n` (1-based). Every period takes
  /// `amount / periods` and the final one takes the rest, so the column sums to the
  /// amount exactly.
  public func amountFor(s : Schedule, n : Nat) : { #ok : Nat; #err : Fault } {
    if (n == 0 or n > s.periods) return #err(#beyondSchedule({ schedule = s.id; periods = s.periods; asked = n }));
    let each = s.amount / s.periods;
    if (n < s.periods) #ok(each) else #ok(s.amount - each * (s.periods - 1))
  };

  /// The unamortised balance after `n` periods have been posted. Zero after the last,
  /// which is the property the close asserts.
  public func remainingAfter(s : Schedule, n : Nat) : Nat {
    if (n >= s.periods) return 0;
    let each = s.amount / s.periods;
    s.amount - each * n
  };

  /// The whole schedule as rows, so it can be compared against an independent
  /// computation rather than inspected.
  public type Row = { period : Nat; amount : Nat; remaining : Nat };

  public func rows(s : Schedule) : [Row] {
    let out = List.empty<Row>();
    var n = 1;
    while (n <= s.periods) {
      let amount = switch (amountFor(s, n)) { case (#ok(a)) a; case (#err(_)) 0 };
      List.add(out, { period = n; amount; remaining = remainingAfter(s, n) });
      n += 1;
    };
    List.toArray(out)
  };

  public func faults(s : Schedule) : [Text] {
    let out = List.empty<Text>();
    let rs = rows(s);
    if (rs.size() != s.periods) List.add(out, "row count differs from the period count");
    var total = 0;
    for (r in rs.vals()) { total += r.amount; if (r.amount == 0) List.add(out, "a period amortises nothing") };
    if (total != s.amount) List.add(out, "the amortisation column sums to " # Nat.toText(total) # ", not " # Nat.toText(s.amount));
    if (rs.size() > 0 and rs[rs.size() - 1].remaining != 0) List.add(out, "the schedule does not close to zero");
    List.toArray(out)
  };

  /// The two legs of one period's amortisation. Unearned income releases a liability
  /// into income; prepaid expense releases an asset into expense.
  public func legs(s : Schedule, amount : Nat) : ?[JT.Leg] {
    if (amount == 0) return null;
    switch (s.kind) {
      case (#unearnedIncome) ?[
        Posting.leg(s.deferralAccount, null, #debit, s.currency, amount),
        Posting.leg(s.recognitionAccount, null, #credit, s.currency, amount),
      ];
      case (#prepaidExpense) ?[
        Posting.leg(s.recognitionAccount, null, #debit, s.currency, amount),
        Posting.leg(s.deferralAccount, null, #credit, s.currency, amount),
      ];
    }
  };
};
