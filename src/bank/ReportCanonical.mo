/// ReportCanonical.mo: the canonical bytes of the reporting vocabulary.
///
/// Tag per variant, additive for ever, and a decoder that reads what it knows. The
/// definitions and templates a report's identity is built from are encoded here, so the hash
/// a filing carries is produced by the same encoder that produces its block.

import Nat "mo:core/Nat";
import Int "mo:core/Int";
import List "mo:core/List";

import C "mo:journal/Canonical";

import T "ReportTypes";

module {

  // ─── shared pieces ─────────────────────────────────────────────────────────

  public func wDimension(w : C.Writer, d : T.Dimension) {
    switch (d) {
      case (#account) w.byte(0x01);
      case (#accountRange(r)) { w.byte(0x02); w.nat(r.lo); w.nat(r.hi) };
      case (#leadsheet) w.byte(0x03);
      case (#category) w.byte(0x04);
      case (#currency) w.byte(0x05);
      case (#book) w.byte(0x06);
      case (#product) w.byte(0x07);
      case (#counterpartyClass(c)) { w.byte(0x08); w.text(c.schema); w.text(c.field) };
    };
  };

  public func rDimension(r : C.Reader) : ?T.Dimension {
    switch (r.byte()) {
      case (?0x01) ?#account;
      case (?0x02) { let ?lo = r.nat() else return null; let ?hi = r.nat() else return null; ?#accountRange({ lo; hi }) };
      case (?0x03) ?#leadsheet;
      case (?0x04) ?#category;
      case (?0x05) ?#currency;
      case (?0x06) ?#book;
      case (?0x07) ?#product;
      case (?0x08) { let ?s = r.text() else return null; let ?f = r.text() else return null; ?#counterpartyClass({ schema = s; field = f }) };
      case (_) null;
    }
  };

  public func wMeasure(w : C.Writer, m : T.Measure) {
    switch (m) {
      case (#periodDebits) w.byte(0x11);
      case (#periodCredits) w.byte(0x12);
      case (#closingDebits) w.byte(0x13);
      case (#closingCredits) w.byte(0x14);
      case (#netMovement) w.byte(0x15);
      case (#closingBalance) w.byte(0x16);
      case (#entryCount) w.byte(0x17);
      case (#balanceAsOf(d)) { w.byte(0x18); w.nat(d) };
      case (#valueDatedBalance(d)) { w.byte(0x19); w.nat(d) };
    };
  };

  public func rMeasure(r : C.Reader) : ?T.Measure {
    switch (r.byte()) {
      case (?0x11) ?#periodDebits;
      case (?0x12) ?#periodCredits;
      case (?0x13) ?#closingDebits;
      case (?0x14) ?#closingCredits;
      case (?0x15) ?#netMovement;
      case (?0x16) ?#closingBalance;
      case (?0x17) ?#entryCount;
      case (?0x18) { let ?d = r.nat() else return null; ?#balanceAsOf(d) };
      case (?0x19) { let ?d = r.nat() else return null; ?#valueDatedBalance(d) };
      case (_) null;
    }
  };

  func wInt(w : C.Writer, x : Int) {
    if (x < 0) { w.byte(1); w.nat(Int.abs(x)) } else { w.byte(0); w.nat(Int.abs(x)) };
  };

  func rInt(r : C.Reader) : ?Int {
    let ?sign = r.byte() else return null;
    let ?n = r.nat() else return null;
    if (sign == 1) ?(-n) else if (sign == 0) ?n else null
  };

  public func wDef(w : C.Writer, d : T.ReportDef) {
    w.text(d.id); w.nat(d.version); w.text(d.title);
    w.len16(d.rows.size());
    for (x in d.rows.vals()) wDimension(w, x);
    w.len16(d.filters.size());
    for (f in d.filters.vals()) {
      wDimension(w, f.dimension);
      switch (f.op) {
        case (#eq(v)) { w.byte(0x21); w.text(v) };
        case (#inSet(xs)) { w.byte(0x22); w.len16(xs.size()); for (x in xs.vals()) w.text(x) };
        case (#range(g)) { w.byte(0x23); w.nat(g.lo); w.nat(g.hi) };
      };
    };
    w.len16(d.measures.size());
    for (m in d.measures.vals()) wMeasure(w, m);
    switch (d.ordering) {
      case (#byRowKey) w.byte(0x31);
      case (#byCategoryThenAccount) w.byte(0x32);
      case (#byMeasureDescending(k)) { w.byte(0x33); w.nat(k) };
    };
    w.byte(switch (d.scale) { case (#minorUnits) 0; case (#units) 1; case (#thousands) 2; case (#millions) 3 });
    w.byte(switch (d.comparatives) { case (#none) 0; case (#priorPeriod) 1; case (#priorYear) 2 });
    w.nat(d.maxSlice);
  };

  public func rDef(r : C.Reader) : ?T.ReportDef {
    let ?id = r.text() else return null;
    let ?version = r.nat() else return null;
    let ?title = r.text() else return null;
    let ?nr = r.len16() else return null;
    let rows = List.empty<T.Dimension>();
    var i = 0;
    while (i < nr) { let ?d = rDimension(r) else return null; List.add(rows, d); i += 1 };
    let ?nf = r.len16() else return null;
    let filters = List.empty<T.Filter>();
    i := 0;
    while (i < nf) {
      let ?d = rDimension(r) else return null;
      let ?tag = r.byte() else return null;
      let op : T.FilterOp = switch (tag) {
        case (0x21) { let ?v = r.text() else return null; #eq(v) };
        case (0x22) {
          let ?n = r.len16() else return null;
          let xs = List.empty<Text>();
          var k = 0;
          while (k < n) { let ?x = r.text() else return null; List.add(xs, x); k += 1 };
          #inSet(List.toArray(xs))
        };
        case (0x23) { let ?lo = r.nat() else return null; let ?hi = r.nat() else return null; #range({ lo; hi }) };
        case (_) return null;
      };
      List.add(filters, { dimension = d; op });
      i += 1;
    };
    let ?nm = r.len16() else return null;
    let measures = List.empty<T.Measure>();
    i := 0;
    while (i < nm) { let ?m = rMeasure(r) else return null; List.add(measures, m); i += 1 };
    let ?otag = r.byte() else return null;
    let ordering : T.Ordering = switch (otag) {
      case (0x31) #byRowKey;
      case (0x32) #byCategoryThenAccount;
      case (0x33) { let ?k = r.nat() else return null; #byMeasureDescending(k) };
      case (_) return null;
    };
    let ?stag = r.byte() else return null;
    let scale : T.Scale = switch (stag) { case (0) #minorUnits; case (1) #units; case (2) #thousands; case (3) #millions; case (_) return null };
    let ?ctag = r.byte() else return null;
    let comparatives : T.Comparative = switch (ctag) { case (0) #none; case (1) #priorPeriod; case (2) #priorYear; case (_) return null };
    let ?maxSlice = r.nat() else return null;
    ?{
      id; version; title;
      rows = List.toArray(rows);
      filters = List.toArray(filters);
      measures = List.toArray(measures);
      ordering; scale; comparatives; maxSlice;
    }
  };

  public func wTemplate(w : C.Writer, t : T.ReturnTemplate) {
    w.text(t.id); w.nat(t.version); w.text(t.title); w.text(t.authority); w.text(t.currency);
    switch (t.taxonomy) { case null w.byte(0); case (?x) { w.byte(1); w.text(x) } };
    w.len16(t.parameters.size());
    for (p in t.parameters.vals()) { w.text(p.name); w.nat(p.numerator); w.nat(p.denominator) };
    w.len16(t.lines.size());
    for (l in t.lines.vals()) {
      w.text(l.code); w.text(l.caption);
      switch (l.binding) { case null w.byte(0); case (?b) { w.byte(1); w.text(b) } };
      switch (l.source) {
        case (#sumOfAccounts(s)) { w.byte(0x01); w.len16(s.accounts.size()); for (a in s.accounts.vals()) w.text(a); wMeasure(w, s.measure) };
        case (#sumOfRanges(s)) { w.byte(0x02); w.len16(s.ranges.size()); for (g in s.ranges.vals()) { w.nat(g.lo); w.nat(g.hi) }; wMeasure(w, s.measure) };
        case (#sumOfLines(s)) { w.byte(0x03); w.len16(s.lines.size()); for (x in s.lines.vals()) w.text(x) };
        case (#difference(d)) { w.byte(0x04); w.text(d.minuend); w.text(d.subtrahend) };
        case (#ratio(x)) {
          w.byte(0x05); w.text(x.numerator); w.text(x.denominator); w.nat(x.scale);
          w.byte(switch (x.whenZero) { case (#reportZero) 0; case (#reportUnmeasurable) 1; case (#refuse) 2 });
        };
        case (#weighted(x)) { w.byte(0x06); w.text(x.line); w.nat(x.numerator); w.nat(x.denominator) };
        case (#declared(d)) { w.byte(0x07); wInt(w, d.value) };
      };
    };
  };

  public func rTemplate(r : C.Reader) : ?T.ReturnTemplate {
    let ?id = r.text() else return null;
    let ?version = r.nat() else return null;
    let ?title = r.text() else return null;
    let ?authority = r.text() else return null;
    let ?currency = r.text() else return null;
    let taxonomy = switch (r.byte()) {
      case (?0) null;
      case (?1) { let ?x = r.text() else return null; ?x };
      case (_) return null;
    };
    let ?np = r.len16() else return null;
    let params = List.empty<{ name : Text; numerator : Nat; denominator : Nat }>();
    var i = 0;
    while (i < np) {
      let ?n = r.text() else return null;
      let ?num = r.nat() else return null;
      let ?den = r.nat() else return null;
      List.add(params, { name = n; numerator = num; denominator = den });
      i += 1;
    };
    let ?nl = r.len16() else return null;
    let lines = List.empty<T.ReturnLine>();
    i := 0;
    while (i < nl) {
      let ?code = r.text() else return null;
      let ?caption = r.text() else return null;
      let binding = switch (r.byte()) {
        case (?0) null;
        case (?1) { let ?b = r.text() else return null; ?b };
        case (_) return null;
      };
      let ?tag = r.byte() else return null;
      let source : T.LineSource = switch (tag) {
        case (0x01) {
          let ?n = r.len16() else return null;
          let accounts = List.empty<Text>();
          var k = 0;
          while (k < n) { let ?a = r.text() else return null; List.add(accounts, a); k += 1 };
          let ?m = rMeasure(r) else return null;
          #sumOfAccounts({ accounts = List.toArray(accounts); measure = m })
        };
        case (0x02) {
          let ?n = r.len16() else return null;
          let ranges = List.empty<{ lo : Nat; hi : Nat }>();
          var k = 0;
          while (k < n) {
            let ?lo = r.nat() else return null;
            let ?hi = r.nat() else return null;
            List.add(ranges, { lo; hi });
            k += 1;
          };
          let ?m = rMeasure(r) else return null;
          #sumOfRanges({ ranges = List.toArray(ranges); measure = m })
        };
        case (0x03) {
          let ?n = r.len16() else return null;
          let xs = List.empty<Text>();
          var k = 0;
          while (k < n) { let ?x = r.text() else return null; List.add(xs, x); k += 1 };
          #sumOfLines({ lines = List.toArray(xs) })
        };
        case (0x04) { let ?a = r.text() else return null; let ?b = r.text() else return null; #difference({ minuend = a; subtrahend = b }) };
        case (0x05) {
          let ?n = r.text() else return null;
          let ?d = r.text() else return null;
          let ?sc = r.nat() else return null;
          let ?z = r.byte() else return null;
          let whenZero : T.ZeroDenominator = switch (z) { case (0) #reportZero; case (1) #reportUnmeasurable; case (2) #refuse; case (_) return null };
          #ratio({ numerator = n; denominator = d; scale = sc; whenZero })
        };
        case (0x06) {
          let ?l = r.text() else return null;
          let ?num = r.nat() else return null;
          let ?den = r.nat() else return null;
          #weighted({ line = l; numerator = num; denominator = den })
        };
        case (0x07) { let ?v = rInt(r) else return null; #declared({ value = v }) };
        case (_) return null;
      };
      List.add(lines, { code; caption; source; binding });
      i += 1;
    };
    ?{ id; version; title; authority; currency; lines = List.toArray(lines); taxonomy; parameters = List.toArray(params) }
  };

  func wMap(w : C.Writer, m : T.StatementMap) {
    w.len16(m.cash.size()); for (x in m.cash.vals()) w.text(x);
    w.text(m.retainedEarnings);
    w.len16(m.investing.size()); for (x in m.investing.vals()) w.text(x);
    w.len16(m.financing.size()); for (x in m.financing.vals()) w.text(x);
    w.len16(m.monetary.size()); for (x in m.monetary.vals()) w.text(x);
  };

  func rTexts(r : C.Reader) : ?[Text] {
    let ?n = r.len16() else return null;
    let out = List.empty<Text>();
    var i = 0;
    while (i < n) { let ?x = r.text() else return null; List.add(out, x); i += 1 };
    ?List.toArray(out)
  };

  func rMap(r : C.Reader) : ?T.StatementMap {
    let ?cash = rTexts(r) else return null;
    let ?re = r.text() else return null;
    let ?investing = rTexts(r) else return null;
    let ?financing = rTexts(r) else return null;
    let ?monetary = rTexts(r) else return null;
    ?{ cash; retainedEarnings = re; investing; financing; monetary }
  };

  func wBalanceType(w : C.Writer, k : T.BalanceType) {
    w.byte(switch (k) { case (#OPBD) 1; case (#CLBD) 2; case (#ITBD) 3; case (#PRCD) 4; case (#CLAV) 5 });
  };

  func rBalanceType(r : C.Reader) : ?T.BalanceType {
    switch (r.byte()) {
      case (?1) ?#OPBD; case (?2) ?#CLBD; case (?3) ?#ITBD; case (?4) ?#PRCD; case (?5) ?#CLAV;
      case (_) null;
    }
  };

  func wStatement(w : C.Writer, s : T.StatementRef) {
    w.text(s.id); w.nat(s.account);
    switch (s.kind) {
      case (#camt053(x)) { w.byte(0x53); w.nat(x.cut) };
      case (#camt052(x)) { w.byte(0x52); w.nat(x.asOf) };
      case (#camt054(x)) { w.byte(0x54); w.nat(x.movement) };
    };
    w.text(s.currency); w.text(s.period);
    w.len16(s.balances.size());
    for (b in s.balances.vals()) { wBalanceType(w, b.kind); w.nat(b.debits); w.nat(b.credits); wInt(w, b.net) };
    w.len16(s.entryBlocks.size());
    for (i in s.entryBlocks.vals()) w.nat(i);
    w.nat(s.issued);
    w.blob(s.contentHash);
    w.nat(s.atHeight);
  };

  func rStatement(r : C.Reader) : ?T.StatementRef {
    let ?id = r.text() else return null;
    let ?account = r.nat() else return null;
    let ?ktag = r.byte() else return null;
    let kind : T.StatementKind = switch (ktag) {
      case (0x53) { let ?d = r.nat() else return null; #camt053({ cut = d }) };
      case (0x52) { let ?d = r.nat() else return null; #camt052({ asOf = d }) };
      case (0x54) { let ?d = r.nat() else return null; #camt054({ movement = d }) };
      case (_) return null;
    };
    let ?currency = r.text() else return null;
    let ?period = r.text() else return null;
    let ?nb = r.len16() else return null;
    let balances = List.empty<T.StatementBalance>();
    var i = 0;
    while (i < nb) {
      let ?k = rBalanceType(r) else return null;
      let ?d = r.nat() else return null;
      let ?c = r.nat() else return null;
      let ?n = rInt(r) else return null;
      List.add(balances, { kind = k; debits = d; credits = c; net = n });
      i += 1;
    };
    let ?ne = r.len16() else return null;
    let blocks = List.empty<Nat>();
    i := 0;
    while (i < ne) { let ?x = r.nat() else return null; List.add(blocks, x); i += 1 };
    let ?issued = r.nat() else return null;
    let ?hash = r.blob() else return null;
    let ?atHeight = r.nat() else return null;
    ?{
      id; account; kind; currency; period;
      balances = List.toArray(balances);
      entryBlocks = List.toArray(blocks);
      issued; contentHash = hash; atHeight;
    }
  };

  func wEndpoint(w : C.Writer, e : T.FeedEndpoint) {
    w.text(e.url);
    w.len16(e.retries.size());
    for (x in e.retries.vals()) w.nat(x);
    w.byte(if (e.active) 1 else 0);
  };

  func rEndpoint(r : C.Reader) : ?T.FeedEndpoint {
    let ?url = r.text() else return null;
    let ?n = r.len16() else return null;
    let retries = List.empty<Nat>();
    var i = 0;
    while (i < n) { let ?x = r.nat() else return null; List.add(retries, x); i += 1 };
    let ?a = r.byte() else return null;
    ?{ url; retries = List.toArray(retries); active = a == 1 }
  };

  // ─── the events ────────────────────────────────────────────────────────────

  public func writeEvent(w : C.Writer, e : T.ReportEvent) {
    switch (e) {
      case (#reportDefinitionRegistered(x)) { w.byte(0x01); wDef(w, x.definition); w.blob(x.hash) };
      case (#returnTemplateRegistered(x)) { w.byte(0x02); wTemplate(w, x.template); w.blob(x.hash) };
      case (#statementMapSet(x)) { w.byte(0x03); w.text(x.book); wMap(w, x.map) };
      case (#reportCertified(x)) {
        w.byte(0x04); w.text(x.kind); w.text(x.id); w.text(x.book); w.text(x.period);
        w.nat(x.atHeight); w.blob(x.contentHash); w.nat(x.rows);
      };
      case (#statementIssued(x)) { w.byte(0x05); wStatement(w, x.statement) };
      case (#feedEndpointSet(x)) { w.byte(0x06); wEndpoint(w, x.endpoint) };
      case (#feedDeadLettered(x)) {
        w.byte(0x07); w.nat(x.letter.cursor); w.text(x.letter.endpoint);
        w.nat(x.letter.attempts); w.text(x.letter.reason);
      };
    };
  };

  public func readEvent(r : C.Reader) : ?T.ReportEvent {
    let ?tag = r.byte() else return null;
    switch (tag) {
      case 0x01 {
        let ?d = rDef(r) else return null;
        let ?h = r.blob() else return null;
        ?#reportDefinitionRegistered({ definition = d; hash = h })
      };
      case 0x02 {
        let ?t = rTemplate(r) else return null;
        let ?h = r.blob() else return null;
        ?#returnTemplateRegistered({ template = t; hash = h })
      };
      case 0x03 {
        let ?b = r.text() else return null;
        let ?m = rMap(r) else return null;
        ?#statementMapSet({ book = b; map = m })
      };
      case 0x04 {
        let ?kind = r.text() else return null;
        let ?id = r.text() else return null;
        let ?book = r.text() else return null;
        let ?period = r.text() else return null;
        let ?atHeight = r.nat() else return null;
        let ?hash = r.blob() else return null;
        let ?rows = r.nat() else return null;
        ?#reportCertified({ kind; id; book; period; atHeight; contentHash = hash; rows })
      };
      case 0x05 { let ?s = rStatement(r) else return null; ?#statementIssued({ statement = s }) };
      case 0x06 { let ?e = rEndpoint(r) else return null; ?#feedEndpointSet({ endpoint = e }) };
      case 0x07 {
        let ?cursor = r.nat() else return null;
        let ?endpoint = r.text() else return null;
        let ?attempts = r.nat() else return null;
        let ?reason = r.text() else return null;
        ?#feedDeadLettered({ letter = { cursor; endpoint; attempts; reason } })
      };
      case _ null;
    }
  };
};
