// Screening.test.mo — absence from a committed list is provable.
//
// The verifiable half of party and KYC's screening design: a sorted Merkle commitment over a
// normalised list, inclusion proofs for every entry, non-membership by adjacency in
// all three shapes (below the first entry, between two, above the last), membership
// reported as membership rather than as a failed proof, and every way of tampering
// with a proof refused.
//
// engine: wasi-only — seven hundred Merkle proofs over a 500-leaf tree, each with
// dozens of SHA-256 calls. Under `moc -r` it does not finish in a useful time (the
// run was killed after four minutes with its output frozen), the same reason the
// journal's own core battery is exempted for being quadratic in the interpreter.
// Its proof is the WASI run alone, and that is said here, in the component record
// and in the release note rather than left to be noticed.

import Debug "mo:core/Debug";
import Nat "mo:core/Nat";
import Blob "mo:core/Blob";
import Array "mo:core/Array";
import Text "mo:core/Text";

import T "../src/bank/PartyTypes";
import C "../src/bank/Commitments";
import S "../src/bank/Screening";

func entry(t : Text) : Blob { S.entryBytes(t) };

// a sorted, normalised, deduplicated list
var raw : [Text] = [];
var n = 0;
while (n < 500) { raw := Array.concat(raw, ["LISTED PERSON " # Nat.toText(1000 + n)]); n += 1 };
var entries = Array.map<Text, Blob>(raw, entry);
entries := Array.sort<Blob>(entries, func(a, b) {
  switch (S.compareEntries(a, b)) { case (#less) #less; case (#equal) #equal; case (#greater) #greater }
});
assert (S.validateSorted(entries) == null);
let ?listRoot = S.root(entries) else { Debug.print("no root"); assert false; loop {} };
let list : T.ScreeningList = {
  version = "UN-2026-09"; root = listRoot; count = entries.size();
  normalisation = C.NORMALISATION; committedAtBlock = 1;
};
Debug.print("count: screening list entries committed = " # Nat.toText(list.count));

// every entry's inclusion proof reaches the root
var inclusions = 0;
var k = 0;
while (k < entries.size()) {
  let ?p = S.path(entries, k) else { assert false; loop {} };
  assert (S.verifyInclusion(entries[k], k, p, list.count, list.root));
  inclusions += 1;
  k += 1;
};
Debug.print("count: inclusion proofs verified = " # Nat.toText(inclusions));
assert (inclusions == entries.size());

// absence is provable for subjects below, between and above the list
var absences = 0;
var below = 0; var between = 0; var above = 0;
var m = 0;
while (m < 200) {
  // A mix on purpose: below the first entry, above the last, and strictly
  // between two neighbours — the three shapes the proof must handle.
  let subject = if (m % 10 == 0) entry("AAA ABSENT " # Nat.toText(m))
    else if (m % 10 == 1) entry("ZZZ ABSENT " # Nat.toText(m))
    else entry("LISTED PERSON " # Nat.toText(1000 + m) # "A");
  let ?proof = S.adjacencyProof(entries, subject) else { Debug.print("no proof for an absent subject"); assert false; loop {} };
  switch (S.verifyNonMembership(subject, proof, list)) {
    case (#absent) {
      absences += 1;
      switch (proof.lower, proof.upper) {
        case (null, ?_) below += 1;
        case (?_, null) above += 1;
        case (?_, ?_) between += 1;
        case (null, null) { assert false };
      };
    };
    case (x) { Debug.print("absent subject not proved absent: " # debug_show (x)); assert false };
  };
  m += 1;
};
Debug.print("count: non-membership proofs verified = " # Nat.toText(absences));
Debug.print("count: proofs with the subject below the first entry = " # Nat.toText(below));
Debug.print("count: proofs with the subject between two entries = " # Nat.toText(between));
Debug.print("count: proofs with the subject above the last entry = " # Nat.toText(above));
assert (absences == 200);
assert (below > 0 and between > 0 and above > 0);

// a subject that IS on the list is reported present, not as a failed proof
var presents = 0;
k := 0;
while (k < 50) {
  let subject = entries[k * 10 % entries.size()];
  // a publisher cannot build an absence proof for a present subject
  assert (S.adjacencyProof(entries, subject) == null);
  // and a hand-built bracket around it is reported present
  let idx = k * 10 % entries.size();
  if (idx > 0 and idx + 1 < entries.size()) {
    let ?lp = S.path(entries, idx - 1) else { assert false; loop {} };
    let ?up = S.path(entries, idx) else { assert false; loop {} };
    let proof : T.AdjacencyProof = {
      lower = ?{ entry = entries[idx - 1]; index = idx - 1; path = lp };
      upper = ?{ entry = entries[idx]; index = idx; path = up };
    };
    switch (S.verifyNonMembership(subject, proof, list)) {
      case (#present) presents += 1;
      case (x) { Debug.print("a listed subject was not reported present: " # debug_show (x)); assert false };
    };
  };
  k += 1;
};
Debug.print("count: listed subjects reported present = " # Nat.toText(presents));
assert (presents > 40);

// every way of tampering with a proof is refused
var tampers = 0;
func mustInvalid(p : T.AdjacencyProof, subject : Blob, why : Text) {
  switch (S.verifyNonMembership(subject, p, list)) {
    case (#invalid(_)) tampers += 1;
    case (x) { Debug.print("tampered proof accepted (" # why # "): " # debug_show (x)); assert false };
  };
};
let subj = entry("LISTED PERSON 1007A");
let ?base = S.adjacencyProof(entries, subj) else { assert false; loop {} };
switch (base.lower, base.upper) {
  case (?l, ?u) {
    // non-adjacent neighbours
    let ?p2 = S.path(entries, u.index + 1) else { assert false; loop {} };
    mustInvalid({ lower = ?l; upper = ?{ entry = entries[u.index + 1]; index = u.index + 1; path = p2 } }, subj, "non-adjacent");
    // a lower neighbour that does not sort below the subject
    mustInvalid({ lower = ?{ u with index = l.index }; upper = ?u }, subj, "lower above the subject");
    // a path from the wrong index
    mustInvalid({ lower = ?{ l with path = p2 }; upper = ?u }, subj, "wrong path");
    // a claimed index past the end
    mustInvalid({ lower = ?l; upper = ?{ u with index = list.count } }, subj, "index past the end");
    // a missing neighbour in the middle of the list
    mustInvalid({ lower = null; upper = ?u }, subj, "missing lower neighbour");
    mustInvalid({ lower = ?l; upper = null }, subj, "missing upper neighbour");
    mustInvalid({ lower = null; upper = null }, subj, "no neighbours at all");
    // a proof against a different root
    let otherList : T.ScreeningList = { list with root = C.listLeaf(entry("something else")) };
    switch (S.verifyNonMembership(subj, base, otherList)) {
      case (#invalid(_)) tampers += 1;
      case (x) { Debug.print("proof accepted against a different root: " # debug_show (x)); assert false };
    };
    // A count that puts the upper neighbour out of range is refused. (A count
    // *larger* than the real one is not a soundness hole and is not asserted to
    // be refused: the entry count comes from the recorded list, not from the
    // prover, and for a bracketed subject the argument rests on the two leaves
    // being included under the committed root and adjacent — which they still
    // are. The count binds the two edge shapes, "nothing below the first" and
    // "nothing above the last", and the index bounds.)
    switch (S.verifyNonMembership(subj, base, { list with count = u.index })) {
      case (#invalid(_)) tampers += 1;
      case (x) { Debug.print("proof accepted with the upper neighbour out of range: " # debug_show (x)); assert false };
    };
  };
  case _ { Debug.print("expected a bracketed subject"); assert false };
};
Debug.print("count: tampered non-membership proofs refused = " # Nat.toText(tampers));
assert (tampers == 9);

// a path with a spare sibling is not this path
let ?p0 = S.path(entries, 0) else { assert false; loop {} };
assert (not S.verifyInclusion(entries[0], 0, Array.concat(p0, [p0[0]]), list.count, list.root));
assert (not S.verifyInclusion(entries[0], 0, [], list.count, list.root));
Debug.print("count: malformed inclusion paths refused = 2");

// an unsorted or duplicated list is refused rather than committed
assert (S.validateSorted([entry("B"), entry("A")]) != null);
assert (S.validateSorted([entry("A"), entry("A")]) != null);
assert (S.root([]) == null);
Debug.print("count: list validation refusals = 3");

// the empty list: nothing is on it, and it admits no neighbours
let emptyList : T.ScreeningList = { version = "empty"; root = C.listLeaf(entry("x")); count = 0; normalisation = C.NORMALISATION; committedAtBlock = 1 };
switch (S.verifyNonMembership(subj, { lower = null; upper = null }, emptyList)) {
  case (#absent) {};
  case (x) { Debug.print("empty list: " # debug_show (x)); assert false };
};
Debug.print("count: empty-list checks = 1");

// the screening state gate
var permits = 0;
for (st in [#clear({ listVersion = "v"; at = 1 }), #cleared({ listVersion = "v"; at = 1; reason = "r" })].vals()) {
  assert (S.permitsMovement(st)); permits += 1;
};
for (st in [#unscreened, #hit({ listVersion = "v"; matches = 1; at = 1 }), #confirmed({ listVersion = "v"; at = 1 }), #rescreenDue({ since = "v2" })].vals()) {
  assert (not S.permitsMovement(st)); permits += 1;
};
Debug.print("count: screening states classified = " # Nat.toText(permits));
assert (permits == 6);

Debug.print("SCREENING TEST GREEN");
