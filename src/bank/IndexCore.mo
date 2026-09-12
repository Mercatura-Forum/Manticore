/// IndexCore.mo — the indexing component's folded sub-state.
///
/// Small by design. Everything the indexes hold is **derived** from the journal's log and lives in
/// stable memory under `PostingIndex`, rebuildable from the log by replay; what is here is only the
/// declared configuration that gives a key its meaning, folded from the bank's own log like every
/// other sub-state in `BankCore.State`.

import List "mo:core/List";

import C "mo:journal/Canonical";
import IT "IndexTypes";

module {

  public type State = {
    /// The dimension I4 keys on, or null when none has been declared.
    var classDimension : ?IT.ClassDimension;
    /// Every declaration ever made, oldest first. A row written under an earlier dimension keeps
    /// its meaning, so the history is what lets a reader say which dimension a given class label
    /// came from.
    declarations : List.List<IT.ClassDimension>;
    var declarationCount : Nat;
  };

  public func newState() : State {
    { var classDimension = null; declarations = List.empty<IT.ClassDimension>(); var declarationCount = 0 }
  };

  public func apply(s : State, event : IT.IndexEvent) {
    switch (event) {
      case (#counterpartyClassDimensionSet(x)) {
        s.classDimension := x.dimension;
        switch (x.dimension) {
          case (?d) { List.add(s.declarations, d); s.declarationCount += 1 };
          case null {};
        };
      };
    }
  };

  public func classDimension(s : State) : ?IT.ClassDimension { s.classDimension };

  public func declarations(s : State) : [IT.ClassDimension] { List.toArray(s.declarations) };

  /// Fold this sub-state into the bank's state fingerprint, so a replay that produced a different
  /// declaration history is caught by the same comparison that catches every other divergence.
  public func fingerprintInto(w : C.Writer, s : State) {
    switch (s.classDimension) {
      case null w.byte(0);
      case (?d) { w.byte(1); w.text(d.schema); w.text(d.field) };
    };
    w.nat(s.declarationCount);
    for (d in List.values(s.declarations)) { w.text(d.schema); w.text(d.field) };
  };
}
