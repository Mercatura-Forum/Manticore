/// Feed.mo: the certified pull feed, and the recorded pusher.
///
/// A canister cannot hold a socket open, so the primary mechanism is a **pull** feed: a
/// consumer asks for events after a cursor and receives them together with the certified
/// tip. That is strictly stronger than a webhook, which a consumer has to trust:
///
///   * the cursor is the bank block index, so the sequence is the log and there is no second
///     ordering to get out of step with it;
///   * a response carries the first and last cursor it covers and the tip's certified root,
///     so a consumer that trusts nothing can check that what it received is a **contiguous
///     prefix** of the real sequence; a splice, a reorder or a truncation is detectable
///     rather than invisible;
///   * every event names the block it reports, so a consumer that cares about one event asks
///     for that block's inclusion proof and verifies it alone.
///
/// Push is offered for consumers that need it, and it is deliberately the weaker mechanism:
/// at-least-once delivery to **recorded** endpoints, a declared retry schedule, and a
/// recorded dead-letter list that blocks nothing and is visible. A push to an endpoint that
/// is not a recorded act is refused, so a silent exfiltration path cannot be configured
/// unnoticed.

import Nat "mo:core/Nat";
import Text "mo:core/Text";
import Blob "mo:core/Blob";
import Sha256 "mo:sha2/Sha256";

import JC "mo:journal/Canonical";

import RT "ReportTypes";

module {

  /// What a consumer gets back. `from` and `to` bound the slice, `tipCursor` is the highest
  /// cursor that exists, and `digest` is a hash over the slice in order; so a consumer can
  /// re-derive the digest from what it received and detect a reorder even before it looks at
  /// a single event.
  public type FeedPage = {
    events : [RT.FeedEvent];
    from : Nat;
    to : Nat;
    tipCursor : Nat;
    /// True when `to` is the tip: the consumer is caught up and the next call may return
    /// nothing. Stated rather than inferred from an empty page, because an empty page also
    /// happens when every block in the range was filtered out.
    caughtUp : Bool;
    digest : Blob;
  };

  public let MAX_PAGE : Nat = 512;

  /// The digest of a page: the domain, the bounds, and each event in order. A consumer that
  /// recomputes this has checked the ordering and the completeness of what it holds without
  /// trusting the server that sent it.
  public func pageDigest(events : [RT.FeedEvent], from : Nat, to : Nat) : Blob {
    let w = JC.Writer();
    w.text("thebes.bank.feed.page.v1");
    w.nat(from);
    w.nat(to);
    w.nat(events.size());
    for (e in events.vals()) {
      w.nat(e.cursor);
      w.nat(e.block);
      w.text(e.kind);
      switch (e.book) { case null w.byte(0); case (?b) { w.byte(1); w.text(b) } };
    };
    Sha256.fromBlob(#sha256, Blob.fromArray(w.toArray()))
  };

  /// Is this page a contiguous run starting where the consumer asked? The check a consumer
  /// performs, implemented here so the canister holds itself to the same rule it asks the
  /// consumer to apply.
  public func isContiguous(page : FeedPage, requestedFrom : Nat) : Bool {
    if (page.from != requestedFrom) return false;
    if (page.events.size() == 0) return page.to == page.from;
    var expected = page.from;
    for (e in page.events.vals()) {
      if (e.cursor < expected) return false;      // a reorder or a repeat
      expected := e.cursor + 1;
    };
    if (page.to + 1 < expected) return false;     // an event past the stated end
    page.digest == pageDigest(page.events, page.from, page.to)
  };

  public func validateEndpoint(e : RT.FeedEndpoint) : ?RT.ReportError {
    if (Text.encodeUtf8(e.url).size() == 0) return ?#InvalidEndpoint({ reason = "an endpoint states its URL" });
    if (not Text.startsWith(e.url, #text "https://")) {
      return ?#InvalidEndpoint({ reason = "an endpoint is https; a feed that can be read in transit is not a feed" });
    };
    if (e.retries.size() > RT.MAX_RETRIES) {
      return ?#InvalidEndpoint({ reason = "at most " # Nat.toText(RT.MAX_RETRIES) # " retries" });
    };
    // a retry schedule that does not back off is a retry schedule that hammers
    var previous = 0;
    for (r in e.retries.vals()) {
      if (r == 0) return ?#InvalidEndpoint({ reason = "a retry interval of zero seconds is not a retry" });
      if (r < previous) return ?#InvalidEndpoint({ reason = "a retry schedule does not shorten: " # Nat.toText(previous) # " then " # Nat.toText(r) });
      previous := r;
    };
    null
  };
};
