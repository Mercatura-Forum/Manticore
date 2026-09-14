/// Commitments.mo; how the canister verifies data it never holds.
///
/// A commitment is `SHA-256( domain ‖ salt ‖ normalised value )`, domain-separated
/// so a commitment for one purpose can never be replayed as a commitment for
/// another, and salted so that a small structured space; an Egyptian national
/// identity number is fourteen digits with a known shape; cannot be attacked by
/// dictionary.
///
/// The client submits the components; the canister recomputes and compares. A
/// mismatch is a typed refusal. Plaintext never enters an argument that reaches a
/// block, and the canister never learns it: the components it is given are the
/// salt (which it already has) and the commitment.
///
/// Two commitments exist per identifying field, for two different jobs:
///
///   * the **party commitment**, salted per party, which is the record; and
///   * the optional **deduplication commitment**, salted institution-wide per
///     identifier type, which answers "is this identifier already a customer".
///     That second one trades privacy for a control the bank needs, and the
///     trade is stated here rather than discovered: anyone holding the plaintext
///     identifier and the institution salt can test membership.
///
/// Normalisation is part of the commitment, so two clients that disagree about
/// whitespace or case produce different commitments and the mismatch is loud.
/// The rules are fixed here and named in the committed screening list, so a
/// claim about a list version is a claim about exact bytes.

import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Char "mo:core/Char";
import Nat8 "mo:core/Nat8";
import Text "mo:core/Text";
import Sha256 "mo:sha2/Sha256";

import T "PartyTypes";

module {

  public let IDENTITY_DOMAIN : Text = "THEBES-BANK-PARTY-IDENTITY-v1";
  public let FIELD_DOMAIN : Text = "THEBES-BANK-PARTY-FIELD-v1";
  public let DEDUP_DOMAIN : Text = "THEBES-BANK-PARTY-DEDUP-v1";
  public let DOCUMENT_DOMAIN : Text = "THEBES-BANK-DOCUMENT-v1";
  public let JUSTIFICATION_DOMAIN : Text = "THEBES-BANK-JUSTIFICATION-v1";
  public let LIST_ENTRY_DOMAIN : Text = "THEBES-BANK-SCREENING-ENTRY-v1";
  public let LIST_NODE_DOMAIN : Text = "THEBES-BANK-SCREENING-NODE-v1";

  /// The normalisation rule set, named in every committed list so that a version
  /// identifies exact bytes: trim, collapse internal runs of ASCII whitespace to
  /// one space, upper-case ASCII letters, and drop ASCII punctuation. Non-ASCII
  /// bytes pass through unchanged, because transliterating Arabic is a matching
  /// decision and belongs in the attested pass, not in a commitment.
  public let NORMALISATION : Text = "thebes-norm-v1: trim, collapse ASCII spaces, upper-case ASCII, drop ASCII punctuation";

  func isAsciiSpace(c : Char) : Bool { c == ' ' or c == '\t' or c == '\n' or c == '\r' };

  func isAsciiPunct(c : Char) : Bool {
    (c >= '!' and c <= '/') or (c >= ':' and c <= '@') or (c >= '[' and c <= '`') or (c >= '{' and c <= '~')
  };

  func upperAscii(c : Char) : Char {
    if (c >= 'a' and c <= 'z') Char.fromNat32(Char.toNat32(c) - 32) else c
  };

  /// Apply `NORMALISATION`. Pure, total, and the same in every caller.
  public func normalise(value : Text) : Text {
    var out = "";
    var pendingSpace = false;
    var started = false;
    for (c in value.chars()) {
      if (isAsciiSpace(c)) {
        if (started) pendingSpace := true;
      } else if (isAsciiPunct(c)) {
        // dropped; punctuation does not separate words for this purpose
      } else {
        if (pendingSpace) { out #= " "; pendingSpace := false };
        out #= Text.fromChar(upperAscii(c));
        started := true;
      };
    };
    out
  };

  func digest(domain : Text, parts : [Blob]) : Blob {
    let d = Sha256.Digest(#sha256);
    let db = Text.encodeUtf8(domain);
    // length-prefix the domain so no concatenation of a domain and a value can
    // collide with another domain and another value
    d.writeArray([Nat8.fromNat(db.size() / 256), Nat8.fromNat(db.size() % 256)]);
    d.writeBlob(db);
    for (p in parts.vals()) {
      d.writeArray([Nat8.fromNat(p.size() / 256), Nat8.fromNat(p.size() % 256)]);
      d.writeBlob(p);
    };
    d.sum()
  };

  /// The party's identity commitment: over the normalised identity tuple, under
  /// the party's own salt.
  public func identity(salt : Blob, kind : T.PartyKind, tuple : [Text]) : T.Commitment {
    let kindByte : Blob = Blob.fromArray([switch (kind) { case (#natural) 0; case (#legal) 1 }]);
    var parts : [Blob] = [salt, kindByte];
    for (t in tuple.vals()) { parts := appendBlob(parts, Text.encodeUtf8(normalise(t))) };
    digest(IDENTITY_DOMAIN, parts)
  };

  /// The attribute a screening proof is bound to. A party that is to be screened
  /// must carry it, so "this proof is about this party" is checkable rather than
  /// asserted.
  public let SCREENING_SUBJECT : Text = "screeningSubject";

  /// One named field of the record.
  public func field(salt : Blob, name : Text, value : Text) : T.Commitment {
    fieldBytes(salt, name, Text.encodeUtf8(normalise(value)))
  };

  /// The same commitment from bytes that are **already normalised**; which is
  /// what a screening subject is, because the list it is checked against is
  /// sorted in normalised order. `normalise` is idempotent, so
  /// `fieldBytes(salt, n, encodeUtf8(normalise(v))) == field(salt, n, v)`; the
  /// battery asserts that rather than trusting it.
  public func fieldBytes(salt : Blob, name : Text, normalisedValue : Blob) : T.Commitment {
    digest(FIELD_DOMAIN, [salt, Text.encodeUtf8(name), normalisedValue])
  };

  /// The institution-wide deduplication commitment for one identifier type.
  public func dedup(institutionSalt : Blob, identifierType : Text, value : Text) : T.Commitment {
    digest(DEDUP_DOMAIN, [institutionSalt, Text.encodeUtf8(identifierType), Text.encodeUtf8(normalise(value))])
  };

  public func document(salt : Blob, kind : Text, contentHash : Blob) : T.Commitment {
    digest(DOCUMENT_DOMAIN, [salt, Text.encodeUtf8(kind), contentHash])
  };

  public func justification(text : Text) : T.Commitment {
    digest(JUSTIFICATION_DOMAIN, [Text.encodeUtf8(text)])
  };

  /// A leaf of a committed screening list: the normalised entry, domain-separated
  /// so a leaf can never be read as an interior node.
  public func listLeaf(entry : Blob) : T.Commitment { digest(LIST_ENTRY_DOMAIN, [entry]) };

  /// An interior node of a committed screening list.
  public func listNode(left : Blob, right : Blob) : T.Commitment { digest(LIST_NODE_DOMAIN, [left, right]) };

  func appendBlob(xs : [Blob], x : Blob) : [Blob] {
    Array.tabulate<Blob>(xs.size() + 1, func(i) { if (i < xs.size()) xs[i] else x })
  };

  public func validCommitment(c : T.Commitment) : Bool { c.size() == T.COMMITMENT_BYTES };
  public func validSalt(s : Blob) : Bool { s.size() == T.SALT_BYTES };
};
