/// ShardCore.mo; the shard rule's fold, the transfers' rows, and the routing arithmetic.
///
/// The rule and the open transfers are bounded by acts, so they are heap maps; a transfer's
/// history is its blocks.

import Blob "mo:core/Blob";
import List "mo:core/List";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Principal "mo:core/Principal";
import Result "mo:core/Result";
import Text "mo:core/Text";

import C "mo:journal/Canonical";

import ST "ShardTypes";
import Iban "Iban";

module {

  public type State = {
    var rule : ?ST.Rule;
    versions : List.List<ST.Rule>;
    outbound : Map.Map<ST.TransferId, ST.Outbound>;
    /// (fromShard, transfer) -> what was posted here for it: the duplicate check on delivery.
    inbound : Map.Map<(Nat, Nat), ST.Inbound>;
    var openCount : Nat;
    var settledCount : Nat;
    var returnedCount : Nat;
    var inboundCount : Nat;
  };

  public func newState() : State {
    { var rule = null; versions = List.empty<ST.Rule>(); outbound = Map.empty<ST.TransferId, ST.Outbound>(); inbound = Map.empty<(Nat, Nat), ST.Inbound>(); var openCount = 0; var settledCount = 0; var returnedCount = 0; var inboundCount = 0 }
  };

  func cmp2(a : (Nat, Nat), b : (Nat, Nat)) : { #less; #equal; #greater } {
    switch (Nat.compare(a.0, b.0)) { case (#equal) Nat.compare(a.1, b.1); case (o) o }
  };

  // ─── the rule ─────────────────────────────────────────────────────────────

  public func rule(s : State) : ?ST.Rule { s.rule };
  public func versions(s : State) : [ST.Rule] { List.toArray(s.versions) };

  public func planDeclare(s : State, self : ST.ShardIndex, shards : [ST.ShardEntry]) : Result.Result<ST.ShardEvent, ST.ShardError> {
    if (shards.size() == 0) return #err(#InvalidRule({ reason = "a rule names at least one shard" }));
    if (shards.size() > ST.MAX_SHARDS) return #err(#InvalidRule({ reason = "at most " # Nat.toText(ST.MAX_SHARDS) # " shards: the identifier carries two digits" }));
    var selfListed = false;
    var i = 0;
    while (i < shards.size()) {
      let e = shards[i];
      if (e.index >= ST.MAX_SHARDS) return #err(#InvalidRule({ reason = "shard index " # Nat.toText(e.index) # " does not fit two digits" }));
      if (Principal.isAnonymous(e.principal)) return #err(#InvalidRule({ reason = "the anonymous principal is not a shard" }));
      if (Text.size(e.settlement) == 0) return #err(#InvalidRule({ reason = "every shard needs a settlement account here" }));
      if (e.index == self) selfListed := true;
      var j = i + 1;
      while (j < shards.size()) {
        if (shards[j].index == e.index) return #err(#InvalidRule({ reason = "shard index " # Nat.toText(e.index) # " listed twice" }));
        if (shards[j].principal == e.principal) return #err(#InvalidRule({ reason = "a principal listed twice" }));
        j += 1;
      };
      i += 1;
    };
    if (not selfListed) return #err(#InvalidRule({ reason = "the rule must list this contract's own index" }));
    // a later version keeps every index already declared: an issued identifier keeps its meaning
    switch (s.rule) {
      case (?r) {
        if (r.self != self) return #err(#InvalidRule({ reason = "this contract is shard " # Nat.toText(r.self) # " and cannot become another" }));
        for (old in r.shards.vals()) {
          var kept = false;
          for (e in shards.vals()) { if (e.index == old.index) kept := true };
          if (not kept) return #err(#InvalidRule({ reason = "shard " # Nat.toText(old.index) # " has issued identifiers and cannot be dropped" }));
        };
      };
      case null {};
    };
    let version = switch (s.rule) { case (?r) r.version + 1; case null 1 };
    #ok(#ruleDeclared({ version; self; shards }))
  };

  public func selfIndex(s : State) : ST.ShardIndex { switch (s.rule) { case (?r) r.self; case null 0 } };

  public func shard(s : State, index : ST.ShardIndex) : ?ST.ShardEntry {
    let ?r = s.rule else return null;
    for (e in r.shards.vals()) { if (e.index == index) return ?e };
    null
  };

  public func shardByPrincipal(s : State, p : Principal) : ?ST.ShardEntry {
    let ?r = s.rule else return null;
    for (e in r.shards.vals()) { if (e.principal == p) return ?e };
    null
  };

  /// The serial an account opened at `block` receives on this shard: the shard index in the
  /// first digits, the block in the rest. With no rule declared the serial is the block itself,
  /// which is shard 0's.
  public func serialFor(s : State, fmt : Iban.Format, block : Nat) : ?Nat {
    if (fmt.serialWidth <= ST.SHARD_DIGITS) return null;
    let width = fmt.serialWidth - ST.SHARD_DIGITS;
    if (block >= 10 ** width) return null;
    ?(selfIndex(s) * (10 ** width) + block)
  };

  /// The shard an identifier routes to: arithmetic on its serial.
  public func shardOf(fmt : Iban.Format, identifier : Text) : ?ST.ShardIndex {
    let ?serial = Iban.serialOf(fmt, identifier) else return null;
    if (fmt.serialWidth <= ST.SHARD_DIGITS) return null;
    ?(serial / (10 ** (fmt.serialWidth - ST.SHARD_DIGITS)))
  };

  // ─── transfers ───────────────────────────────────────────────────────────

  public func outbound(s : State, id : ST.TransferId) : ?ST.Outbound { Map.get(s.outbound, Nat.compare, id) };
  public func inbound(s : State, fromShard : ST.ShardIndex, transfer : ST.TransferId) : ?ST.Inbound { Map.get(s.inbound, cmp2, (fromShard, transfer)) };

  public func planSend(s : State, id : ST.TransferId) : Result.Result<ST.ShardEvent, ST.ShardError> {
    let ?t = outbound(s, id) else return #err(#UnknownTransfer({ transfer = id }));
    switch (t.status) {
      case (#open) #ok(#outboundSent({ transfer = id; attempt = 1 }));
      case (#sent(x)) #ok(#outboundSent({ transfer = id; attempt = x.attempts + 1 }));
      case (st) #err(#TransferNotIn({ transfer = id; status = ST.statusName(st); expected = "open or sent" }));
    }
  };

  /// The receiving shard's word: from the receiving shard's principal, for a transfer that was sent.
  public func planSettle(s : State, caller : Principal, id : ST.TransferId, receiverPosting : Nat) : Result.Result<(ST.ShardEvent, ST.Outbound), ST.ShardError> {
    let ?t = outbound(s, id) else return #err(#UnknownTransfer({ transfer = id }));
    let ?to = shard(s, t.toShard) else return #err(#UnknownShard({ shard = t.toShard }));
    if (caller != to.principal) return #err(#NotTheReceiver({ transfer = id; caller }));
    switch (t.status) {
      case (#sent(_)) #ok((#outboundSettled({ transfer = id; receiverPosting }), t));
      case (st) #err(#TransferNotIn({ transfer = id; status = ST.statusName(st); expected = "sent" }));
    }
  };

  public func planReturn(s : State, caller : Principal, id : ST.TransferId, reason : Text) : Result.Result<(ST.ShardEvent, ST.Outbound), ST.ShardError> {
    let ?t = outbound(s, id) else return #err(#UnknownTransfer({ transfer = id }));
    let ?to = shard(s, t.toShard) else return #err(#UnknownShard({ shard = t.toShard }));
    if (caller != to.principal) return #err(#NotTheReceiver({ transfer = id; caller }));
    switch (t.status) {
      case (#sent(_)) #ok((#outboundReturned({ transfer = id; reason }), t));
      case (st) #err(#TransferNotIn({ transfer = id; status = ST.statusName(st); expected = "sent" }));
    }
  };

  /// The idempotency key a received transfer posts under: one per (sending shard, transfer).
  public func inboundKey(fromShard : ST.ShardIndex, transfer : ST.TransferId) : Blob {
    let w = C.Writer();
    w.text("THEBES-BANK-SHARD-INBOUND-v1"); w.nat(fromShard); w.nat(transfer);
    Blob.fromArray(w.toArray())
  };

  // ─── the fold ─────────────────────────────────────────────────────────────

  public func apply(s : State, block : Nat, e : ST.ShardEvent) {
    switch (e) {
      case (#ruleDeclared(x)) { let r : ST.Rule = { version = x.version; self = x.self; shards = x.shards; declaredAt = block }; s.rule := ?r; List.add(s.versions, r) };
      case (#outboundOpened(x)) {
        Map.add(s.outbound, Nat.compare, block, { id = block; from = x.from; toIdentifier = x.toIdentifier; toShard = x.toShard; amount = x.amount; currency = x.currency; valueDay = x.valueDay; period = x.period; narration = x.narration; pendingIndex = x.pendingIndex; status = #open; lastBlock = block });
        s.openCount += 1;
      };
      case (#outboundSent(x)) { switch (outbound(s, x.transfer)) { case (?t) Map.add(s.outbound, Nat.compare, x.transfer, { t with status = #sent({ attempts = x.attempt }); lastBlock = block }); case null {} } };
      case (#outboundSettled(x)) { switch (outbound(s, x.transfer)) { case (?t) { Map.add(s.outbound, Nat.compare, x.transfer, { t with status = #settled({ receiverPosting = x.receiverPosting }); lastBlock = block }); s.openCount -= 1; s.settledCount += 1 }; case null {} } };
      case (#outboundReturned(x)) { switch (outbound(s, x.transfer)) { case (?t) { Map.add(s.outbound, Nat.compare, x.transfer, { t with status = #returned({ reason = x.reason }); lastBlock = block }); s.openCount -= 1; s.returnedCount += 1 }; case null {} } };
      case (#inboundPosted(x)) { Map.add(s.inbound, cmp2, (x.fromShard, x.transfer), { fromShard = x.fromShard; transfer = x.transfer; toAccount = x.toAccount; amount = x.amount; posting = x.posting; receivedAt = block }); s.inboundCount += 1 };
      case (#inboundRefused(_)) {};
    };
  };

  public func openTransfers(s : State, limit : Nat) : [ST.Outbound] {
    let out = List.empty<ST.Outbound>();
    label walk for ((_, t) in Map.entries(s.outbound)) {
      if (List.size(out) >= limit) break walk;
      switch (t.status) { case (#open or #sent(_)) List.add(out, t); case (_) {} };
    };
    List.toArray(out)
  };

  public func counts(s : State) : { open : Nat; settled : Nat; returned : Nat; inbound : Nat; version : Nat } {
    { open = s.openCount; settled = s.settledCount; returned = s.returnedCount; inbound = s.inboundCount; version = switch (s.rule) { case (?r) r.version; case null 0 } }
  };

  public func fingerprintInto(w : C.Writer, s : State) {
    switch (s.rule) { case (?r) { w.byte(1); w.nat(r.version); w.nat(r.self); w.nat(r.shards.size()); for (e in r.shards.vals()) { w.nat(e.index); w.principal(e.principal); w.text(e.settlement) } }; case null w.byte(0) };
    w.nat(Map.size(s.outbound));
    for ((id, t) in Map.entries(s.outbound)) { w.nat(id); w.nat(t.from); w.text(t.toIdentifier); w.nat(t.toShard); w.nat(t.amount); w.nat(t.pendingIndex); w.text(ST.statusName(t.status)); w.nat(t.lastBlock) };
    w.nat(Map.size(s.inbound));
    for (((f, id), x) in Map.entries(s.inbound)) { w.nat(f); w.nat(id); w.nat(x.toAccount); w.nat(x.amount); w.nat(x.posting) };
  };
}
