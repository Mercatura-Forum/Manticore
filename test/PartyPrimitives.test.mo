// PartyPrimitives.test.mo; commitments and account identifiers.
//
// Two of the three pure pieces party and KYC rests on, proved before the state machine uses
// them:
//
//   * a commitment is deterministic, salted, domain-separated, and sensitive to
//     every component; normalisation is the same in every caller and idempotent;
//   * IBAN generation and validation are one code path; every issued identifier
//     validates, the published ISO 13616 vectors pass, and corruptions are refused.
//
// The third piece, the screening proofs, is test/Screening.test.mo: it is
// hash-heavy and runs under WASI only, which that file states in its own header.

import Debug "mo:core/Debug";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Blob "mo:core/Blob";
import Array "mo:core/Array";
import Text "mo:core/Text";

import T "../src/bank/PartyTypes";
import C "../src/bank/Commitments";
import Iban "../src/bank/Iban";

// ═══════════════════════════════════════════════════════════════════════════
//  commitments
// ═══════════════════════════════════════════════════════════════════════════

func salt(n : Nat8) : Blob { Blob.fromArray(Array.tabulate<Nat8>(32, func(i) { Nat8.fromNat((Nat8.toNat(n) + i) % 256) })) };
let s1 = salt(1);
let s2 = salt(2);

assert C.validSalt(s1);
assert (not C.validSalt(Blob.fromArray([1, 2, 3])));

// deterministic and 32 bytes
let id1 = C.identity(s1, #natural, ["Mohamed Ahmed Hassan", "29801011234567"]);
assert (id1 == C.identity(s1, #natural, ["Mohamed Ahmed Hassan", "29801011234567"]));
assert C.validCommitment(id1);

// every component matters
var sensitivity = 0;
func differs(c : T.Commitment, why : Text) {
  if (c == id1) { Debug.print("commitment did not change: " # why); assert false };
  sensitivity += 1;
};
differs(C.identity(s2, #natural, ["Mohamed Ahmed Hassan", "29801011234567"]), "salt");
differs(C.identity(s1, #legal, ["Mohamed Ahmed Hassan", "29801011234567"]), "kind");
differs(C.identity(s1, #natural, ["Mohamed Ahmed Hassam", "29801011234567"]), "name");
differs(C.identity(s1, #natural, ["Mohamed Ahmed Hassan", "29801011234568"]), "identifier");
differs(C.identity(s1, #natural, ["Mohamed Ahmed Hassan"]), "tuple length");
differs(C.identity(s1, #natural, ["29801011234567", "Mohamed Ahmed Hassan"]), "tuple order");
Debug.print("count: identity commitment components proved to matter = " # Nat.toText(sensitivity));
assert (sensitivity == 6);

// domains do not collide: the same salt and value under different domains differ
let f1 = C.field(s1, "nationalId", "29801011234567");
let d1 = C.dedup(s1, "nationalId", "29801011234567");
let doc1 = C.document(s1, "nationalId", Blob.fromArray([1, 2, 3]));
assert (f1 != d1 and f1 != doc1 and d1 != doc1);
assert (f1 != C.field(s1, "passport", "29801011234567"));
Debug.print("count: commitment domain separations checked = 4");

// normalisation is the declared rule set
assert (C.normalise("  mohamed   ahmed  ") == "MOHAMED AHMED");
assert (C.normalise("Mohamed-Ahmed") == "MOHAMEDAHMED");
assert (C.normalise("O'Brien, J.") == "OBRIEN J");
assert (C.normalise("") == "");
assert (C.normalise("   ") == "");
assert (C.normalise("عبد الله") == "عبد الله");   // non-ASCII passes through
assert (C.field(s1, "n", "Mohamed Ahmed") == C.field(s1, "n", "  mohamed   ahmed  "));
Debug.print("count: normalisation cases = 7");

// the deduplication commitment is the same for two parties, by design, and the
// party commitment is not; the trade this module states rather than hides
let institution = salt(9);
assert (C.dedup(institution, "nationalId", "29801011234567") == C.dedup(institution, "nationalId", "29801011234567"));
assert (C.field(s1, "nationalId", "29801011234567") != C.field(s2, "nationalId", "29801011234567"));
Debug.print("count: deduplication-versus-party commitment checks = 2");

// ═══════════════════════════════════════════════════════════════════════════
//  IBAN
// ═══════════════════════════════════════════════════════════════════════════

// The published ISO 13616 example vectors.
let validVectors : [Text] = [
  "GB82WEST12345698765432",
  "DE89370400440532013000",
  "FR1420041010050500013M02606",
  "SA0380000000608010167519",
  "CH9300762011623852957",
  "GR1601101250000000012300695",
  "TR330006100519786457841326",
  "BE68539007547034",
  "NL91ABNA0417164300",
  "PL61109010140000071219812874",
];
var vectorsPassed = 0;
for (v in validVectors.vals()) {
  switch (Iban.validate(v)) {
    case null vectorsPassed += 1;
    case (?r) { Debug.print("published vector refused: " # v # " — " # r); assert false };
  };
};
Debug.print("count: published ISO 13616 vectors accepted = " # Nat.toText(vectorsPassed));
assert (vectorsPassed == validVectors.size());

// generation: every issued Egyptian identifier validates, is 29 characters and is
// distinct from every other
let fmt : Iban.Format = { country = "EG"; bank = "0037"; branch = "0001"; serialWidth = 12; prefix = "00000" };
assert (Iban.validateFormat(fmt) == null);
var issued : [Text] = [];
var issuedCount = 0;
var serial = 0;
while (serial < 1000) {
  switch (Iban.issue(fmt, serial)) {
    case (#ok(iban)) {
      assert (Text.toArray(iban).size() == 29);
      assert (Iban.isValid(iban));
      issued := Array.concat(issued, [iban]);
      issuedCount += 1;
    };
    case (#err(e)) { Debug.print("issue failed at serial " # Nat.toText(serial) # ": " # e); assert false };
  };
  serial += 1;
};
Debug.print("count: Egyptian identifiers issued and validated = " # Nat.toText(issuedCount));
assert (issuedCount == 1000);
// pairwise distinct
var collisions = 0;
var i = 0;
while (i < issued.size()) {
  var j = i + 1;
  while (j < issued.size()) { if (Text.equal(issued[i], issued[j])) collisions += 1; j += 1 };
  i += 1;
};
Debug.print("count: identifier pair comparisons = " # Nat.toText(issued.size() * (issued.size() - 1) / 2));
assert (collisions == 0);

// corruptions are refused: a changed digit, a transposition, a wrong check, a
// wrong length, a wrong country, a lower-case letter
var refusals = 0;
func refuse(iban : Text, why : Text) {
  switch (Iban.validate(iban)) {
    case (?_) refusals += 1;
    case null { Debug.print("accepted a bad identifier (" # why # "): " # iban); assert false };
  };
};
let good = issued[0];
let gcs = Text.toArray(good);
func replaceAt(cs : [Char], pos : Nat, c : Char) : Text {
  var out = "";
  var k = 0;
  while (k < cs.size()) { out #= Text.fromChar(if (k == pos) c else cs[k]); k += 1 };
  out
};
// every single-digit change in the account part must break the check
var pos = 4;
while (pos < gcs.size()) {
  let orig = gcs[pos];
  let other = if (orig == '0') '1' else '0';
  refuse(replaceAt(gcs, pos, other), "digit changed at " # Nat.toText(pos));
  pos += 1;
};
// transpositions of adjacent differing characters
pos := 4;
while (pos + 1 < gcs.size()) {
  if (gcs[pos] != gcs[pos + 1]) {
    var out = "";
    var k = 0;
    while (k < gcs.size()) {
      out #= Text.fromChar(if (k == pos) gcs[pos + 1] else if (k == pos + 1) gcs[pos] else gcs[k]);
      k += 1;
    };
    refuse(out, "transposition at " # Nat.toText(pos));
  };
  pos += 1;
};
refuse("EG000370001000000000000000000", "wrong check digits");
refuse("EG3700370001" , "too short for the profile");
refuse("XX820037000100000000000000001", "country with no profile and a bad check");
refuse("eg820037000100000000000000001", "lower-case country");
refuse(Text.replace(good, #text "EG", "E1"), "non-letter in the country code");
// and across the whole issued set: changing the last character or a middle one
// must always break the check
var broad = 0;
var q = 0;
while (q < 200) {
  let cs = Text.toArray(issued[q]);
  let last = cs.size() - 1;
  let mid = 14;
  for (pp in [last, mid].vals()) {
    let orig = cs[pp];
    let other = if (orig == '0') '7' else '0';
    let bad = replaceAt(cs, pp, other);
    switch (Iban.validate(bad)) {
      case (?_) broad += 1;
      case null { Debug.print("accepted a corrupted issued identifier: " # bad); assert false };
    };
  };
  q += 1;
};
Debug.print("count: corrupted identifiers refused = " # Nat.toText(refusals));
Debug.print("count: corrupted issued identifiers refused across the set = " # Nat.toText(broad));
assert (refusals >= 30);
assert (broad == 400);

// a serial that does not fit is refused rather than truncated
switch (Iban.issue({ fmt with serialWidth = 2 }, 1000)) {
  case (#err(_)) {};
  case (#ok(x)) { Debug.print("a serial that does not fit was issued: " # x); assert false };
};
// a format whose segments do not add up is refused
switch (Iban.validateFormat({ fmt with prefix = "0" })) {
  case (?_) {};
  case null { Debug.print("a malformed format was accepted"); assert false };
};
Debug.print("count: format refusals = 2");

// BIC
assert (Iban.validateBic("CIBEEGCXXXX") == null);
assert (Iban.validateBic("CIBEEGCX") == null);
var bicRefusals = 0;
for (b in ["CIBEEGC", "CIBEEGCXX", "cibeegcxxxx", "CIB1EGCXXXX", "CIBEE1CXXXX"].vals()) {
  switch (Iban.validateBic(b)) { case (?_) bicRefusals += 1; case null { Debug.print("bad BIC accepted: " # b); assert false } };
};
Debug.print("count: malformed BICs refused = " # Nat.toText(bicRefusals));
assert (bicRefusals == 5);

Debug.print("PARTY PRIMITIVES TEST GREEN");
