/// Pack.mo: a closed range of journal blocks, re-encoded column-wise, and unpacked to the exact
/// original bytes.
///
/// The packing rule: "a closed month's postings are re-encoded
/// column-wise: dictionary-coded accounts, currencies and narration templates; delta-coded dates
/// and posting numbers; varint amounts … deterministic, simple codecs only; no general-purpose
/// compressor inside the contract … a packed month unpacks to the exact original posting bytes."
///
/// The unit packed is a **contiguous block range** of the journal's log, `[lo, hi]`, because that
/// is what an archive serves and what a Merkle proof indexes. Every block in the range is packed,
/// posting or not: a posting record goes through the columns below; any other event is stored as
/// its canonical event bytes, which are short and rare (a business-date roll a day, a period open
/// or close a month). Nothing hashed is dropped; the idempotency key, the narration, every leg;
/// because the block's hash covers them and the archived block must stay provable against the
/// certified MMR root. What a closed month drops is the **index state** built from these blocks
/// (`Packing.mo`), not the blocks.
///
/// ## Losslessness is checked, not asserted
///
/// `pack` takes the raw stored bytes of every block beside its decoded form, encodes, **unpacks
/// its own output and compares byte for byte with the raw bytes before returning**. A pack that
/// would not round-trip is refused with the block that broke it. The hash chain is not stored;
/// each block's hash is recomputed on unpack from its content and the previous hash, and the
/// first block's parent hash is the one field carried whole; so a pack that unpacks to the same
/// bytes has also re-derived every hash the MMR committed to.
///
/// ## The codec
///
/// Varints are unsigned LEB128; signed deltas are zigzag then LEB128; texts and blobs are a varint
/// length and the bytes. A pack is:
///
/// ```
/// "TBPK" ‖ version(1) ‖ lo ‖ count ‖ firstParentHash(optBlob)
/// ‖ dictionaries: accounts, currencies, narrations, sourceKinds, sourceIds, periods, subledgers,
///                 callers                    ; each: n ‖ n × (len ‖ bytes), in first-use order
/// ‖ per block, in order:
///     blockVersion(1) ‖ Δtimestamp(zigzag) ‖ caller(dict) ‖ kind(1)
///     kind 0 posted / 1 pending: idempotencyKey(32 raw) ‖ ΔpostingDate(zigzag, from the previous
///         posting's) ‖ ΔvalueDate(zigzag, from this postingDate) ‖ valueDateRequested(0 | 1 ‖ Δ)
///         ‖ period(dict) ‖ legs ‖ legs × (account(dict) ‖ subledger(0 | 1 ‖ dict) ‖ side(1) ‖
///         currency(dict) ‖ amount) ‖ sourceKind(dict) ‖ sourceId(dict) ‖ narration(dict)
///         ‖ relation(0 | 1 ‖ kind(1) ‖ index − original)   [pending: ‖ expiresAt(0 | 1 ‖ nat64)]
///     kind 2 post: index − pendingIndex ‖ postingDate ‖ ΔvalueDate ‖ valueDateRequested ‖ period(dict)
///     kind 3 void: index − pendingIndex ‖ reason(1)
///     kind 4 other: len ‖ canonical event bytes
/// ```

import Array "mo:core/Array";
import Blob "mo:core/Blob";
import List "mo:core/List";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Nat64 "mo:core/Nat64";
import Int "mo:core/Int";
import Text "mo:core/Text";
import Principal "mo:core/Principal";
import Result "mo:core/Result";

import JT "mo:journal/JournalTypes";
import JC "mo:journal/Canonical";

module {

  public let MAGIC : [Nat8] = [0x54, 0x42, 0x50, 0x4B];   // "TBPK"
  public let VERSION : Nat8 = 1;

  // ─── varints ──────────────────────────────────────────────────────────────

  type Buf = List.List<Nat8>;

  func putVarint(b : Buf, value : Nat) {
    var v = value;
    loop {
      let byte = v % 128;
      v /= 128;
      if (v == 0) { List.add(b, Nat8.fromNat(byte)); return } else List.add(b, Nat8.fromNat(byte + 128));
    };
  };

  func zigzag(i : Int) : Nat { if (i >= 0) Int.abs(i) * 2 else Int.abs(i) * 2 - 1 };
  func unzigzag(n : Nat) : Int { if (n % 2 == 0) n / 2 else -(((n + 1) / 2) : Int) };

  func putDelta(b : Buf, from : Nat, to : Nat) { putVarint(b, zigzag(to - from)) };

  func putBytes(b : Buf, bytes : [Nat8]) { putVarint(b, bytes.size()); for (x in bytes.vals()) List.add(b, x) };
  func putBlob(b : Buf, x : Blob) { putBytes(b, Blob.toArray(x)) };

  /// A total reader: every failure is null.
  class Reader(data : [Nat8]) {
    var pos = 0;
    public func position() : Nat { pos };
    public func byte() : ?Nat8 { if (pos >= data.size()) null else { let x = data[pos]; pos += 1; ?x } };
    public func varint() : ?Nat {
      var v = 0; var mul = 1; var i = 0;
      loop {
        let ?x = byte() else return null;
        let n = Nat8.toNat(x);
        v += (n % 128) * mul;
        if (n < 128) return ?v;
        mul *= 128;
        i += 1;
        if (i > 10) return null;
      };
    };
    public func delta(from : Nat) : ?Nat {
      let ?z = varint() else return null;
      let d = unzigzag(z);
      let r : Int = from + d;
      if (r < 0) null else ?Int.abs(r)
    };
    public func bytes() : ?[Nat8] {
      let ?n = varint() else return null;
      if (pos + n > data.size()) return null;
      let out = Array.tabulate<Nat8>(n, func(i) { data[pos + i] });
      pos += n;
      ?out
    };
    public func blob() : ?Blob { switch (bytes()) { case (?b) ?Blob.fromArray(b); case null null } };
    public func text() : ?Text { switch (blob()) { case (?b) Text.decodeUtf8(b); case null null } };
    public func raw(n : Nat) : ?Blob {
      if (pos + n > data.size()) return null;
      let out = Blob.fromArray(Array.tabulate<Nat8>(n, func(i) { data[pos + i] }));
      pos += n;
      ?out
    };
    public func done() : Bool { pos == data.size() };
  };

  // ─── dictionaries ─────────────────────────────────────────────────────────

  class Dict() {
    let index = Map.empty<Blob, Nat>();
    public let entries = List.empty<Blob>();
    public func id(b : Blob) : Nat {
      switch (Map.get(index, Blob.compare, b)) {
        case (?i) i;
        case null { let i = List.size(entries); Map.add(index, Blob.compare, b, i); List.add(entries, b); i };
      }
    };
    public func text(t : Text) : Nat { id(Text.encodeUtf8(t)) };
    public func write(b : Buf) { putVarint(b, List.size(entries)); for (e in List.values(entries)) putBlob(b, e) };
  };

  func readDict(r : Reader) : ?[Blob] {
    let ?n = r.varint() else return null;
    let out = List.empty<Blob>();
    var i = 0;
    while (i < n) { let ?b = r.blob() else return null; List.add(out, b); i += 1 };
    ?List.toArray(out)
  };

  // ─── the block as stored ──────────────────────────────────────────────────

  /// What `pack` is given per block: the bytes the log holds and their decoded form. The version
  /// byte is the first byte of the raw block; it is carried so an older block re-encodes at its own
  /// version.
  public type Stored = { raw : Blob; block : JT.Block };

  public type Unpacked = { raw : Blob; block : JT.Block };

  public type Packed = {
    lo : Nat;
    count : Nat;
    bytes : Blob;
    /// The raw bytes of every block in the range, summed; what the pack replaces.
    rawBytes : Nat;
  };

  // ─── pack ─────────────────────────────────────────────────────────────────

  func kindOf(e : JT.Event) : Nat8 {
    switch (e) { case (#posted(_)) 0; case (#pending(_)) 1; case (#post(_)) 2; case (#void(_)) 3; case (_) 4 }
  };

  /// Pack a contiguous range. Refused when the range is empty, not contiguous, or would not
  /// round-trip; the refusal names the first block that would not.
  public func pack(stored : [Stored]) : Result.Result<Packed, Text> {
    if (stored.size() == 0) return #err("nothing to pack");
    let lo = stored[0].block.index;
    var i = 0;
    while (i < stored.size()) {
      if (stored[i].block.index != lo + i) return #err("the range is not contiguous at block " # Nat.toText(stored[i].block.index));
      i += 1;
    };
    let accounts = Dict(); let currencies = Dict(); let narrations = Dict(); let sourceKinds = Dict();
    let sourceIds = Dict(); let periods = Dict(); let subledgers = Dict(); let callers = Dict();
    // first pass: the dictionaries in first-use order, so the body can be written in one pass
    let body = List.empty<Nat8>();
    var prevTimestamp : Nat = 0;
    var prevPostingDate : Nat = 0;
    var rawTotal = 0;
    for (s in stored.vals()) {
      rawTotal += s.raw.size();
      let rawArr = Blob.toArray(s.raw);
      if (rawArr.size() == 0) return #err("block " # Nat.toText(s.block.index) # " has no bytes");
      List.add(body, rawArr[0]);                              // the block's own version
      putDelta(body, prevTimestamp, Nat64.toNat(s.block.timestamp));
      prevTimestamp := Nat64.toNat(s.block.timestamp);
      putVarint(body, callers.id(Principal.toBlob(s.block.caller)));
      let kind = kindOf(s.block.event);
      List.add(body, kind);
      switch (s.block.event) {
        case (#posted(p)) { prevPostingDate := writeRecord(body, p, s.block.index, prevPostingDate, accounts, currencies, narrations, sourceKinds, sourceIds, periods, subledgers) };
        case (#pending(x)) {
          prevPostingDate := writeRecord(body, x.record, s.block.index, prevPostingDate, accounts, currencies, narrations, sourceKinds, sourceIds, periods, subledgers);
          switch (x.expiresAt) { case null List.add(body, 0 : Nat8); case (?e) { List.add(body, 1 : Nat8); putVarint(body, Nat64.toNat(e)) } };
        };
        case (#post(x)) {
          if (x.pendingIndex > s.block.index) return #err("block " # Nat.toText(s.block.index) # " resolves a later block");
          putVarint(body, s.block.index - x.pendingIndex);
          putVarint(body, x.resolution.postingDate);
          putDelta(body, x.resolution.postingDate, x.resolution.valueDate);
          switch (x.resolution.valueDateRequested) { case null List.add(body, 0 : Nat8); case (?d) { List.add(body, 1 : Nat8); putDelta(body, x.resolution.valueDate, d) } };
          putVarint(body, periods.text(x.resolution.period));
        };
        case (#void(x)) {
          if (x.pendingIndex > s.block.index) return #err("block " # Nat.toText(s.block.index) # " voids a later block");
          putVarint(body, s.block.index - x.pendingIndex);
          List.add(body, switch (x.reason) { case (#requested) (0 : Nat8); case (#expired) (1 : Nat8) });
        };
        case (other) {
          let w = JC.Writer();
          w.event(other);
          putBytes(body, w.toArray());
        };
      };
    };
    let out = List.empty<Nat8>();
    for (m in MAGIC.vals()) List.add(out, m);
    List.add(out, VERSION);
    putVarint(out, lo);
    putVarint(out, stored.size());
    switch (stored[0].block.parentHash) { case null List.add(out, 0 : Nat8); case (?h) { List.add(out, 1 : Nat8); putBlob(out, h) } };
    for (d in [accounts, currencies, narrations, sourceKinds, sourceIds, periods, subledgers, callers].vals()) d.write(out);
    for (x in List.values(body)) List.add(out, x);
    let bytes = Blob.fromArray(List.toArray(out));
    // the round trip, before anything is trusted
    switch (unpack(bytes)) {
      case (#err(why)) return #err("the pack would not unpack: " # why);
      case (#ok(back)) {
        if (back.size() != stored.size()) return #err("the pack unpacks to " # Nat.toText(back.size()) # " blocks, not " # Nat.toText(stored.size()));
        var j = 0;
        while (j < back.size()) {
          if (back[j].raw != stored[j].raw) return #err("block " # Nat.toText(stored[j].block.index) # " does not round-trip");
          j += 1;
        };
      };
    };
    #ok({ lo; count = stored.size(); bytes; rawBytes = rawTotal })
  };

  func writeRecord(
    body : Buf, p : JT.PostingRecord, index : Nat, prevPostingDate : Nat,
    accounts : Dict, currencies : Dict, narrations : Dict, sourceKinds : Dict, sourceIds : Dict, periods : Dict, subledgers : Dict,
  ) : Nat {
    for (x in p.idempotencyKey.vals()) List.add(body, x);   // 32 raw bytes, hashed, kept
    putDelta(body, prevPostingDate, p.postingDate);
    putDelta(body, p.postingDate, p.valueDate);
    switch (p.valueDateRequested) { case null List.add(body, 0 : Nat8); case (?d) { List.add(body, 1 : Nat8); putDelta(body, p.valueDate, d) } };
    putVarint(body, periods.text(p.period));
    putVarint(body, p.legs.size());
    for (leg in p.legs.vals()) {
      putVarint(body, accounts.text(leg.account));
      switch (leg.subledger) { case null List.add(body, 0 : Nat8); case (?s) { List.add(body, 1 : Nat8); putVarint(body, subledgers.id(s)) } };
      List.add(body, switch (leg.side) { case (#debit) (0 : Nat8); case (#credit) (1 : Nat8) });
      putVarint(body, currencies.text(leg.currency));
      putVarint(body, leg.amount);
    };
    putVarint(body, sourceKinds.text(p.sourceRef.kind));
    putVarint(body, sourceIds.text(p.sourceRef.id));
    putVarint(body, narrations.text(p.narration));
    switch (p.relation) {
      case null List.add(body, 0 : Nat8);
      case (?r) {
        List.add(body, 1 : Nat8);
        List.add(body, switch (r.kind) { case (#reversal) (0 : Nat8); case (#correction) (1 : Nat8) });
        putVarint(body, if (r.original <= index) index - r.original else 0);
        // a relation to a later block cannot exist; a later original is written as 0 and the
        // round trip catches the difference
      };
    };
    p.postingDate
  };

  // ─── unpack ───────────────────────────────────────────────────────────────

  public func unpack(bytes : Blob) : Result.Result<[Unpacked], Text> {
    let r = Reader(Blob.toArray(bytes));
    for (m in MAGIC.vals()) { let ?x = r.byte() else return #err("truncated magic"); if (x != m) return #err("not a pack") };
    let ?version = r.byte() else return #err("truncated version");
    if (version != VERSION) return #err("pack version " # Nat.toText(Nat8.toNat(version)) # " is not " # Nat.toText(Nat8.toNat(VERSION)));
    let ?lo = r.varint() else return #err("truncated lo");
    let ?count = r.varint() else return #err("truncated count");
    let ?hasParent = r.byte() else return #err("truncated parent flag");
    var parentHash : ?Blob = null;
    if (hasParent == 1) { let ?h = r.blob() else return #err("truncated parent hash"); parentHash := ?h }
    else if (hasParent != 0) return #err("bad parent flag");
    let ?accounts = readDict(r) else return #err("truncated accounts");
    let ?currencies = readDict(r) else return #err("truncated currencies");
    let ?narrations = readDict(r) else return #err("truncated narrations");
    let ?sourceKinds = readDict(r) else return #err("truncated source kinds");
    let ?sourceIds = readDict(r) else return #err("truncated source ids");
    let ?periods = readDict(r) else return #err("truncated periods");
    let ?subledgers = readDict(r) else return #err("truncated sub-ledgers");
    let ?callers = readDict(r) else return #err("truncated callers");
    func textAt(d : [Blob], i : Nat) : ?Text { if (i >= d.size()) null else Text.decodeUtf8(d[i]) };
    func blobAt(d : [Blob], i : Nat) : ?Blob { if (i >= d.size()) null else ?d[i] };
    let out = List.empty<Unpacked>();
    var prevTimestamp = 0;
    var prevPostingDate = 0;
    var i = 0;
    while (i < count) {
      let index = lo + i;
      let ?blockVersion = r.byte() else return #err("truncated block " # Nat.toText(index));
      let ?ts = r.delta(prevTimestamp) else return #err("bad timestamp at " # Nat.toText(index));
      prevTimestamp := ts;
      let ?ci = r.varint() else return #err("bad caller at " # Nat.toText(index));
      let ?callerBlob = blobAt(callers, ci) else return #err("caller out of dictionary at " # Nat.toText(index));
      let caller = Principal.fromBlob(callerBlob);
      let ?kind = r.byte() else return #err("bad kind at " # Nat.toText(index));
      let event : JT.Event = switch (kind) {
        case 0 {
          let ?(rec, pd) = readRecord(r, index, prevPostingDate, accounts, currencies, narrations, sourceKinds, sourceIds, periods, subledgers, textAt, blobAt) else return #err("bad posting at " # Nat.toText(index));
          prevPostingDate := pd;
          #posted(rec)
        };
        case 1 {
          let ?(rec, pd) = readRecord(r, index, prevPostingDate, accounts, currencies, narrations, sourceKinds, sourceIds, periods, subledgers, textAt, blobAt) else return #err("bad pending at " # Nat.toText(index));
          prevPostingDate := pd;
          let ?flag = r.byte() else return #err("bad expiry at " # Nat.toText(index));
          let expiresAt : ?Nat64 = if (flag == 0) null else { let ?e = r.varint() else return #err("bad expiry at " # Nat.toText(index)); ?Nat64.fromNat(e) };
          #pending({ record = rec; expiresAt })
        };
        case 2 {
          let ?back = r.varint() else return #err("bad resolution at " # Nat.toText(index));
          if (back > index) return #err("bad resolution at " # Nat.toText(index));
          let ?postingDate = r.varint() else return #err("bad resolution date at " # Nat.toText(index));
          let ?valueDate = r.delta(postingDate) else return #err("bad resolution value date at " # Nat.toText(index));
          let ?flag = r.byte() else return #err("bad resolution request at " # Nat.toText(index));
          let valueDateRequested : ?Nat = if (flag == 0) null else { let ?d = r.delta(valueDate) else return #err("bad resolution request at " # Nat.toText(index)); ?d };
          let ?pi = r.varint() else return #err("bad resolution period at " # Nat.toText(index));
          let ?period = textAt(periods, pi) else return #err("period out of dictionary at " # Nat.toText(index));
          #post({ pendingIndex = index - back; resolution = { postingDate; valueDate; valueDateRequested; period } })
        };
        case 3 {
          let ?back = r.varint() else return #err("bad void at " # Nat.toText(index));
          if (back > index) return #err("bad void at " # Nat.toText(index));
          let ?reason = r.byte() else return #err("bad void reason at " # Nat.toText(index));
          #void({ pendingIndex = index - back; reason = switch (reason) { case 0 #requested; case 1 #expired; case _ return #err("bad void reason at " # Nat.toText(index)) } })
        };
        case 4 {
          let ?evBytes = r.bytes() else return #err("bad event bytes at " # Nat.toText(index));
          let er = JC.Reader(evBytes);
          let ?ev = er.event() else return #err("bad event at " # Nat.toText(index));
          ev
        };
        case _ return #err("bad kind at " # Nat.toText(index));
      };
      let enc = JC.encodeBlockAtVersion(blockVersion, index, Nat64.fromNat(ts), caller, parentHash, event);
      List.add(out, { raw = enc.bytes; block = { index; timestamp = Nat64.fromNat(ts); caller; parentHash; hash = enc.hash; event } });
      parentHash := ?enc.hash;
      i += 1;
    };
    if (not r.done()) return #err("trailing bytes after the last block");
    #ok(List.toArray(out))
  };

  func readRecord(
    r : Reader, index : Nat, prevPostingDate : Nat,
    accounts : [Blob], currencies : [Blob], narrations : [Blob], sourceKinds : [Blob], sourceIds : [Blob], periods : [Blob], subledgers : [Blob],
    textAt : ([Blob], Nat) -> ?Text, blobAt : ([Blob], Nat) -> ?Blob,
  ) : ?(JT.PostingRecord, Nat) {
    let ?idempotencyKey = r.raw(32) else return null;
    let ?postingDate = r.delta(prevPostingDate) else return null;
    let ?valueDate = r.delta(postingDate) else return null;
    let ?flag = r.byte() else return null;
    let valueDateRequested : ?Nat = if (flag == 0) null else { let ?d = r.delta(valueDate) else return null; ?d };
    let ?pi = r.varint() else return null;
    let ?period = textAt(periods, pi) else return null;
    let ?n = r.varint() else return null;
    let legs = List.empty<JT.Leg>();
    var i = 0;
    while (i < n) {
      let ?ai = r.varint() else return null;
      let ?account = textAt(accounts, ai) else return null;
      let ?sflag = r.byte() else return null;
      let subledger : ?JT.SubledgerKey = if (sflag == 0) null else { let ?si = r.varint() else return null; let ?s = blobAt(subledgers, si) else return null; ?s };
      let ?side = r.byte() else return null;
      let ?ci = r.varint() else return null;
      let ?currency = textAt(currencies, ci) else return null;
      let ?amount = r.varint() else return null;
      List.add(legs, { account; subledger; side = switch (side) { case 0 #debit; case 1 #credit; case _ return null }; currency; amount });
      i += 1;
    };
    let ?ki = r.varint() else return null;
    let ?kind = textAt(sourceKinds, ki) else return null;
    let ?ii = r.varint() else return null;
    let ?id = textAt(sourceIds, ii) else return null;
    let ?ni = r.varint() else return null;
    let ?narration = textAt(narrations, ni) else return null;
    let ?rflag = r.byte() else return null;
    let relation : ?JT.Relation = if (rflag == 0) null else {
      let ?rk = r.byte() else return null;
      let ?back = r.varint() else return null;
      if (back > index) return null;
      ?{ original = index - back; kind = switch (rk) { case 0 #reversal; case 1 #correction; case _ return null } }
    };
    ?({ idempotencyKey; postingDate; valueDate; valueDateRequested; period; legs = List.toArray(legs); sourceRef = { kind; id }; narration; relation }, postingDate)
  };

  /// What a packed account's list holds per posting: enough for an account statement over a packed
  /// month without the posting's block; the number, the value and posting days, and the account's
  /// own debits and credits in it. Delta-coded: the number as a gap, the days as zigzag deltas.
  public type AccountEntry = { posting : Nat; valueDay : Nat; postingDay : Nat; debits : Nat; credits : Nat };

  public func encodeAccountList(entries : [AccountEntry]) : Blob {
    let b = List.empty<Nat8>();
    putVarint(b, entries.size());
    var prevPosting = 0;
    var prevDay = 0;
    var first = true;
    for (e in entries.vals()) {
      if (first) { putVarint(b, e.posting); first := false } else { assert (e.posting > prevPosting); putVarint(b, e.posting - prevPosting) };
      putDelta(b, prevDay, e.valueDay);
      putDelta(b, e.valueDay, e.postingDay);
      putVarint(b, e.debits);
      putVarint(b, e.credits);
      prevPosting := e.posting;
      prevDay := e.valueDay;
    };
    Blob.fromArray(List.toArray(b))
  };

  public func decodeAccountList(bytes : Blob) : ?[AccountEntry] {
    let r = Reader(Blob.toArray(bytes));
    let ?n = r.varint() else return null;
    let out = List.empty<AccountEntry>();
    var prevPosting = 0;
    var prevDay = 0;
    var i = 0;
    while (i < n) {
      let ?g = r.varint() else return null;
      let posting = if (i == 0) g else prevPosting + g;
      let ?valueDay = r.delta(prevDay) else return null;
      let ?postingDay = r.delta(valueDay) else return null;
      let ?debits = r.varint() else return null;
      let ?credits = r.varint() else return null;
      List.add(out, { posting; valueDay; postingDay; debits; credits });
      prevPosting := posting;
      prevDay := valueDay;
      i += 1;
    };
    if (not r.done()) return null;
    ?List.toArray(out)
  };

  /// The delta-coded posting list a summary row points at: ascending posting numbers as varint
  /// gaps from the previous one. Zero gaps are impossible (a posting is listed once), so the first
  /// entry is written whole.
  public func encodeList(postings : [Nat]) : Blob {
    let b = List.empty<Nat8>();
    putVarint(b, postings.size());
    var prev = 0;
    var first = true;
    for (p in postings.vals()) {
      if (first) { putVarint(b, p); first := false } else { assert (p > prev); putVarint(b, p - prev) };
      prev := p;
    };
    Blob.fromArray(List.toArray(b))
  };

  public func decodeList(bytes : Blob) : ?[Nat] {
    let r = Reader(Blob.toArray(bytes));
    let ?n = r.varint() else return null;
    let out = List.empty<Nat>();
    var prev = 0;
    var i = 0;
    while (i < n) {
      let ?g = r.varint() else return null;
      let p = if (i == 0) g else prev + g;
      List.add(out, p);
      prev := p;
      i += 1;
    };
    if (not r.done()) return null;
    ?List.toArray(out)
  };
}
