/// Queries.mo — one bounded, paged read over the posting indexes.
///
/// `PostingIndex` is the write side; this is the read side, and it is deliberately the **only** new
/// read surface the component adds. Proposal §4: the engine picks the narrowest index the filter
/// allows, applies the rest while walking it, sizes the walk first and refuses a filter wider than
/// its bound — naming the size — rather than trapping part-way.
///
/// ## Why refusal and not truncation
///
/// A read that silently returns the first five hundred of a million matching rows is worse than one
/// that fails: the caller cannot tell a complete answer from a prefix, and a reconciliation built on
/// the prefix is wrong in a way nothing detects. So every page says which index answered it, how many
/// rows the sizing found, and what the bound was. A filter past the bound is an `#err`, and the error
/// carries the size and the one sentence that says how to narrow it.
///
/// ## Which index answers
///
/// In order of how much of the key space the filter fixes:
///
///   1. an **account** filter → I1 (`acctId ‖ valueDay ‖ postingNo`), one account's slice;
///   2. a **declared class** filter → I4;
///   3. a **currency** filter → I3;
///   4. otherwise → I2, the day index.
///
/// Every one of those is a single range scan with a date window, because the day is the second part
/// of all four keys. A filter the chosen index does not fix — an amount band, a status, a currency
/// when the account index answered — is applied while walking, and the page reports how many rows it
/// walked so a caller can see the selectivity it got.
///
/// ## Dates are value dates
///
/// `from` and `to` are **value** dates, because that is what the four keys are ordered by and what a
/// statement is ordered by. A posting's booking date is in the row, so a caller filtering on booking
/// date filters the page; a caller wanting a booking-date *range* wants the report engine, which folds
/// the period.
///
/// ## Stale rows
///
/// A pending that resolved to another value day left rows at the day it was first indexed under.
/// `PostingIndex.isLive` separates them, and this engine drops the stale ones. They are counted, so a
/// page can say it walked rows it did not return and why.

import Blob "mo:core/Blob";
import List "mo:core/List";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Text "mo:core/Text";

import JT "mo:journal/JournalTypes";

import IT "IndexTypes";
import RI "mo:ledger/RegionIndex";
import PIdx "PostingIndex";

module {

  /// The page bound of the design. A caller may ask for less; nothing gets more.
  public let MAX_LIMIT : Nat = 500;
  /// How many index rows the engine will walk to fill one page. The same figure as the report
  /// engine's `MAX_SLICE`, so one number governs both bounded reads in this estate.
  public let MAX_SCAN : Nat = 20_000;

  public type Filter = {
    account : ?Nat;
    currency : ?JT.Currency;
    class_ : ?Text;
    /// Inclusive value-date window. Absent means unbounded, which is usually refused by the sizing —
    /// correctly, because an unbounded window over a real journal is not a bounded read.
    from : ?JT.Day;
    to : ?JT.Day;
    minAmount : ?Nat;
    maxAmount : ?Nat;
    /// Which statuses to return. Absent means the two that mean "this moved money":
    /// `posted` and `postedFromPending`.
    statuses : ?[Nat8];
    cursor : ?Blob;
    limit : Nat;
  };

  public type Row = {
    postingNo : Nat;
    valueDay : JT.Day;
    postingDay : JT.Day;
    currency : JT.Currency;
    debits : Nat;
    credits : Nat;
    legs : Nat;
    status : Nat8;
    flags : Nat8;
    period : JT.PeriodId;
    /// The account the row is about, when the account index answered. Absent for the day, currency
    /// and class indexes, whose rows are about a posting and not about one account.
    account : ?Nat;
  };

  public type Page = {
    rows : [Row];
    cursor : ?Blob;
    /// Which index answered: `account`, `class`, `currency` or `day`. Stated rather than inferred,
    /// because a caller checking selectivity needs to know what was walked.
    index : Text;
    /// Index rows walked, including those a secondary filter or staleness dropped.
    scanned : Nat;
    /// Rows dropped because they were superseded by a resolution to another value day.
    stale : Nat;
    /// Rows dropped by a filter the chosen index does not fix.
    filtered : Nat;
    /// What the sizing found, up to the bound.
    sized : Nat;
    bound : Nat;
    /// The journal height the page was read at, so every row is checkable against the certified
    /// root as it stood for this answer.
    atHeight : Nat;
  };

  /// Declared in `IndexTypes` so the bank's error union does not import the engine.
  public type Error = IT.QueryError;

  /// What the engine needs that the index does not hold.
  public type Context = {
    /// The currency of a currency ordinal, and the period of a period ordinal: the index keys on
    /// ordinals and a caller reads names.
    /// A posting's record, for the one case a bounded read still needs it: an amount filter over a
    /// row whose movement field saturated. `null` drops the row from an amount-filtered page rather
    /// than guessing, and the page's `filtered` count says it happened.
    recordOf : Nat -> ?JT.PostingRecord;
    /// The journal's height, stamped on the page.
    height : Nat;
    /// Which account ids exist, so a filter naming an account the bank never opened is refused
    /// rather than answered "no rows" — the two are different answers and a caller must be able to
    /// tell them apart.
    accountExists : Nat -> Bool;
    /// The declared class of an account, the same answer the index was written with. Needed for
    /// exactly one thing: a saturated row on the class index, whose exact magnitude is the sum over
    /// that class's legs and not over the posting's. Without it the band would be decided against
    /// the saturated field and a bound straddling 2^64 would be answered wrongly — a case no bank
    /// reaches, which is not a reason to be wrong about it.
    classOf : Nat -> ?Text;
  };

  let DEFAULT_STATUSES : [Nat8] = [PIdx.STATUS_POSTED, PIdx.STATUS_POSTED_FROM_PENDING];

  let DAY_MIN : JT.Day = 0;
  let DAY_MAX : JT.Day = 4_294_967_295;

  func statusWanted(statuses : [Nat8], s : Nat8) : Bool {
    for (w in statuses.vals()) { if (w == s) return true };
    false
  };

  /// The movement a filter compares against: the larger of the two sides, because an entry is as
  /// large as the amount that moved and a balanced posting's two sides are equal.
  func magnitude(m : PIdx.Movement) : Nat { if (m.debits >= m.credits) m.debits else m.credits };

  /// Which legs of a posting a given index's row is the sum of. Each of the four indexes sums a
  /// different subset, so a saturated row's exact magnitude has to be taken over the same subset the
  /// row was written from, or the band is decided against a different number than the row reports.
  type Scope = {
    #account : Nat;
    #class_ : Text;
    #currency : Nat;
    /// The day index's row is the posting's movement in its primary currency.
    #primary;
  };

  /// The exact magnitude of a saturated row, recomputed from the record over the row's own scope.
  /// Only reached when an amount filter is active and the header says the eight-byte field could not
  /// hold the leg.
  func exactMagnitude(ctx : Context, idx : PIdx.State, postingNo : Nat, scope : Scope) : ?Nat {
    let ?record = ctx.recordOf(postingNo) else return null;
    if (record.legs.size() == 0) return ?0;
    let primary = record.legs[0].currency;
    var dr = 0;
    var cr = 0;
    for (leg in record.legs.vals()) {
      let acctOf : ?Nat = switch (leg.subledger) {
        case (?sub) PIdx.accountOf(idx, sub);
        case null null;
      };
      let counts = switch (scope) {
        case (#account(wanted)) { switch (acctOf) { case (?a) a == wanted; case null false } };
        case (#class_(wanted)) {
          switch (acctOf) {
            case (?a) { switch (ctx.classOf(a)) { case (?l) Text.equal(l, wanted); case null false } };
            case null false;
          }
        };
        case (#currency(ord)) {
          switch (PIdx.knownCurrency(idx, leg.currency)) { case (?o) o == ord; case null false }
        };
        case (#primary) Text.equal(leg.currency, primary);
      };
      if (counts) {
        switch (leg.side) { case (#debit) dr += leg.amount; case (#credit) cr += leg.amount };
      };
    };
    ?(if (dr >= cr) dr else cr)
  };

  type Plan = {
    name : Text;
    index : RI.State;
    lo : Blob;
    hi : Blob;
    width : Nat;
    /// How to read the posting number out of a key of this index.
    postingOf : Blob -> Nat;
    /// How to read the value day out of a key of this index.
    dayOf : Blob -> JT.Day;
    /// The account every row of this plan is about, when the plan fixes one.
    account : ?Nat;
    /// Which legs a row of this plan is the sum of.
    scope : Scope;
    /// The sentence the refusal uses.
    narrow : Text;
  };

  func planFor(idx : PIdx.State, f : Filter, from : JT.Day, to : JT.Day) : Plan {
    switch (f.account) {
      case (?a) {
        let (lo, hi) = PIdx.accountRangeEnds(a, from, to);
        {
          name = "account"; index = idx.byAccount; lo; hi; width = PIdx.I1_KEY;
          postingOf = func(k) { PIdx.splitAccountKey(k).postingNo };
          dayOf = func(k) { PIdx.splitAccountKey(k).valueDay };
          account = ?a;
          scope = #account(a);
          narrow = "narrow the date range";
        }
      };
      case null {
        switch (f.class_) {
          case (?c) {
            // `knownClass` has already been checked by `run`, so the ordinal is present.
            let ord = switch (PIdx.knownClass(idx, c)) { case (?o) o; case null 0 };
            let (lo, hi) = PIdx.classRangeEnds(ord, from, to);
            {
              name = "class"; index = idx.byClass; lo; hi; width = PIdx.I4_KEY;
              postingOf = func(k) { PIdx.splitOrdinalKey(k).postingNo };
              dayOf = func(k) { PIdx.splitOrdinalKey(k).valueDay };
              account = null;
              scope = #class_(c);
              narrow = "narrow the date range, or name an account";
            }
          };
          case null {
            switch (f.currency) {
              case (?c) {
                let ord = switch (PIdx.knownCurrency(idx, c)) { case (?o) o; case null 0 };
                let (lo, hi) = PIdx.currencyRangeEnds(ord, from, to);
                {
                  name = "currency"; index = idx.byCurrency; lo; hi; width = PIdx.I3_KEY;
                  postingOf = func(k) { PIdx.splitOrdinalKey(k).postingNo };
                  dayOf = func(k) { PIdx.splitOrdinalKey(k).valueDay };
                  account = null;
                  scope = #currency(ord);
                  narrow = "narrow the date range, or name an account";
                }
              };
              case null {
                let (lo, hi) = PIdx.dayRangeEnds(from, to);
                {
                  name = "day"; index = idx.byDay; lo; hi; width = PIdx.I2_KEY;
                  postingOf = func(k) { PIdx.splitDayKey(k).postingNo };
                  dayOf = func(k) { PIdx.splitDayKey(k).valueDay };
                  account = null;
                  scope = #primary;
                  narrow = "narrow the date range, or name an account, a currency or a class";
                }
              };
            }
          };
        }
      };
    }
  };

  /// One page. Sized first, then walked; never the other way round.
  public func run(idx : PIdx.State, f : Filter, ctx : Context) : { #ok : Page; #err : Error } {
    // ── the filter itself ──
    let limit = if (f.limit == 0 or f.limit > MAX_LIMIT) MAX_LIMIT else f.limit;
    let from = switch (f.from) { case (?d) d; case null DAY_MIN };
    let to = switch (f.to) { case (?d) d; case null DAY_MAX };
    if (from > to) {
      return #err(#InvalidRange({ reason = "the window starts after it ends: " # Nat.toText(from) # " > " # Nat.toText(to) }));
    };
    if (to > DAY_MAX) {
      return #err(#InvalidRange({ reason = "a day beyond the four bytes a key holds" }));
    };
    switch (f.minAmount, f.maxAmount) {
      case (?lo, ?hi) {
        if (lo > hi) return #err(#InvalidRange({ reason = "the amount band starts above where it ends" }));
      };
      case (_, _) {};
    };
    switch (f.account) {
      case (?a) { if (not ctx.accountExists(a)) return #err(#UnknownAccount({ account = a })) };
      case null {};
    };
    // A currency or class the journal has never seen is a refusal, not an empty page: "no such
    // currency" and "no movements in that currency" are different answers.
    switch (f.currency) {
      case (?c) { if (PIdx.knownCurrency(idx, c) == null) return #err(#UnknownCurrency({ currency = c })) };
      case null {};
    };
    switch (f.class_) {
      case (?c) { if (PIdx.knownClass(idx, c) == null) return #err(#UnknownClass({ class_ = c })) };
      case null {};
    };

    let plan = planFor(idx, f, from, to);
    let statuses = switch (f.statuses) { case (?s) s; case null DEFAULT_STATUSES };

    // ── size before walking ──
    let sizing = RI.rangeSize(plan.index, plan.lo, plan.hi, MAX_SCAN);
    if (sizing.exceeded) {
      return #err(#TooWide({ size = sizing.size; bound = MAX_SCAN; narrow = plan.narrow }));
    };

    // ── walk ──
    //
    // Two loops, and the inner one has to be able to stop **without** advancing past what it has not
    // looked at. A page fills when `limit` rows have been kept, which can happen part-way through a
    // B-tree page whenever a secondary filter has dropped rows earlier on; the entries after it in
    // that same B-tree page have not been examined, so the cursor has to point at the first of them
    // and not at whatever the B-tree page's own cursor says. Getting that wrong loses rows silently,
    // which the oracle caught at a page size of two: 494 rows returned where 552 were due.
    let rows = List.empty<Row>();
    var scanned = 0;
    var stale = 0;
    var filtered = 0;
    var cursor = f.cursor;
    var out : ?Blob = null;
    label walk loop {
      let page = RI.range(plan.index, plan.lo, plan.hi, cursor, limit);
      if (page.entries.size() == 0) { out := null; break walk };
      var i = 0;
      label examine while (i < page.entries.size()) {
        if (List.size(rows) >= limit) { out := ?page.entries[i].0; break walk };
        let (k, v) = page.entries[i];
        i += 1;
        scanned += 1;
        let postingNo = plan.postingOf(k);
        let keyDay = plan.dayOf(k);
        switch (PIdx.header(idx, postingNo)) {
          // A row with no header cannot happen: the header is written in the same message as the row.
          // Counting it as filtered rather than trapping keeps a read from being the thing that takes
          // the contract down.
          case null filtered += 1;
          case (?h) {
            if (h.valueDay != keyDay) { stale += 1 } else if (not statusWanted(statuses, h.status)) {
              filtered += 1;
            } else {
              let m = PIdx.readMovement(v);
              // The magnitude the amount band compares against. A saturated row's eight-byte field
              // cannot answer it, so the record decides, over the same legs the row was written from;
              // a record that cannot be read leaves the band undecidable, and an undecidable row is
              // dropped rather than guessed at.
              let amountOk = switch (f.minAmount, f.maxAmount) {
                case (null, null) true;
                case (_, _) {
                  let exact : ?Nat = if (PIdx.hasFlag(h.flags, PIdx.FLAG_SATURATED)) {
                    exactMagnitude(ctx, idx, postingNo, plan.scope)
                  } else ?magnitude(m);
                  switch (exact) {
                    case null false;
                    case (?mag) {
                      let aboveMin = switch (f.minAmount) { case (?lo) mag >= lo; case null true };
                      let belowMax = switch (f.maxAmount) { case (?hi) mag <= hi; case null true };
                      aboveMin and belowMax
                    };
                  }
                };
              };
              // A currency filter the day or account index answered: checked against the header's
              // primary currency. The currency index has already fixed it in the key.
              let ccyOk = switch (f.currency) {
                case null true;
                case (?c) {
                  if (Text.equal(plan.name, "currency")) true
                  else switch (PIdx.knownCurrency(idx, c)) { case (?o) h.currencyOrd == o; case null false };
                };
              };
              if (amountOk and ccyOk) {
                List.add(rows, {
                  postingNo;
                  valueDay = h.valueDay;
                  postingDay = h.postingDay;
                  currency = switch (PIdx.currencyOf(idx, h.currencyOrd)) { case (?c) c; case null "" };
                  debits = m.debits;
                  credits = m.credits;
                  legs = h.legs;
                  status = h.status;
                  flags = h.flags;
                  period = switch (PIdx.periodOf(idx, h.periodOrd)) { case (?p) p; case null "" };
                  account = plan.account;
                });
              } else { filtered += 1 };
            };
          };
        };
      };
      // The B-tree page is exhausted. Either the caller's page is full, in which case the next row is
      // where the B-tree said to resume, or there is more of the range to walk.
      if (List.size(rows) >= limit) { out := page.cursor; break walk };
      switch (page.cursor) {
        case null { out := null; break walk };
        case (?c) {
          cursor := ?c;
          // Bounded by the sizing, which already refused anything past `MAX_SCAN`. The check is here
          // as well so a filter that drops almost everything cannot walk further than a filter that
          // drops nothing.
          if (scanned >= MAX_SCAN) { out := ?c; break walk };
        };
      };
    };

    #ok({
      rows = List.toArray(rows);
      cursor = out;
      index = plan.name;
      scanned;
      stale;
      filtered;
      sized = sizing.size;
      bound = MAX_SCAN;
      atHeight = ctx.height;
    })
  };
}
