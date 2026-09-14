/// Leadsheet.mo; mapping of chart-of-accounts codes to audit leadsheets.
///
/// The schema is the `account_leadsheet_map` of the audit product's
/// `tb_schema.json`: a list of inclusive four-digit prefix ranges, each naming
/// a leadsheet, its financial-statement category and its audit cycle. A valid
/// schema has no overlapping ranges, so an account falls in at most one range.
/// Accounts that fall in none are reported as unmapped; they are never placed
/// in a default bucket, because a silently bucketed account is exactly the
/// kind of population gap an audit is meant to find.

import Array "mo:core/Array";
import Char "mo:core/Char";
import Nat "mo:core/Nat";
import Nat32 "mo:core/Nat32";
import Text "mo:core/Text";
import List "mo:core/List";
import Map "mo:core/Map";

import T "JournalTypes";

module {

  public type Range = T.LeadsheetRange;

  func isDigit(c : Char) : Bool { c >= '0' and c <= '9' };
  func isAlnum(c : Char) : Bool { isDigit(c) or (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') };

  /// Account code grammar: four ASCII digits, optionally "." then 1..6 ASCII
  /// letters or digits. Returns a reason on rejection.
  public func validateAccountCode(code : Text) : ?Text {
    let cs = Text.toArray(code);
    if (cs.size() < 4) return ?"account code must start with four digits";
    var i = 0;
    while (i < 4) { if (not isDigit(cs[i])) return ?"account code must start with four digits"; i += 1 };
    if (cs.size() == 4) return null;
    if (cs[4] != '.') return ?"account code suffix must begin with '.'";
    let suffix : Nat = cs.size() - 5;
    if (suffix < 1 or suffix > 6) return ?"account code suffix must be 1 to 6 characters";
    i := 5;
    while (i < cs.size()) { if (not isAlnum(cs[i])) return ?"account code suffix must be ASCII letters or digits"; i += 1 };
    null
  };

  /// The four-digit prefix of a (valid) account code as a number.
  public func prefix(code : Text) : ?Nat {
    let cs = Text.toArray(code);
    if (cs.size() < 4) return null;
    var acc : Nat = 0;
    var i = 0;
    while (i < 4) {
      if (not isDigit(cs[i])) return null;
      acc := acc * 10 + (Nat32.toNat(Char.toNat32(cs[i])) - 48);
      i += 1;
    };
    ?acc
  };

  /// Reject a schema with an empty or out-of-range or overlapping range.
  /// Ranges may be given in any order; overlap is checked after sorting by `lo`.
  public func validate(ranges : [Range]) : ?Text {
    if (ranges.size() == 0) return ?"schema has no ranges";
    for (r in ranges.vals()) {
      if (r.lo > r.hi) return ?("range " # Nat.toText(r.lo) # "-" # Nat.toText(r.hi) # " has lo > hi");
      if (r.hi > 9999) return ?("range " # Nat.toText(r.lo) # "-" # Nat.toText(r.hi) # " exceeds 9999");
      if (r.leadsheet.size() == 0) return ?("range " # Nat.toText(r.lo) # "-" # Nat.toText(r.hi) # " has an empty leadsheet id");
    };
    let sorted = sortByLo(ranges);
    var i = 1;
    while (i < sorted.size()) {
      if (sorted[i].lo <= sorted[i - 1].hi) {
        return ?("ranges " # Nat.toText(sorted[i - 1].lo) # "-" # Nat.toText(sorted[i - 1].hi) # " and " # Nat.toText(sorted[i].lo) # "-" # Nat.toText(sorted[i].hi) # " overlap");
      };
      i += 1;
    };
    null
  };

  public func sortByLo(ranges : [Range]) : [Range] {
    Array.sort<Range>(ranges, func(a, b) { Nat.compare(a.lo, b.lo) })
  };

  /// The unique range containing the account's prefix, if any. With a
  /// validated (non-overlapping) schema there is at most one.
  public func lookup(sorted : [Range], code : Text) : ?Range {
    let ?p = prefix(code) else return null;
    var lo = 0;
    var hi = sorted.size();
    while (lo < hi) {
      let mid = (lo + hi) / 2;
      let r = sorted[mid];
      if (p < r.lo) { hi := mid } else if (p > r.hi) { lo := mid + 1 } else { return ?r };
    };
    null
  };

  /// Number of ranges containing the prefix; used by tests to prove "exactly one".
  public func countContaining(ranges : [Range], code : Text) : Nat {
    let ?p = prefix(code) else return 0;
    var n = 0;
    for (r in ranges.vals()) { if (p >= r.lo and p <= r.hi) n += 1 };
    n
  };

  /// Map a trial balance through the schema. Every row lands in `mapped` or
  /// `unmapped`; the two partitions are exhaustive and disjoint by construction.
  public func mapTrialBalance(sorted : [Range], tb : T.TrialBalance) : T.MappedTrialBalance {
    let mapped = List.empty<T.MappedRow>();
    let unmapped = List.empty<T.TrialBalanceRow>();
    // leadsheet totals keyed by (leadsheet, currency)
    type Acc = { name : Text; var dr : Nat; var cr : Nat };
    let totals = Map.empty<(Text, Text), Acc>();
    func cmp(a : (Text, Text), b : (Text, Text)) : { #less; #equal; #greater } {
      switch (Text.compare(a.0, b.0)) { case (#equal) Text.compare(a.1, b.1); case (o) o }
    };
    for (row in tb.rows.vals()) {
      switch (lookup(sorted, row.account)) {
        case (?r) {
          List.add(mapped, { row; leadsheet = r.leadsheet; leadsheetName = r.name; category = r.category; cycle = r.cycle });
          let key = (r.leadsheet, row.currency);
          switch (Map.get(totals, cmp, key)) {
            case (?acc) { acc.dr += row.closingDebits; acc.cr += row.closingCredits };
            case null { Map.add(totals, cmp, key, { name = r.name; var dr = row.closingDebits; var cr = row.closingCredits }) };
          };
        };
        case null { List.add(unmapped, row) };
      };
    };
    let leadsheets = List.empty<T.LeadsheetTotal>();
    for (((ls, ccy), acc) in Map.entries(totals)) {
      List.add(leadsheets, { leadsheet = ls; name = acc.name; currency = ccy; closingDebits = acc.dr; closingCredits = acc.cr });
    };
    {
      period = tb.period;
      mapped = List.toArray(mapped);
      unmapped = List.toArray(unmapped);
      leadsheets = List.toArray(leadsheets);
      balanced = tb.balanced;
    }
  };
};
