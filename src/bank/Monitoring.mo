/// Monitoring.mo: evaluating the closed rule set over the aggregates.
///
/// Pure over a context: the aggregates (`Activity`), the account's own postings (the I1 range of
/// `PostingIndex`, sized before it is read) and each account's currency. Two entry points, one per
/// timing:
///
///   * `atPosting`; the cheap rules, in the posting's own message, from what that message knows
///     and nothing else: the posting's closed reading (`Activity.Posted`), each account's dormancy
///     **before** the posting, and one reverse lookup for a round trip;
///   * `atDay`; the window rules, for one account and one day, from ranges over the window.
///
/// Every read is bounded before it happens. A window is at most `MAX_WINDOW_DAYS` rows of A1; a
/// structuring rule declares `maxScan` and is **refused, not run**, when the account's postings in
/// the window exceed it; a fan rule reads its neighbour rows in pages and stops at its bar, refused
/// past `MAX_SCAN` rows. A refusal is `#TooWide` with the size and the bound, so the operator can
/// see which rule on which account was too wide to evaluate rather than assume it ran.
///
/// The oracle (`test/Monitoring.test.mo`) recomputes every finding of every rule type from the
/// whole journal by brute force and requires the same findings with the same cited postings.

import Array "mo:core/Array";
import List "mo:core/List";
import Nat "mo:core/Nat";
import Text "mo:core/Text";
import Result "mo:core/Result";

import A "Activity";
import MT "MonitoringTypes";

module {

  public type PostingRow = { posting : Nat; day : Nat; debits : Nat; credits : Nat };

  public type Context = {
    activity : A.State;
    /// The account's postings over `[from, to]` by value day, at most `bound` of them, and whether
    /// there were more; the I1 range, sized first.
    postingsOf : (Nat, Nat, Nat, Nat) -> { rows : [PostingRow]; exceeded : Bool };
    currencyOf : Nat -> ?Text;
  };

  /// A rule applies to an account when it names no currency or the account's.
  public func applies(ctx : Context, rule : MT.Rule, account : Nat) : Bool {
    if (not rule.active) return false;
    switch (rule.currency) {
      case null true;
      case (?c) { switch (ctx.currencyOf(account)) { case (?ac) Text.equal(ac, c); case null false } };
    }
  };

  func windowStart(day : Nat, windowDays : Nat) : Nat { if (windowDays > day) 0 else day + 1 - windowDays };

  func finding(rule : MT.Rule, account : Nat, day : Nat, postings : [Nat], detail : Text) : MT.Finding {
    { rule = rule.id; version = rule.version; account; day; postings = cap(postings); detail }
  };

  func cap(ps : [Nat]) : [Nat] { if (ps.size() <= MT.MAX_CITATIONS) ps else Array.tabulate<Nat>(MT.MAX_CITATIONS, func(i) { ps[i] }) };

  // ═══════════════════════════════════════════════════════
  //  AT POSTING
  // ═══════════════════════════════════════════════════════

  /// The cheap rules against one posting. `recorded` is what `Activity.record` returned for it.
  public func atPosting(ctx : Context, rules : [MT.Rule], recorded : A.Recorded) : [MT.Finding] {
    let ?p = recorded.posted else return [];
    let out = List.empty<MT.Finding>();
    for (rule in rules.vals()) {
      switch (rule.spec) {
        case (#largeCash(x)) {
          var onChannel = false;
          for (c in x.channels.vals()) { if (Text.equal(c, p.channel)) onChannel := true };
          if (onChannel) {
            for (a in p.accounts.vals()) {
              if (applies(ctx, rule, a.account) and a.largest >= x.threshold) {
                List.add(out, finding(rule, a.account, p.day, [p.postingNo], "leg of " # Nat.toText(a.largest) # " on channel " # p.channel));
              };
            };
          };
        };
        case (#dormantThenActive(x)) {
          for (a in p.accounts.vals()) {
            if (applies(ctx, rule, a.account) and Nat.max(a.debits, a.credits) >= x.amount) {
              for ((acct, before) in recorded.before.vals()) {
                if (acct == a.account) {
                  switch (before) {
                    case (?lb) { if (p.day >= lb + x.dormantDays) List.add(out, finding(rule, a.account, p.day, [p.postingNo], "dormant " # Nat.toText(p.day - lb) # " days")) };
                    case null {};
                  };
                };
              };
            };
          };
        };
        case (#roundTrip(x)) {
          for (e in p.edges.vals()) {
            if (e.amount >= x.minAmount) {
              // the account this is found on: the sender when it is an account, else the receiver
              let on : ?Nat = switch (e.from) { case (#account(id)) ?id; case (_) { switch (e.to) { case (#account(id)) ?id; case (_) null } } };
              switch (on) {
                case (?acct) {
                  if (applies(ctx, rule, acct)) {
                    let back = A.edgesBetween(ctx.activity, e.to, e.from, windowStart(p.day, x.windowDays + 1), p.day, MT.MAX_CITATIONS + 1);
                    let earlier = List.empty<Nat>();
                    for (r in back.rows.vals()) { if (r.posting != p.postingNo) List.add(earlier, r.posting) };
                    if (List.size(earlier) > 0) {
                      List.add(out, finding(rule, acct, p.day, Array.concat<Nat>([p.postingNo], List.toArray(earlier)), "edge of " # Nat.toText(e.amount) # " returned within " # Nat.toText(x.windowDays) # " days"));
                    };
                  };
                };
                case null {};
              };
            };
          };
        };
        case (_) {};
      };
    };
    List.toArray(out)
  };

  // ═══════════════════════════════════════════════════════
  //  AT DAY
  // ═══════════════════════════════════════════════════════

  /// The window rules for one account on one day.
  public func atDay(ctx : Context, rules : [MT.Rule], account : Nat, day : Nat) : Result.Result<[MT.Finding], MT.MonitoringError> {
    let out = List.empty<MT.Finding>();
    for (rule in rules.vals()) {
      if (applies(ctx, rule, account)) {
        switch (evaluateWindow(ctx, rule, account, day)) {
          case (#err(e)) return #err(e);
          case (#ok(?f)) List.add(out, f);
          case (#ok(null)) {};
        };
      };
    };
    #ok(List.toArray(out))
  };

  func windowPostings(ctx : Context, account : Nat, from : Nat, to : Nat) : [Nat] {
    Array.map<PostingRow, Nat>(ctx.postingsOf(account, from, to, MT.MAX_CITATIONS).rows, func(r) { r.posting })
  };

  public func evaluateWindow(ctx : Context, rule : MT.Rule, account : Nat, day : Nat) : Result.Result<?MT.Finding, MT.MonitoringError> {
    // a window that reaches rolled-up days has no daily rows to read there: refused, not run short
    let w = MT.windowOf(rule.spec);
    if (w > 0) {
      let start = windowStart(day, w);
      let packed = A.rolledUpThrough(ctx.activity);
      if (packed > 0 and start <= packed) return #err(#WindowPacked({ rule = rule.id; windowStart = start; rolledUpThrough = packed }));
    };
    switch (rule.spec) {
      case (#velocity(x)) {
        let from = windowStart(day, x.windowDays);
        var n = 0;
        for ((_, d) in A.activityOver(ctx.activity, account, from, day).vals()) n += d.count;
        if (n >= x.count) #ok(?finding(rule, account, day, windowPostings(ctx, account, from, day), Nat.toText(n) # " postings in " # Nat.toText(x.windowDays) # " days"))
        else #ok(null)
      };
      case (#passThrough(x)) {
        let from = windowStart(day, x.windowDays);
        var dr = 0; var cr = 0;
        for ((_, d) in A.activityOver(ctx.activity, account, from, day).vals()) { dr += d.debits; cr += d.credits };
        if (dr >= x.minAmount and cr >= x.minAmount and Nat.min(dr, cr) * 100 >= Nat.max(dr, cr) * x.inOutPercent) {
          #ok(?finding(rule, account, day, windowPostings(ctx, account, from, day), "in " # Nat.toText(cr) # ", out " # Nat.toText(dr)))
        } else #ok(null)
      };
      case (#structuring(x)) {
        let from = windowStart(day, x.windowDays);
        let rows = ctx.postingsOf(account, from, day, x.maxScan);
        if (rows.exceeded) return #err(#TooWide({ rule = rule.id; size = rows.rows.size(); bound = x.maxScan }));
        let lo = x.threshold * (100 - x.bandPercent) / 100;
        let hit = List.empty<Nat>();
        for (r in rows.rows.vals()) {
          let m = Nat.max(r.debits, r.credits);
          if (m >= lo and m < x.threshold) List.add(hit, r.posting);
        };
        if (List.size(hit) >= x.count) #ok(?finding(rule, account, day, List.toArray(hit), Nat.toText(List.size(hit)) # " postings in the band under " # Nat.toText(x.threshold)))
        else #ok(null)
      };
      case (#fanOut(x)) fan(ctx, rule, account, day, x.distinct, x.windowDays, true);
      case (#fanIn(x)) fan(ctx, rule, account, day, x.distinct, x.windowDays, false);
      case (_) #ok(null);   // cheap rules do not run at day
    }
  };

  /// Distinct counterparties over the window, read in pages, stopping past the bar; refused past
  /// `MAX_SCAN` rows. Cites one posting per counterparty found.
  func fan(ctx : Context, rule : MT.Rule, account : Nat, day : Nat, bar : Nat, windowDays : Nat, outward : Bool) : Result.Result<?MT.Finding, MT.MonitoringError> {
    let from = windowStart(day, windowDays);
    let me : A.Counterparty = #account(account);
    let read = if (outward) A.edgesOut(ctx.activity, me, from, day, MT.MAX_SCAN) else A.edgesIn(ctx.activity, me, from, day, MT.MAX_SCAN);
    if (read.more) return #err(#TooWide({ rule = rule.id; size = read.rows.size(); bound = MT.MAX_SCAN }));
    let d = A.distinct(read.rows, bar);
    if (not d.overBar) return #ok(null);
    // one citation per distinct counterparty, from E1
    let cited = List.empty<Nat>();
    label cite for (k in d.keys.vals()) {
      if (List.size(cited) >= MT.MAX_CITATIONS) break cite;
      let other = counterpartyOf(k);
      let e = if (outward) A.edgesBetween(ctx.activity, me, other, from, day, 1) else A.edgesBetween(ctx.activity, other, me, from, day, 1);
      for (r in e.rows.vals()) List.add(cited, r.posting);
    };
    #ok(?finding(rule, account, day, List.toArray(cited), Nat.toText(d.keys.size()) # (if (outward) " receivers" else " senders") # " in " # Nat.toText(windowDays) # " days"))
  };

  /// A counterparty from the 33-byte key a neighbour row returned, for the E1 lookup that cites it.
  func counterpartyOf(k : Blob) : A.Counterparty { #key(k) };

  /// The declared cost bound of a rule, as the operator reads it.
  public func costBound(spec : MT.RuleSpec) : Text {
    switch (spec) {
      case (#velocity(x)) "at most " # Nat.toText(x.windowDays) # " activity rows";
      case (#structuring(x)) "at most " # Nat.toText(x.maxScan) # " postings of the account in " # Nat.toText(x.windowDays) # " days, refused past that";
      case (#roundTrip(_)) "one reverse range of at most " # Nat.toText(MT.MAX_CITATIONS + 1) # " rows per edge";
      case (#fanOut(x)) "neighbour rows over " # Nat.toText(x.windowDays) # " days, stopping past " # Nat.toText(x.distinct) # " distinct, refused past " # Nat.toText(MT.MAX_SCAN) # " rows";
      case (#fanIn(x)) "neighbour rows over " # Nat.toText(x.windowDays) # " days, stopping past " # Nat.toText(x.distinct) # " distinct, refused past " # Nat.toText(MT.MAX_SCAN) # " rows";
      case (#dormantThenActive(_)) "one row";
      case (#passThrough(x)) "at most " # Nat.toText(x.windowDays) # " activity rows";
      case (#largeCash(_)) "the posting itself";
    }
  };
}
