/// Canonical.mo — deterministic byte encoding and hashing of journal blocks.
///
/// The encoding is the contract between the canister and any party that wants
/// to verify an entry without trusting the canister: the verifier re-encodes
/// the fields it was given, hashes them the same way, and checks the result
/// against the Merkle Mountain Range root in the signed tip certificate. The
/// encoding is therefore fully specified here and kept free of anything that
/// is not reproducible from the block's fields.
///
/// Primitive encodings (all big-endian, all length-prefixed so that no two
/// field sequences share a byte string):
///   nat      : [len : 1 byte][magnitude : len bytes, big-endian, no leading zero]; zero is [0x00]
///   nat64    : 8 bytes big-endian
///   nat8     : 1 byte
///   bool     : 1 byte (0 or 1)
///   text     : [len : 2 bytes][UTF-8 bytes]
///   blob     : [len : 2 bytes][bytes]
///   principal: [len : 1 byte][raw principal bytes]
///   option   : [0x00] or [0x01][value]
///   array    : [count : 2 bytes][items...]
///   variant  : [tag : 1 byte][payload]
///
/// Block bytes (what is stored in the log):
///   leg: text account, option<blob> subledger, side, text currency, nat amount
///   accountOpened payload: text code, text name, side, category, constraint (1 byte: 0 none, 1 debitsNotExceedCredits, 2 creditsNotExceedDebits)
///   posting: … text narration, relation, option<nat> valueDateRequested (v3)
///   [version byte][index nat][timestamp nat64][caller principal]
///   (version 3 = the calendar vocabulary; version 4 adds the banking tags from 0x2C)
///   [parentHash option<32 bytes>][event][hash 32 bytes]
///
/// Block hash = SHA-256( text("THEBES-JOURNAL-BLOCK-v1") || block bytes before the hash field ).
/// Posting content hash = SHA-256( text("THEBES-JOURNAL-POSTING-v1") || posting record bytes ),
/// used for idempotency-key content comparison.

import Array "mo:core/Array";
import Blob "mo:core/Blob";
import List "mo:core/List";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Nat64 "mo:core/Nat64";
import Principal "mo:core/Principal";
import Text "mo:core/Text";
import Sha256 "mo:sha2/Sha256";

import T "JournalTypes";
import ByteBuf "../ledger/ByteBuf";

module {

  /// The version byte a new block is written with. Version 3 is the journal calendar
  /// vocabulary (tags 0x10-0x2B); version 4 adds the banking tags 0x2C (poster scope),
  /// 0x2D (numeric balance limit) and 0x2E (chart-of-accounts attributes).
  /// No existing variant's encoding changed, so a version-3 block's bytes and
  /// hash are exactly what they were.
  public let BLOCK_VERSION : Nat8 = 0x04;

  /// Every version this decoder can read. A stored block carries its own
  /// version byte inside the hashed preimage, so a log written by an earlier
  /// build stays readable and its hashes stay valid; refusing anything but the
  /// current version, as the decoder did before, would have made an existing
  /// log unreadable the moment a tag was added.
  public let SUPPORTED_BLOCK_VERSIONS : [Nat8] = [0x03, 0x04];

  /// An IC principal is at most 29 bytes. The decoder must check this before
  /// constructing one: `Principal.fromBlob` traps on a longer blob, and a
  /// decoder that traps on malformed input cannot reject it. Found by the bank
  /// log's byte-flip test, which tampers with the length byte of a principal
  /// field (`thebes-banking-core/test/BankCanonical.test.mo`); the journal's own
  /// paths never reach it, because the journal only decodes bytes it wrote, but
  /// an external verifier, an archive child and any query that decodes
  /// caller-supplied bytes all do.
  public let MAX_PRINCIPAL_BYTES : Nat = 29;

  public func supportsVersion(v : Nat8) : Bool {
    for (s in SUPPORTED_BLOCK_VERSIONS.vals()) { if (s == v) return true };
    false
  };
  public let BLOCK_DOMAIN : Text = "THEBES-JOURNAL-BLOCK-v1";
  public let POSTING_DOMAIN : Text = "THEBES-JOURNAL-POSTING-v1";
  public let IDEMPOTENCY_DOMAIN : Text = "THEBES-JOURNAL-IDEMPOTENCY-v1";

  // ═══════════════════════════════════════════════════════
  //  WRITER
  // ═══════════════════════════════════════════════════════

  public class Writer() {
    let buf = ByteBuf.ByteBuf(256);

    public func byte(b : Nat8) { buf.add(b) };
    public func bytes(bs : [Nat8]) { buf.addArray(bs) };
    public func blobRaw(b : Blob) { buf.addBlob(b) };

    public func nat(n : Nat) {
      if (n == 0) { byte(0); return };
      var tmp = n;
      var count : Nat = 0;
      while (tmp > 0) { tmp /= 256; count += 1 };
      assert (count <= 255);
      byte(Nat8.fromNat(count));
      buf.addBE(n, count);
    };

    public func nat64(n : Nat64) { buf.addBE(Nat64.toNat(n), 8) };

    public func nat8(n : Nat8) { byte(n) };
    public func bool(b : Bool) { byte(if (b) 1 else 0) };

    public func len16(n : Nat) { assert (n <= 65535); byte(Nat8.fromNat(n / 256)); byte(Nat8.fromNat(n % 256)) };
    public func text(t : Text) { let b = Text.encodeUtf8(t); len16(b.size()); blobRaw(b) };
    public func blob(b : Blob) { len16(b.size()); blobRaw(b) };
    public func principal(p : Principal) { let b = Principal.toBlob(p); assert (b.size() <= MAX_PRINCIPAL_BYTES); byte(Nat8.fromNat(b.size())); blobRaw(b) };
    public func optBlob(o : ?Blob) { switch (o) { case null byte(0); case (?b) { byte(1); blob(b) } } };
    public func optNat(o : ?Nat) { switch (o) { case null byte(0); case (?n) { byte(1); nat(n) } } };
    public func optNat64(o : ?Nat64) { switch (o) { case null byte(0); case (?n) { byte(1); nat64(n) } } };

    public func side(s : T.Side) { byte(switch (s) { case (#debit) 0; case (#credit) 1 }) };
    public func category(c : T.Category) {
      byte(switch (c) { case (#asset) 0; case (#liability) 1; case (#equity) 2; case (#income) 3; case (#expense) 4 })
    };
    public func voidReason(r : T.VoidReason) { byte(switch (r) { case (#requested) 0; case (#expired) 1 }) };
    public func constraint(c : T.BalanceConstraint) {
      byte(switch (c) { case (#none) 0; case (#debitsNotExceedCredits) 1; case (#creditsNotExceedDebits) 2 })
    };

    public func leg(l : T.Leg) { text(l.account); optBlob(l.subledger); side(l.side); text(l.currency); nat(l.amount) };
    public func sourceRef(s : T.SourceRef) { text(s.kind); text(s.id) };
    public func relation(r : ?T.Relation) {
      switch (r) {
        case null byte(0);
        case (?rel) { byte(1); nat(rel.original); byte(switch (rel.kind) { case (#reversal) 0; case (#correction) 1 }) };
      };
    };
    public func resolution(r : T.Resolution) { nat(r.postingDate); nat(r.valueDate); text(r.period); optNat(r.valueDateRequested) };
    public func range(r : T.LeadsheetRange) { nat(r.lo); nat(r.hi); text(r.leadsheet); text(r.name); text(r.category); text(r.cycle) };

    public func posting(p : T.PostingRecord) {
      blob(p.idempotencyKey);
      nat(p.postingDate);
      nat(p.valueDate);
      text(p.period);
      len16(p.legs.size());
      for (l in p.legs.vals()) { leg(l) };
      sourceRef(p.sourceRef);
      text(p.narration);
      relation(p.relation);
      optNat(p.valueDateRequested);
    };

    public func shiftPolicy(sp : T.ShiftPolicy) { byte(switch (sp) { case (#reject) 0; case (#previous) 1; case (#next) 2; case (#nearest) 3 }) };
    public func calendarAuthority(a : T.CalendarAuthority) { byte(switch (a) { case (#substrateClock) 0; case (#businessDate) 1 }) };
    public func calendar(c : ?T.CalendarConfig) {
      switch (c) {
        case null byte(0);
        case (?cal) {
          byte(1);
          len16(cal.restDays.size()); for (d in cal.restDays.vals()) { nat(d) };
          len16(cal.holidays.size()); for (h in cal.holidays.vals()) { nat(h) };
          shiftPolicy(cal.policy);
        };
      };
    };

    public func event(e : T.Event) {
      switch (e) {
        case (#posted(p)) { byte(0x10); posting(p) };
        case (#pending(x)) { byte(0x11); posting(x.record); optNat64(x.expiresAt) };
        case (#post(x)) { byte(0x12); nat(x.pendingIndex); resolution(x.resolution) };
        case (#void(x)) { byte(0x13); nat(x.pendingIndex); voidReason(x.reason) };
        case (#currencyRegistered(c)) { byte(0x20); text(c.code); nat8(c.minorUnits) };
        case (#accountOpened(a)) { byte(0x21); text(a.code); text(a.name); side(a.normalSide); category(a.category); constraint(a.constraint) };
        case (#accountClosed(a)) { byte(0x22); text(a.code) };
        case (#periodOpened(p)) { byte(0x23); text(p.id); nat(p.start); nat(p.end) };
        case (#periodClosed(p)) { byte(0x24); text(p.id) };
        case (#activationHeight(a)) { byte(0x25); nat64(a.height) };
        case (#leadsheetSchema(s)) { byte(0x26); len16(s.ranges.size()); for (r in s.ranges.vals()) { range(r) } };
        case (#posterAdded(p)) { byte(0x27); principal(p.poster) };
        case (#posterRemoved(p)) { byte(0x28); principal(p.poster) };
        case (#adminTransferred(a)) { byte(0x29); principal(a.admin) };
        case (#businessDateRolled(b)) { byte(0x2A); nat(b.day) };
        case (#calendarSet(c)) { byte(0x2B); calendar(c.calendar) };
        case (#calendarAuthoritySet(x)) { byte(0x2F); calendarAuthority(x.authority); nat(x.maxRollDays); optNat(x.businessDate) };
        case (#posterScopeSet(p)) {
          byte(0x2C); principal(p.poster);
          switch (p.accounts) {
            case null byte(0);
            case (?accounts) { byte(1); len16(accounts.size()); for (a in accounts.vals()) { text(a) } };
          };
        };
        case (#balanceLimitSet(x)) {
          byte(0x2D); text(x.account);
          switch (x.subledger) { case null byte(0); case (?b) { byte(1); blob(b) } };
          text(x.currency);
          switch (x.limit) {
            case (#none) byte(0);
            case (#debitsNotExceedCreditsPlus(n)) { byte(1); nat(n) };
            case (#creditsNotExceedDebitsPlus(n)) { byte(2); nat(n) };
          };
        };
        case (#accountAttributesSet(x)) {
          byte(0x2E); text(x.code);
          attributes(x.attributes);
        };
        case (#checkpoint(c)) { byte(0x30); nat(c.through); nat(c.seq); bool(c.last); checkpointPart(c.part) };
      };
    };

    public func attributes(a : T.AccountAttributes) {
      byte(switch (a.usage) { case (#header) 0; case (#detail) 1 });
      bool(a.manualEntriesAllowed);
      switch (a.parent) { case null byte(0); case (?p2) { byte(1); text(p2) } };
    };
    public func limit(l : T.BalanceLimit) {
      switch (l) {
        case (#none) byte(0);
        case (#debitsNotExceedCreditsPlus(n)) { byte(1); nat(n) };
        case (#creditsNotExceedDebitsPlus(n)) { byte(2); nat(n) };
      };
    };

    /// Counts here are `nat`, not `len16`: a checkpoint part is bounded by bytes, not by 65,535.
    public func checkpointPart(p : T.CheckpointPart) {
      switch (p) {
        case (#config(c)) {
          byte(0x01);
          principal(c.admin); nat64(c.activationHeight); optNat(c.businessDate); calendar(c.calendar);
          nat(c.leadsheet.size()); for (r in c.leadsheet.vals()) { range(r) };
          nat(c.currencies.size()); for ((code, mu) in c.currencies.vals()) { text(code); nat8(mu) };
          nat(c.posters.size()); for (p2 in c.posters.vals()) { principal(p2) };
          nat(c.posterScopes.size()); for ((p2, scope) in c.posterScopes.vals()) { principal(p2); nat(scope.size()); for (a in scope.vals()) { text(a) } };
          nat(c.balanceLimits.size()); for (l in c.balanceLimits.vals()) { text(l.account); blob(l.subledger); text(l.currency); limit(l.limit) };
          nat(c.accountAttributes.size()); for ((code, a) in c.accountAttributes.vals()) { text(code); attributes(a) };
          nat(c.accountOrdinals.size()); for ((code, o) in c.accountOrdinals.vals()) { text(code); nat(o) };
          nat(c.currencyOrdinals.size()); for ((code, o) in c.currencyOrdinals.vals()) { text(code); nat(o) };
          nat(c.periodOrdinals.size()); for ((id, o) in c.periodOrdinals.vals()) { text(id); nat(o) };
          nat(c.postedCount); nat(c.voidedCount); nat(c.datedRolledUpThrough);
          calendarAuthority(c.calendarAuthority); nat(c.maxRollDays);
        };
        case (#accounts(xs)) {
          byte(0x02); nat(xs.size());
          for (a in xs.vals()) { text(a.code); text(a.name); side(a.normalSide); category(a.category); constraint(a.constraint); bool(a.active); nat(a.openedAtBlock); optNat(a.closedAtBlock) };
        };
        case (#periods(xs)) {
          byte(0x03); nat(xs.size());
          for (p2 in xs.vals()) { text(p2.id); nat(p2.start); nat(p2.end); bool(p2.open); nat(p2.openedAtBlock); optNat(p2.closedAtBlock); nat(p2.postings); nat(p2.pendings) };
        };
        case (#balances(xs)) {
          byte(0x04); nat(xs.size());
          for (b in xs.vals()) { text(b.account); blob(b.subledger); text(b.currency); nat(b.drPosted); nat(b.crPosted); nat(b.drPending); nat(b.crPending) };
        };
        case (#periodBalances(xs)) {
          byte(0x05); nat(xs.size());
          for (b in xs.vals()) { text(b.period); text(b.account); text(b.currency); nat(b.debits); nat(b.credits) };
        };
        case (#dated(d)) {
          byte(0x06); bool(d.valueDated); nat(d.rows.size());
          for (r in d.rows.vals()) { text(r.account); text(r.currency); blob(r.subledger); nat(r.day); nat(r.debits); nat(r.credits) };
        };
        case (#pendings(x)) {
          byte(0x07); nat(x.open.size()); for (i in x.open.vals()) { nat(i) };
          nat(x.byAccount.size()); for ((a, n) in x.byAccount.vals()) { text(a); nat(n) };
        };
      };
    };

    public func size() : Nat { buf.size() };
    public func toBlob() : Blob { buf.toBlob() };
    public func toArray() : [Nat8] { buf.toArray() };
  };

  // ═══════════════════════════════════════════════════════
  //  READER (total: every failure is `null`, never a trap)
  // ═══════════════════════════════════════════════════════

  public class Reader(data : [Nat8]) {
    var pos : Nat = 0;

    public func position() : Nat { pos };
    public func remaining() : Nat { data.size() - pos };

    public func byte() : ?Nat8 { if (pos >= data.size()) null else { let b = data[pos]; pos += 1; ?b } };

    public func take(n : Nat) : ?[Nat8] {
      if (pos + n > data.size()) return null;
      let out = Array.tabulate<Nat8>(n, func(i) { data[pos + i] });
      pos += n;
      ?out
    };

    public func nat() : ?Nat {
      switch (byte()) {
        case null null;
        case (?len) {
          let l = Nat8.toNat(len);
          if (l == 0) return ?0;
          switch (take(l)) {
            case null null;
            case (?bs) {
              if (bs[0] == 0) return null; // non-minimal encoding is not canonical
              var acc : Nat = 0;
              for (b in bs.vals()) { acc := acc * 256 + Nat8.toNat(b) };
              ?acc
            };
          };
        };
      };
    };

    public func nat64() : ?Nat64 {
      switch (take(8)) {
        case null null;
        case (?bs) { var acc : Nat = 0; for (b in bs.vals()) { acc := acc * 256 + Nat8.toNat(b) }; ?Nat64.fromNat(acc) };
      };
    };

    public func nat8() : ?Nat8 { byte() };
    public func bool() : ?Bool { switch (byte()) { case (?0) ?false; case (?1) ?true; case _ null } };

    public func len16() : ?Nat {
      switch (take(2)) { case (?bs) ?(Nat8.toNat(bs[0]) * 256 + Nat8.toNat(bs[1])); case null null }
    };

    public func text() : ?Text {
      switch (len16()) {
        case null null;
        case (?n) { switch (take(n)) { case null null; case (?bs) Text.decodeUtf8(Blob.fromArray(bs)) } };
      };
    };

    public func blob() : ?Blob {
      switch (len16()) { case null null; case (?n) { switch (take(n)) { case null null; case (?bs) ?Blob.fromArray(bs) } } };
    };

    public func principal() : ?Principal {
      switch (byte()) {
        case null null;
        case (?len) {
          let n = Nat8.toNat(len);
          // A blob longer than a principal is not a principal; returning null
          // rejects the block, where constructing one would trap.
          if (n > MAX_PRINCIPAL_BYTES) return null;
          switch (take(n)) { case null null; case (?bs) ?Principal.fromBlob(Blob.fromArray(bs)) };
        };
      };
    };

    public func optBlob() : ??Blob {
      switch (byte()) { case (?0) ?null; case (?1) { switch (blob()) { case (?b) ?(?b); case null null } }; case _ null }
    };
    public func optNat() : ??Nat {
      switch (byte()) { case (?0) ?null; case (?1) { switch (nat()) { case (?n) ?(?n); case null null } }; case _ null }
    };
    public func optNat64() : ??Nat64 {
      switch (byte()) { case (?0) ?null; case (?1) { switch (nat64()) { case (?n) ?(?n); case null null } }; case _ null }
    };

    public func side() : ?T.Side { switch (byte()) { case (?0) ?#debit; case (?1) ?#credit; case _ null } };
    public func category() : ?T.Category {
      switch (byte()) { case (?0) ?#asset; case (?1) ?#liability; case (?2) ?#equity; case (?3) ?#income; case (?4) ?#expense; case _ null }
    };
    public func voidReason() : ?T.VoidReason { switch (byte()) { case (?0) ?#requested; case (?1) ?#expired; case _ null } };
    public func constraint() : ?T.BalanceConstraint {
      switch (byte()) { case (?0) ?#none; case (?1) ?#debitsNotExceedCredits; case (?2) ?#creditsNotExceedDebits; case _ null }
    };

    public func leg() : ?T.Leg {
      let ?account = text() else return null;
      let ?subledger = optBlob() else return null;
      let ?s = side() else return null;
      let ?currency = text() else return null;
      let ?amount = nat() else return null;
      ?{ account; subledger; side = s; currency; amount }
    };

    public func sourceRef() : ?T.SourceRef {
      let ?kind = text() else return null;
      let ?id = text() else return null;
      ?{ kind; id }
    };

    public func relation() : ??T.Relation {
      switch (byte()) {
        case (?0) ?null;
        case (?1) {
          let ?original = nat() else return null;
          let ?k = byte() else return null;
          let kind : T.RelationKind = switch (k) { case 0 #reversal; case 1 #correction; case _ return null };
          ?(?{ original; kind })
        };
        case _ null;
      };
    };

    public func resolution() : ?T.Resolution {
      let ?postingDate = nat() else return null;
      let ?valueDate = nat() else return null;
      let ?period = text() else return null;
      let ?valueDateRequested = optNat() else return null;
      ?{ postingDate; valueDate; valueDateRequested; period }
    };

    public func range() : ?T.LeadsheetRange {
      let ?lo = nat() else return null;
      let ?hi = nat() else return null;
      let ?leadsheet = text() else return null;
      let ?name = text() else return null;
      let ?category = text() else return null;
      let ?cycle = text() else return null;
      ?{ lo; hi; leadsheet; name; category; cycle }
    };

    public func posting() : ?T.PostingRecord {
      let ?idempotencyKey = blob() else return null;
      let ?postingDate = nat() else return null;
      let ?valueDate = nat() else return null;
      let ?period = text() else return null;
      let ?count = len16() else return null;
      let legs = List.empty<T.Leg>();
      var i = 0;
      while (i < count) { let ?l = leg() else return null; List.add(legs, l); i += 1 };
      let ?src = sourceRef() else return null;
      let ?narration = text() else return null;
      let ?rel = relation() else return null;
      let ?valueDateRequested = optNat() else return null;
      ?{ idempotencyKey; postingDate; valueDate; valueDateRequested; period; legs = List.toArray(legs); sourceRef = src; narration; relation = rel }
    };

    public func shiftPolicy() : ?T.ShiftPolicy {
      switch (byte()) { case (?0) ?#reject; case (?1) ?#previous; case (?2) ?#next; case (?3) ?#nearest; case _ null }
    };
    public func calendarAuthority() : ?T.CalendarAuthority {
      switch (byte()) { case (?0) ?#substrateClock; case (?1) ?#businessDate; case _ null }
    };
    public func calendar() : ??T.CalendarConfig {
      switch (byte()) {
        case (?0) ?null;
        case (?1) {
          let ?nr = len16() else return null;
          let rest = List.empty<Nat>();
          var i = 0; while (i < nr) { let ?d = nat() else return null; List.add(rest, d); i += 1 };
          let ?nh = len16() else return null;
          let hol = List.empty<Nat>();
          i := 0; while (i < nh) { let ?h = nat() else return null; List.add(hol, h); i += 1 };
          let ?policy = shiftPolicy() else return null;
          ?(?{ restDays = List.toArray(rest); holidays = List.toArray(hol); policy })
        };
        case _ null;
      }
    };

    public func attributes() : ?T.AccountAttributes {
      let ?u = byte() else return null;
      let usage : T.AccountUsage = switch (u) { case 0 #header; case 1 #detail; case _ return null };
      let ?manualEntriesAllowed = bool() else return null;
      let ?present = byte() else return null;
      let parent : ?T.AccountCode = if (present == 0) null else if (present == 1) { let ?p2 = text() else return null; ?p2 } else return null;
      ?{ usage; manualEntriesAllowed; parent }
    };
    public func limit() : ?T.BalanceLimit {
      let ?kind = byte() else return null;
      switch (kind) {
        case 0 ?#none;
        case 1 { let ?n = nat() else return null; ?#debitsNotExceedCreditsPlus(n) };
        case 2 { let ?n = nat() else return null; ?#creditsNotExceedDebitsPlus(n) };
        case _ null;
      }
    };
    func count() : ?Nat { let ?n = nat() else return null; if (n > 16_777_216) return null; ?n };

    public func checkpointPart() : ?T.CheckpointPart {
      let ?tag = byte() else return null;
      switch (tag) {
        case 0x01 {
          let ?admin = principal() else return null; let ?activationHeight = nat64() else return null;
          let ?businessDate = optNat() else return null; let ?cal = calendar() else return null;
          let ?nl = count() else return null; let leadsheet = List.empty<T.LeadsheetRange>();
          var i = 0; while (i < nl) { let ?r = range() else return null; List.add(leadsheet, r); i += 1 };
          let ?nc = count() else return null; let currencies = List.empty<(T.Currency, Nat8)>();
          i := 0; while (i < nc) { let ?c = text() else return null; let ?mu = nat8() else return null; List.add(currencies, (c, mu)); i += 1 };
          let ?np = count() else return null; let posters = List.empty<Principal>();
          i := 0; while (i < np) { let ?p2 = principal() else return null; List.add(posters, p2); i += 1 };
          let ?ns = count() else return null; let scopes = List.empty<(Principal, T.PosterScope)>();
          i := 0; while (i < ns) {
            let ?p2 = principal() else return null; let ?na = count() else return null; let accts = List.empty<T.AccountCode>();
            var j = 0; while (j < na) { let ?a = text() else return null; List.add(accts, a); j += 1 };
            List.add(scopes, (p2, List.toArray(accts))); i += 1;
          };
          let ?nb = count() else return null; let limits = List.empty<{ account : T.AccountCode; subledger : Blob; currency : T.Currency; limit : T.BalanceLimit }>();
          i := 0; while (i < nb) { let ?account = text() else return null; let ?subledger = blob() else return null; let ?currency = text() else return null; let ?l = limit() else return null; List.add(limits, { account; subledger; currency; limit = l }); i += 1 };
          let ?natt = count() else return null; let attrs = List.empty<(T.AccountCode, T.AccountAttributes)>();
          i := 0; while (i < natt) { let ?code = text() else return null; let ?a = attributes() else return null; List.add(attrs, (code, a)); i += 1 };
          let ?nao = count() else return null; let accountOrdinals = List.empty<(T.AccountCode, Nat)>();
          i := 0; while (i < nao) { let ?code = text() else return null; let ?o = nat() else return null; List.add(accountOrdinals, (code, o)); i += 1 };
          let ?nco = count() else return null; let currencyOrdinals = List.empty<(T.Currency, Nat)>();
          i := 0; while (i < nco) { let ?code = text() else return null; let ?o = nat() else return null; List.add(currencyOrdinals, (code, o)); i += 1 };
          let ?npo = count() else return null; let periodOrdinals = List.empty<(T.PeriodId, Nat)>();
          i := 0; while (i < npo) { let ?id = text() else return null; let ?o = nat() else return null; List.add(periodOrdinals, (id, o)); i += 1 };
          let ?postedCount = nat() else return null; let ?voidedCount = nat() else return null; let ?datedRolledUpThrough = nat() else return null;
          let ?authority = calendarAuthority() else return null; let ?maxRollDays = nat() else return null;
          ?#config({
            admin; activationHeight; businessDate; calendar = cal; leadsheet = List.toArray(leadsheet); currencies = List.toArray(currencies);
            posters = List.toArray(posters); posterScopes = List.toArray(scopes); balanceLimits = List.toArray(limits); accountAttributes = List.toArray(attrs);
            accountOrdinals = List.toArray(accountOrdinals); currencyOrdinals = List.toArray(currencyOrdinals); periodOrdinals = List.toArray(periodOrdinals);
            postedCount; voidedCount; datedRolledUpThrough; calendarAuthority = authority; maxRollDays;
          })
        };
        case 0x02 {
          let ?n = count() else return null;
          let out = List.empty<{ code : T.AccountCode; name : Text; normalSide : T.Side; category : T.Category; constraint : T.BalanceConstraint; active : Bool; openedAtBlock : Nat; closedAtBlock : ?Nat }>();
          var i = 0;
          while (i < n) {
            let ?code = text() else return null; let ?name = text() else return null; let ?normalSide = side() else return null; let ?cat = category() else return null;
            let ?con = constraint() else return null; let ?active = bool() else return null; let ?openedAtBlock = nat() else return null; let ?closedAtBlock = optNat() else return null;
            List.add(out, { code; name; normalSide; category = cat; constraint = con; active; openedAtBlock; closedAtBlock }); i += 1;
          };
          ?#accounts(List.toArray(out))
        };
        case 0x03 {
          let ?n = count() else return null;
          let out = List.empty<{ id : T.PeriodId; start : T.Day; end : T.Day; open : Bool; openedAtBlock : Nat; closedAtBlock : ?Nat; postings : Nat; pendings : Nat }>();
          var i = 0;
          while (i < n) {
            let ?id = text() else return null; let ?start = nat() else return null; let ?end = nat() else return null; let ?open = bool() else return null;
            let ?openedAtBlock = nat() else return null; let ?closedAtBlock = optNat() else return null; let ?postings = nat() else return null; let ?pendings = nat() else return null;
            List.add(out, { id; start; end; open; openedAtBlock; closedAtBlock; postings; pendings }); i += 1;
          };
          ?#periods(List.toArray(out))
        };
        case 0x04 {
          let ?n = count() else return null;
          let out = List.empty<{ account : T.AccountCode; subledger : Blob; currency : T.Currency; drPosted : Nat; crPosted : Nat; drPending : Nat; crPending : Nat }>();
          var i = 0;
          while (i < n) {
            let ?account = text() else return null; let ?subledger = blob() else return null; let ?currency = text() else return null;
            let ?drPosted = nat() else return null; let ?crPosted = nat() else return null; let ?drPending = nat() else return null; let ?crPending = nat() else return null;
            List.add(out, { account; subledger; currency; drPosted; crPosted; drPending; crPending }); i += 1;
          };
          ?#balances(List.toArray(out))
        };
        case 0x05 {
          let ?n = count() else return null;
          let out = List.empty<{ period : T.PeriodId; account : T.AccountCode; currency : T.Currency; debits : Nat; credits : Nat }>();
          var i = 0;
          while (i < n) {
            let ?period = text() else return null; let ?account = text() else return null; let ?currency = text() else return null; let ?debits = nat() else return null; let ?credits = nat() else return null;
            List.add(out, { period; account; currency; debits; credits }); i += 1;
          };
          ?#periodBalances(List.toArray(out))
        };
        case 0x06 {
          let ?valueDated = bool() else return null; let ?n = count() else return null;
          let out = List.empty<{ account : T.AccountCode; currency : T.Currency; subledger : Blob; day : T.Day; debits : Nat; credits : Nat }>();
          var i = 0;
          while (i < n) {
            let ?account = text() else return null; let ?currency = text() else return null; let ?subledger = blob() else return null; let ?day = nat() else return null; let ?debits = nat() else return null; let ?credits = nat() else return null;
            List.add(out, { account; currency; subledger; day; debits; credits }); i += 1;
          };
          ?#dated({ valueDated; rows = List.toArray(out) })
        };
        case 0x07 {
          let ?no = count() else return null; let open = List.empty<Nat>();
          var i = 0; while (i < no) { let ?x = nat() else return null; List.add(open, x); i += 1 };
          let ?na = count() else return null; let byAccount = List.empty<(T.AccountCode, Nat)>();
          i := 0; while (i < na) { let ?a = text() else return null; let ?n = nat() else return null; List.add(byAccount, (a, n)); i += 1 };
          ?#pendings({ open = List.toArray(open); byAccount = List.toArray(byAccount) })
        };
        case _ null;
      }
    };

    public func event() : ?T.Event {
      let ?tag = byte() else return null;
      switch (tag) {
        case 0x10 { let ?p = posting() else return null; ?#posted(p) };
        case 0x11 { let ?record = posting() else return null; let ?expiresAt = optNat64() else return null; ?#pending({ record; expiresAt }) };
        case 0x12 { let ?pendingIndex = nat() else return null; let ?res = resolution() else return null; ?#post({ pendingIndex; resolution = res }) };
        case 0x13 { let ?pendingIndex = nat() else return null; let ?reason = voidReason() else return null; ?#void({ pendingIndex; reason }) };
        case 0x20 { let ?code = text() else return null; let ?minorUnits = nat8() else return null; ?#currencyRegistered({ code; minorUnits }) };
        case 0x21 {
          let ?code = text() else return null; let ?name = text() else return null;
          let ?normalSide = side() else return null; let ?cat = category() else return null;
          let ?con = constraint() else return null;
          ?#accountOpened({ code; name; normalSide; category = cat; constraint = con })
        };
        case 0x22 { let ?code = text() else return null; ?#accountClosed({ code }) };
        case 0x23 { let ?id = text() else return null; let ?start = nat() else return null; let ?end = nat() else return null; ?#periodOpened({ id; start; end }) };
        case 0x24 { let ?id = text() else return null; ?#periodClosed({ id }) };
        case 0x25 { let ?height = nat64() else return null; ?#activationHeight({ height }) };
        case 0x26 {
          let ?count = len16() else return null;
          let ranges = List.empty<T.LeadsheetRange>();
          var i = 0;
          while (i < count) { let ?r = range() else return null; List.add(ranges, r); i += 1 };
          ?#leadsheetSchema({ ranges = List.toArray(ranges) })
        };
        case 0x27 { let ?poster = principal() else return null; ?#posterAdded({ poster }) };
        case 0x28 { let ?poster = principal() else return null; ?#posterRemoved({ poster }) };
        case 0x29 { let ?admin = principal() else return null; ?#adminTransferred({ admin }) };
        case 0x2A { let ?day = nat() else return null; ?#businessDateRolled({ day }) };
        case 0x2B { let ?cal = calendar() else return null; ?#calendarSet({ calendar = cal }) };
        case 0x2F {
          let ?authority = calendarAuthority() else return null; let ?maxRollDays = nat() else return null; let ?businessDate = optNat() else return null;
          ?#calendarAuthoritySet({ authority; maxRollDays; businessDate })
        };
        case 0x2D {
          let ?account = text() else return null;
          let ?subledger = optBlob() else return null;
          let ?currency = text() else return null;
          let ?kind = byte() else return null;
          let limit : T.BalanceLimit = switch (kind) {
            case 0 #none;
            case 1 { let ?n = nat() else return null; #debitsNotExceedCreditsPlus(n) };
            case 2 { let ?n = nat() else return null; #creditsNotExceedDebitsPlus(n) };
            case _ return null;
          };
          ?#balanceLimitSet({ account; subledger; currency; limit })
        };
        case 0x2E {
          let ?code = text() else return null;
          let ?a = attributes() else return null;
          ?#accountAttributesSet({ code; attributes = a })
        };
        case 0x30 {
          let ?through = nat() else return null; let ?seq = nat() else return null; let ?last = bool() else return null;
          let ?part = checkpointPart() else return null;
          ?#checkpoint({ through; seq; last; part })
        };
        case 0x2C {
          let ?poster = principal() else return null;
          let ?present = byte() else return null;
          if (present == 0) { ?#posterScopeSet({ poster; accounts = null }) }
          else if (present == 1) {
            let ?count = len16() else return null;
            let accounts = List.empty<T.AccountCode>();
            var i = 0;
            while (i < count) { let ?a = text() else return null; List.add(accounts, a); i += 1 };
            ?#posterScopeSet({ poster; accounts = ?List.toArray(accounts) })
          } else null
        };
        case _ null;
      };
    };
  };

  // ═══════════════════════════════════════════════════════
  //  HASHING
  // ═══════════════════════════════════════════════════════

  func sha256Domain(domain : Text, payload : [Nat8]) : Blob {
    let d = Sha256.Digest(#sha256);
    let w = Writer();
    w.text(domain);
    d.writeArray(w.toArray());
    d.writeArray(payload);
    d.sum()
  };

  /// Encode a block's preimage (everything but the hash) and compute its hash.
  public func encodeBlock(index : Nat, timestamp : Nat64, caller : Principal, parentHash : ?Blob, event : T.Event) : { bytes : Blob; hash : Blob } {
    encodeBlockAtVersion(BLOCK_VERSION, index, timestamp, caller, parentHash, event)
  };

  /// Encode at an explicit version. The journal always writes `BLOCK_VERSION`;
  /// this exists so that a legacy stream can be produced and replayed against
  /// the current decoder, which is how the version-3 compatibility criterion is
  /// tested rather than asserted.
  public func encodeBlockAtVersion(version : Nat8, index : Nat, timestamp : Nat64, caller : Principal, parentHash : ?Blob, event : T.Event) : { bytes : Blob; hash : Blob } {
    let w = Writer();
    w.byte(version);
    w.nat(index);
    w.nat64(timestamp);
    w.principal(caller);
    w.optBlob(parentHash);
    w.event(event);
    let preimage = w.toArray();
    let hash = sha256Domain(BLOCK_DOMAIN, preimage);
    w.blobRaw(hash);
    { bytes = w.toBlob(); hash }
  };

  /// Decode a stored block. Verifies that the stored hash matches the
  /// recomputed hash of the preimage; a mismatch yields null so that a
  /// corrupted log entry can never be served as genuine.
  public func decodeBlock(bytes : Blob) : ?T.Block {
    let data = Blob.toArray(bytes);
    let r = Reader(data);
    let ?version = r.byte() else return null;
    if (not supportsVersion(version)) return null;
    let ?index = r.nat() else return null;
    let ?timestamp = r.nat64() else return null;
    let ?caller = r.principal() else return null;
    let ?parentHash = r.optBlob() else return null;
    let ?event = r.event() else return null;
    let preimageLen = r.position();
    let ?storedHash = r.take(32) else return null;
    if (r.remaining() != 0) return null;
    let preimage = Array.tabulate<Nat8>(preimageLen, func(i) { data[i] });
    let recomputed = sha256Domain(BLOCK_DOMAIN, preimage);
    let stored = Blob.fromArray(storedHash);
    if (recomputed != stored) return null;
    ?{ index; timestamp; caller; parentHash; hash = stored; event }
  };

  /// Content hash of a posting record, for idempotency-key comparison.
  public func postingContentHash(p : T.PostingRecord) : Blob {
    let w = Writer();
    w.posting(p);
    sha256Domain(POSTING_DOMAIN, w.toArray())
  };

  /// Idempotency scope key: H(domain || caller || key). Scoping by caller means
  /// two principals can never collide on, or pre-empt, each other's keys.
  public func idempotencyScopeKey(caller : Principal, key : Blob) : Blob {
    let w = Writer();
    w.principal(caller);
    w.blob(key);
    sha256Domain(IDEMPOTENCY_DOMAIN, w.toArray())
  };

  public func hex(b : Blob) : Text {
    let digits = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f"];
    var out = "";
    for (x in b.vals()) { let n = Nat8.toNat(x); out #= digits[n / 16] # digits[n % 16] };
    out
  };
};
