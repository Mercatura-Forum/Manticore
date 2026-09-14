/// Screening.mo: what is verifiable about a sanctions check, and what is not.
///
/// Real screening is fuzzy: transliteration, phonetic matching, aliases, partial
/// dates of birth. That cannot be an on-chain exact-match proof, and pretending
/// otherwise would be the "structural validation standing in for a real check"
/// pattern. So the two layers are separated explicitly, and only one of them
/// makes a claim this module can enforce.
///
/// **Layer 1, verifiable.** A screening list is normalised, sorted and committed
/// as a sorted Merkle tree; the root, the version, the entry count and the
/// normalisation rule set are recorded in a block. A party's normalised identity
/// is then proven *absent* by an adjacency proof: the two neighbouring leaves
/// that bracket it, each with its inclusion path. The canister verifies the
/// proof. "This party was not on list version V" becomes a property a third party
/// recomputes. This is the mechanism Certificate Transparency (RFC 6962) uses for
/// a consistency claim and Revocation Transparency for non-membership.
///
/// **Layer 2, attested.** The fuzzy pass runs in the institution's screening
/// system and its result is recorded as an attributable decision naming the
/// screener, the list version, the list root, the match count and a commitment to
/// the justification. What the chain then guarantees is attribution, ordering and
/// tamper-evidence, and that the recorded consequences are enforced; a `#hit`
/// blocks money movement. It does **not** guarantee that the fuzzy match was
/// good. That sentence belongs in the release note and in the sales material in
/// the same words it appears in here.
///
/// The tree: leaves are `Commitments.listLeaf(entry)` over the normalised entry
/// bytes; interior nodes are `Commitments.listNode(left, right)`; an odd node at
/// a level is promoted unchanged. Leaf and node use different domains, so a leaf
/// can never be read as an interior node (the second-preimage weakness a single
/// domain would leave open).

import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Nat "mo:core/Nat";
import List "mo:core/List";
import Text "mo:core/Text";

import T "PartyTypes";
import C "Commitments";

module {

  /// Bytewise comparison of two entries, which is the order the list is sorted in
  /// and therefore the order an adjacency proof is read against.
  public func compareEntries(a : Blob, b : Blob) : { #less; #equal; #greater } {
    let xs = Blob.toArray(a);
    let ys = Blob.toArray(b);
    let n = if (xs.size() < ys.size()) xs.size() else ys.size();
    var i = 0;
    while (i < n) {
      if (xs[i] < ys[i]) return #less;
      if (xs[i] > ys[i]) return #greater;
      i += 1;
    };
    if (xs.size() < ys.size()) #less else if (xs.size() > ys.size()) #greater else #equal
  };

  /// The normalised bytes of a list entry or of a subject. The same function for
  /// both, because a comparison between differently normalised values is
  /// meaningless.
  public func entryBytes(value : Text) : Blob { Text.encodeUtf8(C.normalise(value)) };

  /// Build the committed root of a sorted list. The caller must pass the entries
  /// already sorted and free of duplicates; `validateSorted` checks that, and the
  /// canister refuses a list that fails it rather than committing to an order it
  /// cannot rely on.
  public func root(entries : [Blob]) : ?Blob {
    if (entries.size() == 0) return null;
    var level = Array.map<Blob, Blob>(entries, func(e) { C.listLeaf(e) });
    while (level.size() > 1) {
      let next = List.empty<Blob>();
      var i = 0;
      while (i < level.size()) {
        if (i + 1 < level.size()) { List.add(next, C.listNode(level[i], level[i + 1])) }
        else { List.add(next, level[i]) };   // promoted unchanged
        i += 2;
      };
      level := List.toArray(next);
    };
    ?level[0]
  };

  public func validateSorted(entries : [Blob]) : ?Text {
    var i = 1;
    while (i < entries.size()) {
      switch (compareEntries(entries[i - 1], entries[i])) {
        case (#less) {};
        case (#equal) return ?("duplicate entry at index " # Nat.toText(i));
        case (#greater) return ?("entry at index " # Nat.toText(i) # " is out of order");
      };
      i += 1;
    };
    for (e in entries.vals()) {
      if (e.size() == 0) return ?"an empty entry cannot be committed";
      if (e.size() > T.MAX_LIST_ENTRY_BYTES) return ?"an entry exceeds the bound";
    };
    null
  };

  /// The inclusion path for `index` in a list of `entries`. Used by a list
  /// publisher and by the tests; a verifier only ever checks a path it is given.
  public func path(entries : [Blob], index : Nat) : ?[Blob] {
    if (index >= entries.size()) return null;
    var level = Array.map<Blob, Blob>(entries, func(e) { C.listLeaf(e) });
    var idx = index;
    let out = List.empty<Blob>();
    while (level.size() > 1) {
      if (idx % 2 == 1) { List.add(out, level[idx - 1]) }
      else if (idx + 1 < level.size()) { List.add(out, level[idx + 1]) };
      // else: promoted, no sibling
      let next = List.empty<Blob>();
      var i = 0;
      while (i < level.size()) {
        if (i + 1 < level.size()) { List.add(next, C.listNode(level[i], level[i + 1])) }
        else { List.add(next, level[i]) };
        i += 2;
      };
      level := List.toArray(next);
      idx /= 2;
    };
    ?List.toArray(out)
  };

  /// Recompute the root from a leaf, its index, its path and the list's size.
  /// The size is what tells the verifier where a node was promoted, so a path
  /// cannot be replayed against a different list size.
  public func rootFromPath(entry : Blob, index : Nat, p : [Blob], count : Nat) : ?Blob {
    if (count == 0 or index >= count) return null;
    if (p.size() > T.MAX_ADJACENCY_PATH) return null;
    var h = C.listLeaf(entry);
    var idx = index;
    var width = count;
    var used = 0;
    while (width > 1) {
      if (idx % 2 == 1) {
        if (used >= p.size()) return null;
        h := C.listNode(p[used], h);
        used += 1;
      } else if (idx + 1 < width) {
        if (used >= p.size()) return null;
        h := C.listNode(h, p[used]);
        used += 1;
      };
      idx /= 2;
      width := (width + 1) / 2;
    };
    if (used != p.size()) return null;   // a path with spare siblings is not this path
    ?h
  };

  public func verifyInclusion(entry : Blob, index : Nat, p : [Blob], count : Nat, expected : Blob) : Bool {
    switch (rootFromPath(entry, index, p, count)) { case (?h) h == expected; case null false }
  };

  /// Verify that `subject` is **absent** from the committed list.
  ///
  /// `list` is the *recorded* list; its root, count and version come from a
  /// block, not from the prover; which is what the argument rests on. The count
  /// binds the two edge shapes ("nothing sorts below the first entry", "nothing
  /// sorts above the last") and the index bounds; for a subject bracketed by two
  /// neighbours the argument is that both leaves are included under the committed
  /// root and are adjacent, and that holds whatever the count is.
  ///
  /// The proof must show the two entries that bracket it and that they are
  /// adjacent, so there is no room between them for the subject. Three shapes are
  /// legitimate and each is checked on its own terms: the subject sorts before
  /// the first entry, after the last, or strictly between two neighbours. A
  /// subject equal to an entry is a membership, reported as such rather than as a
  /// failed proof.
  public func verifyNonMembership(subject : Blob, proof : T.AdjacencyProof, list : T.ScreeningList) : { #absent; #present; #invalid : Text } {
    if (list.count == 0) {
      switch (proof.lower, proof.upper) {
        case (null, null) return #absent;    // nothing is on an empty list
        case _ return #invalid("an empty list admits no neighbours");
      };
    };
    switch (proof.lower, proof.upper) {
      case (null, ?u) {
        if (u.index != 0) return #invalid("with no lower neighbour the upper neighbour must be the first entry");
        switch (compareEntries(subject, u.entry)) {
          case (#less) {};
          case (#equal) return #present;
          case (#greater) return #invalid("the subject is not below the first entry");
        };
        if (not verifyInclusion(u.entry, u.index, u.path, list.count, list.root)) return #invalid("the upper neighbour's inclusion proof does not reach the list root");
        #absent
      };
      case (?l, null) {
        if (l.index != list.count - 1) return #invalid("with no upper neighbour the lower neighbour must be the last entry");
        switch (compareEntries(l.entry, subject)) {
          case (#less) {};
          case (#equal) return #present;
          case (#greater) return #invalid("the subject is not above the last entry");
        };
        if (not verifyInclusion(l.entry, l.index, l.path, list.count, list.root)) return #invalid("the lower neighbour's inclusion proof does not reach the list root");
        #absent
      };
      case (?l, ?u) {
        if (u.index != l.index + 1) return #invalid("the neighbours are not adjacent");
        if (u.index >= list.count) return #invalid("the upper neighbour is past the end of the list");
        switch (compareEntries(l.entry, subject)) {
          case (#less) {};
          case (#equal) return #present;
          case (#greater) return #invalid("the lower neighbour does not sort below the subject");
        };
        switch (compareEntries(subject, u.entry)) {
          case (#less) {};
          case (#equal) return #present;
          case (#greater) return #invalid("the upper neighbour does not sort above the subject");
        };
        if (not verifyInclusion(l.entry, l.index, l.path, list.count, list.root)) return #invalid("the lower neighbour's inclusion proof does not reach the list root");
        if (not verifyInclusion(u.entry, u.index, u.path, list.count, list.root)) return #invalid("the upper neighbour's inclusion proof does not reach the list root");
        #absent
      };
      case (null, null) #invalid("a non-empty list needs at least one neighbour");
    }
  };

  /// Build the adjacency proof for a subject against a sorted entry set. A list
  /// publisher produces this; the canister only verifies.
  public func adjacencyProof(entries : [Blob], subject : Blob) : ?T.AdjacencyProof {
    var lowerIdx : ?Nat = null;
    var upperIdx : ?Nat = null;
    var i = 0;
    while (i < entries.size()) {
      switch (compareEntries(entries[i], subject)) {
        case (#less) lowerIdx := ?i;
        case (#equal) return null;            // the subject is present; there is no proof of absence
        case (#greater) { if (upperIdx == null) upperIdx := ?i };
      };
      i += 1;
    };
    func side(o : ?Nat) : ?{ entry : Blob; index : Nat; path : [Blob] } {
      switch (o) {
        case null null;
        case (?idx) {
          switch (path(entries, idx)) {
            case (?p) ?{ entry = entries[idx]; index = idx; path = p };
            case null null;
          }
        };
      }
    };
    ?{ lower = side(lowerIdx); upper = side(upperIdx) }
  };

  /// Does this screening state permit money to move?
  public func permitsMovement(s : T.ScreeningState) : Bool {
    switch (s) {
      case (#clear(_)) true;
      case (#cleared(_)) true;
      case (#unscreened) false;
      case (#hit(_)) false;
      case (#confirmed(_)) false;
      case (#rescreenDue(_)) false;
    }
  };

  public func stateText(s : T.ScreeningState) : Text {
    switch (s) {
      case (#unscreened) "unscreened";
      case (#clear(_)) "clear";
      case (#hit(_)) "hit";
      case (#cleared(_)) "cleared";
      case (#confirmed(_)) "confirmed";
      case (#rescreenDue(_)) "rescreenDue";
    }
  };
};
