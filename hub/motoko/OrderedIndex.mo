/// OrderedIndex.mo -- deterministic ordered secondary-index contract.
///
/// This is a small sorted-entry index used by the hub today and designed to be
/// replaced by a Region-backed BTree without changing query semantics.

import Array "mo:core/Array";
import Int "mo:core/Int";
import Nat "mo:core/Nat";
import Text "mo:core/Text";

module {

  public type Entry = {
    key : Text;
    id : Nat;
  };

  public type Index = {
    entries : [Entry];
  };

  public type InvariantReport = {
    ok : Bool;
    issueCount : Nat;
    issues : [Text];
  };

  public func empty() : Index {
    { entries = [] };
  };

  public func size(index : Index) : Nat {
    index.entries.size();
  };

  public func replace(index : Index, key : Text, id : Nat) : Index {
    insert(removeId(index, id), key, id);
  };

  public func removeId(index : Index, id : Nat) : Index {
    { entries = Array.filter<Entry>(index.entries, func(e) { e.id != id }) };
  };

  public func insert(index : Index, key : Text, id : Nat) : Index {
    var out : [Entry] = [];
    var inserted = false;
    for (entry in index.entries.vals()) {
      if (entry.key == key and entry.id == id) {
        inserted := true;
      };
      if (not inserted and before({ key; id }, entry)) {
        out := Array.concat<Entry>(out, [{ key; id }]);
        inserted := true;
      };
      if (not (entry.key == key and entry.id == id)) {
        out := Array.concat<Entry>(out, [entry]);
      };
    };
    if (not inserted) {
      out := Array.concat<Entry>(out, [{ key; id }]);
    };
    { entries = out };
  };

  public func range(index : Index, fromInclusive : Text, toExclusive : Text, offset : Nat, limit : Nat) : [Nat] {
    var out : [Nat] = [];
    var skipped = 0;
    for (entry in index.entries.vals()) {
      if (textGte(entry.key, fromInclusive) and textLt(entry.key, toExclusive)) {
        if (skipped < offset) {
          skipped += 1;
        } else if (out.size() < limit) {
          out := Array.concat<Nat>(out, [entry.id]);
        };
      };
    };
    out;
  };

  public func prefix(index : Index, prefixText : Text, offset : Nat, limit : Nat) : [Nat] {
    var out : [Nat] = [];
    var skipped = 0;
    for (entry in index.entries.vals()) {
      if (Text.startsWith(entry.key, #text prefixText)) {
        if (skipped < offset) {
          skipped += 1;
        } else if (out.size() < limit) {
          out := Array.concat<Nat>(out, [entry.id]);
        };
      };
    };
    out;
  };

  public func verify(index : Index) : InvariantReport {
    var issues : [Text] = [];
    var prev : ?Entry = null;
    for (entry in index.entries.vals()) {
      switch (prev) {
        case (?p) {
          if (not before(p, entry)) {
            issues := Array.concat<Text>(issues, ["index entries must be strictly sorted and unique"]);
          };
        };
        case null {};
      };
      prev := ?entry;
    };
    { ok = issues.size() == 0; issueCount = issues.size(); issues };
  };

  public func keyPart(value : Text) : Text {
    escape(value) # "|";
  };

  public func natPart(value : Nat) : Text {
    padNat(value, 20) # "|";
  };

  public func intPart(value : Int) : Text {
    if (value < 0) {
      "0" # padNat(Int.abs(value), 20) # "|";
    } else {
      "1" # padNat(Int.abs(value), 20) # "|";
    };
  };

  public func lower(parts : [Text]) : Text {
    join(parts);
  };

  public func upper(parts : [Text]) : Text {
    join(parts) # "~";
  };

  public func join(parts : [Text]) : Text {
    var out = "";
    for (p in parts.vals()) {
      out #= p;
    };
    out;
  };

  func before(a : Entry, b : Entry) : Bool {
    switch (Text.compare(a.key, b.key)) {
      case (#less) true;
      case (#equal) a.id < b.id;
      case (#greater) false;
    };
  };

  func textLt(a : Text, b : Text) : Bool {
    switch (Text.compare(a, b)) {
      case (#less) true;
      case _ false;
    };
  };

  func textGte(a : Text, b : Text) : Bool {
    switch (Text.compare(a, b)) {
      case (#less) false;
      case _ true;
    };
  };

  func padNat(value : Nat, width : Nat) : Text {
    let raw = Nat.toText(value);
    var out = raw;
    while (Text.size(out) < width) {
      out := "0" # out;
    };
    out;
  };

  func escape(value : Text) : Text {
    let out = Text.replace(value, #text "\\", "\\\\");
    Text.replace(out, #text "|", "\\p");
  };
};
