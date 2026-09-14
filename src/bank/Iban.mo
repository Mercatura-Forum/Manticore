/// Iban.mo; account identifiers: ISO 13616 (IBAN) and ISO 9362 (BIC).
///
/// The hub already *validates* Egyptian IBAN shape; what a core-banking system measures
/// and what a bank actually needs is **generation** under a declared policy. The
/// rule here is that an identifier we issue and an identifier we receive go
/// through one code path: `generate` ends by calling `validate` on its own output
/// and traps if it disagrees, so a generator bug cannot produce an identifier the
/// validator would later reject.
///
/// The check is ISO 13616's mod-97-10: move the first four characters to the end,
/// map letters to two digits (A = 10 … Z = 35), and read the result as one long
/// decimal number; a valid IBAN leaves remainder 1. Generation forms the same
/// string with check digits "00" and takes 98 − (n mod 97).
///
/// A country profile fixes the length and the segment layout. Egypt's national
/// structure is 29 characters: EG, two check digits, a four-digit bank code, a
/// four-digit branch code and a seventeen-character account identifier.

import Array "mo:core/Array";
import Char "mo:core/Char";
import Nat "mo:core/Nat";
import Nat32 "mo:core/Nat32";
import Text "mo:core/Text";

module {

  public type Segment = { name : Text; length : Nat; kind : { #digits; #alnum } };

  public type CountryProfile = {
    country : Text;          // two upper-case ASCII letters
    length : Nat;            // total IBAN length including the country and check digits
    segments : [Segment];    // the BBAN layout, in order, after the check digits
  };

  /// The profiles this module knows. A country without a profile is a typed
  /// refusal, never a guess at its length.
  public func profiles() : [CountryProfile] {
    [
      {
        country = "EG"; length = 29;
        segments = [
          { name = "bank"; length = 4; kind = #digits },
          { name = "branch"; length = 4; kind = #digits },
          { name = "account"; length = 17; kind = #alnum },
        ];
      },
    ]
  };

  public func profile(country : Text) : ?CountryProfile {
    for (p in profiles().vals()) { if (Text.equal(p.country, country)) return ?p };
    null
  };

  func isDigit(c : Char) : Bool { c >= '0' and c <= '9' };
  func isUpper(c : Char) : Bool { c >= 'A' and c <= 'Z' };
  func isAlnum(c : Char) : Bool { isDigit(c) or isUpper(c) };

  /// A character's numeric value for the mod-97 computation: a digit is itself,
  /// a letter is 10 + its position. Returns null for anything else.
  func value(c : Char) : ?Nat {
    if (isDigit(c)) return ?(Nat32ToNat(Char.toNat32(c)) - 48);
    if (isUpper(c)) return ?(Nat32ToNat(Char.toNat32(c)) - 65 + 10);
    null
  };

  func Nat32ToNat(n : Nat32) : Nat { Nat.fromNat32 n };

  /// mod 97 of the digit expansion of `s`, computed incrementally so no large
  /// integer is built. Null if `s` carries a character that is not a digit or an
  /// upper-case ASCII letter.
  public func mod97(s : Text) : ?Nat {
    var acc : Nat = 0;
    for (c in s.chars()) {
      let ?v = value(c) else return null;
      acc := if (v < 10) (acc * 10 + v) % 97 else (acc * 100 + v) % 97;
    };
    ?acc
  };

  /// Validate an IBAN against ISO 13616 and, when the country has a profile,
  /// against that profile's length and segment layout. Returns a reason on
  /// rejection so a refusal says which rule failed.
  public func validate(iban : Text) : ?Text {
    let cs = Text.toArray(iban);
    if (cs.size() < 5) return ?"shorter than the shortest possible IBAN";
    if (cs.size() > 34) return ?"longer than the ISO 13616 maximum of 34";
    if (not (isUpper(cs[0]) and isUpper(cs[1]))) return ?"the first two characters must be an upper-case country code";
    if (not (isDigit(cs[2]) and isDigit(cs[3]))) return ?"characters three and four must be the check digits";
    var i = 4;
    while (i < cs.size()) {
      if (not isAlnum(cs[i])) return ?"the account part must be digits or upper-case letters";
      i += 1;
    };
    let country = charsToText(Array.tabulate<Char>(2, func(j) { cs[j] }));
    switch (profile(country)) {
      case (?p) {
        if (cs.size() != p.length) return ?("country " # country # " requires " # Nat.toText(p.length) # " characters");
        var pos = 4;
        for (seg in p.segments.vals()) {
          var k = 0;
          while (k < seg.length) {
            let c = cs[pos + k];
            switch (seg.kind) {
              case (#digits) { if (not isDigit(c)) return ?("segment " # seg.name # " must be digits") };
              case (#alnum) { if (not isAlnum(c)) return ?("segment " # seg.name # " must be digits or upper-case letters") };
            };
            k += 1;
          };
          pos += seg.length;
        };
        if (pos != p.length) return ?("profile for " # country # " does not account for every character");
      };
      case null {};   // no profile: ISO 13616 structure and the check digits only
    };
    // rearranged: everything from position 4 onwards, then the first four
    let rearranged = charsToText(Array.tabulate<Char>(cs.size(), func(j) {
      if (j < cs.size() - 4) cs[j + 4] else cs[j - (cs.size() - 4)]
    }));
    let ?m = mod97(rearranged) else return ?"unexpected character in the mod-97 expansion";
    if (m != 1) return ?("mod-97 check failed (remainder " # Nat.toText(m) # ", expected 1)");
    null
  };

  public func isValid(iban : Text) : Bool { validate(iban) == null };

  /// Generate an IBAN from a country and a BBAN. The BBAN must already match the
  /// country's profile; the check digits are computed. The result is validated
  /// before it is returned, so `generate` and `validate` can never disagree.
  public func generate(country : Text, bban : Text) : { #ok : Text; #err : Text } {
    if (Text.toArray(country).size() != 2) return #err("the country code must be two characters");
    for (c in country.chars()) { if (not isUpper(c)) return #err("the country code must be upper-case ASCII") };
    for (c in bban.chars()) { if (not isAlnum(c)) return #err("the account part must be digits or upper-case letters") };
    switch (profile(country)) {
      case (?p) {
        if (Text.toArray(bban).size() != p.length - 4) {
          return #err("country " # country # " requires a " # Nat.toText(p.length - 4) # "-character account part");
        };
      };
      case null {};
    };
    let ?m = mod97(bban # country # "00") else return #err("unexpected character in the mod-97 expansion");
    let check = 98 - m;
    let checkText = if (check < 10) "0" # Nat.toText(check) else Nat.toText(check);
    let iban = country # checkText # bban;
    switch (validate(iban)) {
      case (?r) #err("generated an identifier its own validator refuses: " # r);
      case null #ok(iban);
    }
  };

  /// An account-number format policy, recorded as data: the country, the bank and
  /// branch codes, and the width of the serial. The serial comes from the
  /// account's own block index, so identifiers are collision-free by construction
  /// rather than by a uniqueness check after the fact.
  public type Format = { country : Text; bank : Text; branch : Text; serialWidth : Nat; prefix : Text };

  public func validateFormat(f : Format) : ?Text {
    let ?p = profile(f.country) else return ?("no profile for country " # f.country);
    var bbanLen = 0;
    for (seg in p.segments.vals()) { bbanLen += seg.length };
    if (Text.toArray(f.bank).size() != 4) return ?"the bank code must be four characters";
    if (Text.toArray(f.branch).size() != 4) return ?"the branch code must be four characters";
    for (c in f.bank.chars()) { if (not isDigit(c)) return ?"the bank code must be digits" };
    for (c in f.branch.chars()) { if (not isDigit(c)) return ?"the branch code must be digits" };
    let prefixLen = Text.toArray(f.prefix).size();
    for (c in f.prefix.chars()) { if (not isAlnum(c)) return ?"the prefix must be digits or upper-case letters" };
    if (f.serialWidth == 0) return ?"the serial must be at least one character wide";
    if (prefixLen + f.serialWidth != bbanLen - 8) {
      return ?("prefix plus serial must be " # Nat.toText(bbanLen - 8) # " characters for country " # f.country);
    };
    null
  };

  /// Issue the identifier for `serial` under `f`. Deterministic in the serial, so
  /// two accounts can never receive the same identifier.
  public func issue(f : Format, serial : Nat) : { #ok : Text; #err : Text } {
    switch (validateFormat(f)) { case (?r) return #err(r); case null {} };
    let s = Nat.toText(serial);
    let width = Text.toArray(s).size();
    if (width > f.serialWidth) return #err("serial " # s # " does not fit in " # Nat.toText(f.serialWidth) # " characters");
    var padded = "";
    var i = width;
    while (i < f.serialWidth) { padded #= "0"; i += 1 };
    padded #= s;
    generate(f.country, f.bank # f.branch # f.prefix # padded)
  };

  /// The serial an identifier issued under `f` carries: the last `serialWidth` characters of the
  /// BBAN, when the identifier is valid and its country, bank, branch and prefix are `f`'s. What
  /// routes a foreign identifier to its shard (`ShardCore.shardOf`).
  public func serialOf(f : Format, iban : Text) : ?Nat {
    if (validate(iban) != null) return null;
    let cs = Text.toArray(iban);
    let head = f.country # "??" # f.bank # f.branch # f.prefix;   // the check digits are any two
    let headLen = Text.toArray(head).size();
    if (cs.size() != headLen + f.serialWidth) return null;
    var i = 0;
    for (h in head.chars()) { if (h != '?' and cs[i] != h) return null; i += 1 };
    var serial = 0;
    while (i < cs.size()) {
      let c = cs[i];
      if (not isDigit(c)) return null;
      serial := serial * 10 + (Nat32.toNat(Char.toNat32(c)) - 48);
      i += 1;
    };
    ?serial
  };

  // ─── ISO 9362 BIC ──────────────────────────────────────────────────────────

  /// Validate a BIC: 8 or 11 characters, four letters of institution code, two
  /// letters of country, two alphanumerics of location, and an optional
  /// three-character branch.
  public func validateBic(bic : Text) : ?Text {
    let cs = Text.toArray(bic);
    if (cs.size() != 8 and cs.size() != 11) return ?"a BIC is 8 or 11 characters";
    var i = 0;
    while (i < 4) { if (not isUpper(cs[i])) return ?"the institution code must be four letters"; i += 1 };
    while (i < 6) { if (not isUpper(cs[i])) return ?"the country code must be two letters"; i += 1 };
    while (i < 8) { if (not isAlnum(cs[i])) return ?"the location code must be alphanumeric"; i += 1 };
    while (i < cs.size()) { if (not isAlnum(cs[i])) return ?"the branch code must be alphanumeric"; i += 1 };
    null
  };

  func charsToText(cs : [Char]) : Text {
    var out = "";
    for (c in cs.vals()) { out #= Text.fromChar(c) };
    out
  };
};
