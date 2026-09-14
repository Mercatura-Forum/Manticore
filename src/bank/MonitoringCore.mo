/// MonitoringCore.mo: the declared rules, folded from the bank's log.
///
/// A rule is a recorded, dual-authorised decision. Defining one again is a new version; retiring
/// one keeps it in the registry, inactive, so a finding that cites version 2 of a rule can always be
/// read back against what version 2 said. Bounded by the organisation's rule book, so it stays on
/// the heap.

import Map "mo:core/Map";
import Nat "mo:core/Nat";
import List "mo:core/List";
import Text "mo:core/Text";
import Result "mo:core/Result";
import Runtime "mo:core/Runtime";

import C "mo:journal/Canonical";
import MT "MonitoringTypes";

module {

  public type State = {
    rules : Map.Map<MT.RuleId, MT.Rule>;
    /// Every version ever declared, (id, version) in order, so a citation can be resolved.
    history : List.List<MT.Rule>;
  };

  public func newState() : State { { rules = Map.empty<MT.RuleId, MT.Rule>(); history = List.empty<MT.Rule>() } };

  public func apply(s : State, block : Nat, e : MT.MonitoringEvent) {
    switch (e) {
      case (#ruleDefined(x)) {
        let r : MT.Rule = { id = x.id; version = x.version; currency = x.currency; spec = x.spec; declaredAt = block; active = true };
        Map.add(s.rules, Text.compare, x.id, r);
        List.add(s.history, r);
      };
      case (#ruleRetired(x)) {
        let ?r = Map.get(s.rules, Text.compare, x.id) else Runtime.trap("MonitoringCore: retirement of an unknown rule");
        Map.add(s.rules, Text.compare, x.id, { r with active = false });
      };
    }
  };

  public func get(s : State, id : MT.RuleId) : ?MT.Rule { Map.get(s.rules, Text.compare, id) };

  /// The rule as a version said it, for reading a finding back.
  public func version(s : State, id : MT.RuleId, v : Nat) : ?MT.Rule {
    for (r in List.values(s.history)) { if (Text.equal(r.id, id) and r.version == v) return ?r };
    null
  };

  public func list(s : State) : [MT.Rule] {
    let out = List.empty<MT.Rule>();
    for ((_, r) in Map.entries(s.rules)) List.add(out, r);
    List.toArray(out)
  };

  /// The active rules of one timing; what a posting or a day evaluates.
  /// The longest window any active rule reads: the least distance closed-month packing keeps
  /// between the packed boundary and the business date.
  public func longestWindow(s : State) : Nat {
    var w = 0;
    for ((_, r) in Map.entries(s.rules)) { if (r.active) w := Nat.max(w, MT.windowOf(r.spec)) };
    w
  };

  public func active(s : State, timing : MT.Timing) : [MT.Rule] {
    let out = List.empty<MT.Rule>();
    for ((_, r) in Map.entries(s.rules)) { if (r.active and MT.timingOf(r.spec) == timing) List.add(out, r) };
    List.toArray(out)
  };

  public func count(s : State) : Nat { Map.size(s.rules) };

  public func planDefine(s : State, id : MT.RuleId, currency : ?Text, spec : MT.RuleSpec) : Result.Result<MT.MonitoringEvent, MT.MonitoringError> {
    switch (MT.validate(id, currency, spec)) { case (?why) return #err(#InvalidRule({ rule = id; reason = why })); case null {} };
    let v = switch (Map.get(s.rules, Text.compare, id)) { case (?r) r.version + 1; case null 1 };
    #ok(#ruleDefined({ id; version = v; currency; spec }))
  };

  public func planRetire(s : State, id : MT.RuleId) : Result.Result<MT.MonitoringEvent, MT.MonitoringError> {
    let ?r = Map.get(s.rules, Text.compare, id) else return #err(#UnknownRule({ rule = id }));
    if (not r.active) return #err(#RuleRetired({ rule = id }));
    #ok(#ruleRetired({ id; version = r.version }))
  };

  func writeSpec(w : C.Writer, spec : MT.RuleSpec) {
    switch (spec) {
      case (#velocity(x)) { w.byte(1); w.nat(x.count); w.nat(x.windowDays) };
      case (#structuring(x)) { w.byte(2); w.nat(x.threshold); w.nat(x.bandPercent); w.nat(x.count); w.nat(x.windowDays); w.nat(x.maxScan) };
      case (#roundTrip(x)) { w.byte(3); w.nat(x.windowDays); w.nat(x.minAmount) };
      case (#fanOut(x)) { w.byte(4); w.nat(x.distinct); w.nat(x.windowDays) };
      case (#fanIn(x)) { w.byte(5); w.nat(x.distinct); w.nat(x.windowDays) };
      case (#dormantThenActive(x)) { w.byte(6); w.nat(x.dormantDays); w.nat(x.amount) };
      case (#passThrough(x)) { w.byte(7); w.nat(x.inOutPercent); w.nat(x.windowDays); w.nat(x.minAmount) };
      case (#largeCash(x)) { w.byte(8); w.nat(x.threshold); w.len16(x.channels.size()); for (c in x.channels.vals()) w.text(c) };
    }
  };

  public func fingerprintInto(w : C.Writer, s : State) {
    w.nat(Map.size(s.rules));
    for ((_, r) in Map.entries(s.rules)) {
      w.text(r.id); w.nat(r.version);
      switch (r.currency) { case null w.byte(0); case (?c) { w.byte(1); w.text(c) } };
      writeSpec(w, r.spec); w.nat(r.declaredAt); w.bool(r.active);
    };
    w.nat(List.size(s.history));
  };
}
