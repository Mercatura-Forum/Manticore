/// IndexTypes.mo — the declared configuration of the posting indexes.
///
/// `PostingIndex.mo` holds the indexes themselves, in stable memory, derived from the log. This
/// module holds the part of the index that is a **recorded decision** rather than a derivation: a
/// key's meaning must be a declared act in a block, not a convention in the code, because a key
/// written under one meaning and read under another is a wrong answer that no test can catch after
/// the fact.
///
/// There is one such decision in this step, and it is the counterparty-class index (I4).
///
/// A declared class is a value of a **party extension** — a (schema, field) pair registered with
/// `registerSchema` — and a party can carry many. The index keys on one of them, and which one is
/// this declaration. Three properties follow from how the label is built
/// (`schema.field=value`, in `labelOf`):
///
///   * a class ordinal means exactly one (schema, field, value) triple for ever, so changing the
///     declared dimension starts new ordinals and leaves every row written under the old one
///     meaning what it meant;
///   * a reader can say what a class row *is* from the label alone, with no second lookup;
///   * no personal data enters a key, because an extension value is a declared classification —
///     a sector, a residency band, a size tier — and this estate holds identity only as
///     commitments.
///
/// Until a dimension is declared the class index has no rows. That is not an absence of behaviour:
/// it is the correct behaviour for a bank that has declared no classes, and it is why `classOf`
/// returns an option rather than a default bucket. The report engine's "unclassified" discipline
/// is the same rule one layer up.

import Text "mo:core/Text";

module {

  /// The declared dimension. Both parts name a registered schema field.
  public type ClassDimension = { schema : Text; field : Text };

  public type IndexEvent = {
    /// A new declared dimension for I4, or `null` to stop classifying new postings. Clearing is a
    /// recorded act for the same reason setting one is: it changes what a later row means.
    #counterpartyClassDimensionSet : { dimension : ?ClassDimension };
  };

  public type IndexError = {
    #InvalidClassDimension : { reason : Text };
  };

  /// What a bounded query refuses, and why. It lives here rather than in the engine so the bank's
  /// error union does not have to import the engine, and so a caller reading the Candid interface
  /// finds every refusal of this component in one place.
  ///
  /// `#TooWide` is the one that matters: it carries the size the sizing found and the sentence that
  /// says how to narrow the filter, because a refusal a caller cannot act on is only an outage with
  /// better manners.
  public type QueryError = {
    #TooWide : { size : Nat; bound : Nat; narrow : Text };
    #InvalidRange : { reason : Text };
    #UnknownCurrency : { currency : Text };
    #UnknownClass : { class_ : Text };
    #UnknownAccount : { account : Nat };
    /// The range reaches days closed-month packing answers from the packs, where there are no
    /// per-posting rows to walk. Split at the boundary: `packedAccountEntries` for the packed part.
    #PackedRange : { from : Nat; to : Nat; packedThroughDay : Nat };
  };

  /// The longest a schema or field name may be in a declaration. The same bound the party schema
  /// registry applies, restated here so a declaration cannot make a label the index cannot hold.
  public let MAX_DIMENSION_PART_BYTES : Nat = 64;

  /// The fully qualified class label: `schema.field=value`. Fully qualified because an ordinal is
  /// assigned per label and never reused, so two dimensions can never share one.
  public func labelOf(dim : ClassDimension, value : Text) : Text {
    dim.schema # "." # dim.field # "=" # value
  };

  public func validPart(t : Text) : Bool {
    let n = Text.encodeUtf8(t).size();
    if (n == 0 or n > MAX_DIMENSION_PART_BYTES) return false;
    for (c in t.chars()) {
      let ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '-' or c == '_' or c == '.';
      if (not ok) return false;
    };
    true
  };
}
