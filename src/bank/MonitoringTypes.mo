/// MonitoringTypes.mo; the closed rule set, as declared data.
///
/// A monitoring rule is not an expression: there is no language to write one in. It is one of the
/// eight types below with its fixed parameters, declared under dual authorisation, versioned, and
/// recorded in a block; like a report definition. Every type has a declared cost bound, and the
/// evaluation sizes that bound before it reads (`Monitoring.mo`). The set is the addendum's,
/// grounded in FATF's red-flag typologies (structuring, round-tripping, pass-through, dormancy),
/// Egypt's Law 80 of 2002 and EMLCU reporting, 31 U.S.C. §5324 and the Wolfsberg monitoring
/// guidance; what those name is what the set can express, and nothing else.
///
/// Amounts are minor units of the rule's currency; a rule with a currency applies to accounts of
/// that currency only, and a rule with none applies to every account. Windows are business days,
/// inclusive of the day evaluated, counted backwards.

import Text "mo:core/Text";

module {

  public type RuleId = Text;

  public type RuleSpec = {
    /// At least `count` postings on the account within `windowDays`.
    #velocity : { count : Nat; windowDays : Nat };
    /// At least `count` postings whose account movement lies in
    /// `[threshold × (100 − bandPercent) / 100, threshold)` within `windowDays`; amounts kept
    /// just under a reporting threshold. Reads the account's postings of the window, so it
    /// declares the most it will read (`maxScan`) and is refused, not run, past it.
    #structuring : { threshold : Nat; bandPercent : Nat; count : Nat; windowDays : Nat; maxScan : Nat };
    /// A → B of at least `minAmount`, and B → A within `windowDays` before it.
    #roundTrip : { windowDays : Nat; minAmount : Nat };
    /// More than `distinct` distinct receivers out of the account within `windowDays`.
    #fanOut : { distinct : Nat; windowDays : Nat };
    /// More than `distinct` distinct senders into the account within `windowDays`.
    #fanIn : { distinct : Nat; windowDays : Nat };
    /// A posting of at least `amount` on an account whose last activity was `dormantDays` or more
    /// before it.
    #dormantThenActive : { dormantDays : Nat; amount : Nat };
    /// Over `windowDays`, both credits and debits at least `minAmount`, and the smaller of the two
    /// at least `inOutPercent` of the larger.
    #passThrough : { inOutPercent : Nat; windowDays : Nat; minAmount : Nat };
    /// A single leg of at least `threshold` on a posting whose source kind is one of `channels`.
    #largeCash : { threshold : Nat; channels : [Text] };
  };

  /// Where a rule runs. Cheap rules run in the posting's own message; window rules run in the
  /// end-of-day batch over the day's active accounts. The kind is a property of the type, not a
  /// choice: it is what the cost bound allows.
  public type Timing = { #atPosting; #endOfDay };

  public type Rule = {
    id : RuleId;
    version : Nat;
    currency : ?Text;
    spec : RuleSpec;
    declaredAt : Nat;      // the bank block
    active : Bool;
  };

  /// What an evaluation produces: the rule and version met, the account it was met on, the day,
  /// and the postings that met it. The alert component (step 5) records these; the oracle
  /// compares them.
  public type Finding = {
    rule : RuleId;
    version : Nat;
    account : Nat;
    day : Nat;
    postings : [Nat];
    detail : Text;
  };

  public type MonitoringEvent = {
    #ruleDefined : { id : RuleId; version : Nat; currency : ?Text; spec : RuleSpec };
    #ruleRetired : { id : RuleId; version : Nat };
  };

  public type MonitoringError = {
    #InvalidRule : { rule : RuleId; reason : Text };
    #UnknownRule : { rule : RuleId };
    #RuleRetired : { rule : RuleId };
    #TooWide : { rule : RuleId; size : Nat; bound : Nat };
    /// The window reaches days whose rows have been rolled up into months by closed-month
    /// packing: there is no daily reading there, and the rule is refused rather than run short.
    #WindowPacked : { rule : RuleId; windowStart : Nat; rolledUpThrough : Nat };
  };

  /// The days a rule reads back from the day it is evaluated on; what closed-month packing
  /// must leave live. Zero for the rules that read nothing but the posting and the account's
  /// exact latest activity (which the monthly rows keep).
  public func windowOf(spec : RuleSpec) : Nat {
    switch (spec) {
      case (#velocity(x)) x.windowDays;
      case (#structuring(x)) x.windowDays;
      case (#roundTrip(x)) x.windowDays + 1;
      case (#fanOut(x)) x.windowDays;
      case (#fanIn(x)) x.windowDays;
      case (#passThrough(x)) x.windowDays;
      case (#dormantThenActive(_)) 0;
      case (#largeCash(_)) 0;
    }
  };

  public let MAX_RULE_ID_BYTES : Nat = 32;
  public let MAX_WINDOW_DAYS : Nat = 366;
  public let MAX_DISTINCT : Nat = 10_000;
  public let MAX_SCAN : Nat = 20_000;
  public let MAX_CHANNELS : Nat = 16;
  public let MAX_CHANNEL_BYTES : Nat = 32;
  /// The most postings one finding cites. A rule that meets its bar on the first `count` postings
  /// cites those; a window rule over a busy account cites the first this many.
  public let MAX_CITATIONS : Nat = 64;

  public func timingOf(spec : RuleSpec) : Timing {
    switch (spec) {
      case (#roundTrip(_)) #atPosting;
      case (#dormantThenActive(_)) #atPosting;
      case (#largeCash(_)) #atPosting;
      case (_) #endOfDay;
    }
  };

  public func specName(spec : RuleSpec) : Text {
    switch (spec) {
      case (#velocity(_)) "velocity"; case (#structuring(_)) "structuring"; case (#roundTrip(_)) "roundTrip";
      case (#fanOut(_)) "fanOut"; case (#fanIn(_)) "fanIn"; case (#dormantThenActive(_)) "dormantThenActive";
      case (#passThrough(_)) "passThrough"; case (#largeCash(_)) "largeCash";
    }
  };

  public func validId(t : Text) : Bool {
    let n = Text.encodeUtf8(t).size();
    if (n == 0 or n > MAX_RULE_ID_BYTES) return false;
    for (c in t.chars()) {
      let ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '-' or c == '_' or c == '.';
      if (not ok) return false;
    };
    true
  };

  /// Refuse a rule that could never fire, could read without bound, or names nothing.
  public func validate(id : RuleId, currency : ?Text, spec : RuleSpec) : ?Text {
    if (not validId(id)) return ?("rule id must be 1.." # debug_show (MAX_RULE_ID_BYTES) # " characters of [A-Za-z0-9-_.]");
    switch (currency) { case (?c) { if (Text.encodeUtf8(c).size() != 3) return ?"the currency must be a three-letter code" }; case null {} };
    let window = func(d : Nat) : ?Text { if (d == 0) ?"a window of zero days reads nothing" else if (d > MAX_WINDOW_DAYS) ?("a window past " # debug_show (MAX_WINDOW_DAYS) # " days") else null };
    switch (spec) {
      case (#velocity(x)) { if (x.count == 0) return ?"a count of zero always fires"; window(x.windowDays) };
      case (#structuring(x)) {
        if (x.threshold == 0) return ?"a threshold of zero has no band below it";
        if (x.bandPercent == 0 or x.bandPercent >= 100) return ?"the band must be 1..99 percent";
        if (x.count == 0) return ?"a count of zero always fires";
        if (x.maxScan == 0 or x.maxScan > MAX_SCAN) return ?("maxScan must be 1.." # debug_show (MAX_SCAN));
        window(x.windowDays)
      };
      case (#roundTrip(x)) { if (x.minAmount == 0) return ?"a minimum of zero matches every edge"; window(x.windowDays) };
      case (#fanOut(x)) { if (x.distinct == 0 or x.distinct > MAX_DISTINCT) return ?("distinct must be 1.." # debug_show (MAX_DISTINCT)); window(x.windowDays) };
      case (#fanIn(x)) { if (x.distinct == 0 or x.distinct > MAX_DISTINCT) return ?("distinct must be 1.." # debug_show (MAX_DISTINCT)); window(x.windowDays) };
      case (#dormantThenActive(x)) {
        if (x.dormantDays == 0) return ?"a dormancy of zero days is every account";
        if (x.dormantDays > MAX_WINDOW_DAYS) return ?("a dormancy past " # debug_show (MAX_WINDOW_DAYS) # " days: the look-back is bounded");
        if (x.amount == 0) return ?"an amount of zero matches every posting";
        null
      };
      case (#passThrough(x)) {
        if (x.inOutPercent == 0 or x.inOutPercent > 100) return ?"inOutPercent must be 1..100";
        if (x.minAmount == 0) return ?"a minimum of zero matches every account";
        window(x.windowDays)
      };
      case (#largeCash(x)) {
        if (x.threshold == 0) return ?"a threshold of zero matches every leg";
        if (x.channels.size() == 0) return ?"a large-cash rule names the channels it watches";
        if (x.channels.size() > MAX_CHANNELS) return ?("more than " # debug_show (MAX_CHANNELS) # " channels");
        for (c in x.channels.vals()) {
          let n = Text.encodeUtf8(c).size();
          if (n == 0 or n > MAX_CHANNEL_BYTES) return ?"a channel name out of bounds";
        };
        null
      };
    }
  };
}
