/// OriginationCore.mo — the applications for credit, folded from the bank's log, in stable memory (origination and underwriting).
///
/// One 220-byte row per application keyed by its id (the block index that opened it); an index by stage
/// (stage ‖ application → 0) for the pipeline, by party (party ‖ application → stage) for a customer's
/// applications, by account (account → application) so a loan carries its application for ever; the
/// conditions of an approval (application ‖ condition key → met) and the parties' passkeys (party ‖
/// credential key → SubjectPublicKeyInfo). Rows are written by the fold only. The evaluations — the
/// affordability rules, the scorecard, the WebAuthn assertion — are pure functions over recorded data, so the
/// Python oracle of `bank_s32.py` is the same function written twice and the same signature verified twice.

import Array "mo:core/Array";
import Blob "mo:core/Blob";
import List "mo:core/List";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Result "mo:core/Result";
import Runtime "mo:core/Runtime";
import Text "mo:core/Text";
import VarArray "mo:core/VarArray";
import Sha256 "mo:sha2/Sha256";

import C "mo:journal/Canonical";
import RI "mo:ledger/RegionIndex";

import OT "OriginationTypes";
import PT "PartyTypes";
import PayT "PaymentsTypes";
import R "StableRows";
import P256 "P256";
import Base64 "Base64";
import Json "Json";
import OC "OriginationCanonical";

module {

  /// `stage(1) ‖ flags(1) ‖ flags2(1) ‖ party(8) ‖ book(32) ‖ product(32) ‖ currency(8) ‖ amount(8) ‖ termDays(4)
  ///  ‖ openedDay(4) ‖ openedBlock(8) ‖ lastBlock(8) ‖ income(8) ‖ obligations(8) ‖ instalment(8) ‖ dependants(2)
  ///  ‖ verdict(1) ‖ bureauScore(4) ‖ bureauFlags(2) ‖ points(4) ‖ band(1) ‖ decision(1) ‖ approvedAmount(8)
  ///  ‖ approvedTermDays(4) ‖ approvedRateBps(4) ‖ offerHash(32) ‖ offerExpiresAt(4) ‖ documents(2)
  ///  ‖ conditions(2) ‖ conditionsMet(2) ‖ account(8)` — 220 bytes.
  /// flags: hasParty=1, hasFacts=2, hasVerdict=4, bureauRequested=8, hasBureau=16, hasScore=32, hasDecision=64,
  /// hasOffer=128; flags2: agreementRecorded=1, hasAccount=2.
  public type Row = {
    stage : OT.Stage;
    party : ?PT.PartyId;
    book : Text;
    product : Text;
    currency : Text;
    amount : Nat;
    termDays : Nat;
    openedDay : Nat;
    openedBlock : Nat;
    lastBlock : Nat;
    facts : ?OT.Facts;
    verdict : ?{ #pass; #fail; #refer };
    bureauRequested : Bool;
    bureau : ?{ score : Nat; flags : Nat };
    score : ?{ points : Nat; band : OT.ScoreBand };
    decision : ?{ #approve : { amount : Nat; termDays : Nat; rateBps : Nat }; #decline; #refer };
    offer : ?{ hash : Blob; expiresAt : Nat };
    documents : Nat;
    agreementRecorded : Bool;
    conditions : Nat;
    conditionsMet : Nat;
    account : ?Nat;
  };
  public let ROW_BYTES : Nat = 220;
  public let SPKI_BYTES : Nat = 91;
  let MAX_PAGE : Nat = 500;
  func zero32() : Blob { Blob.fromArray(Array.tabulate<Nat8>(32, func(_) { 0 })) };

  public type State = {
    rows : RI.State;          // application(8) -> Row
    byStage : RI.State;       // stage(1) ‖ application(8) -> 0; stale when the row's stage differs
    byParty : RI.State;       // party(8) ‖ application(8) -> stage(1)
    byAccount : RI.State;     // account(8) -> application(8)
    conditions : RI.State;    // application(8) ‖ condition key(8) -> met(1)
    passkeys : RI.State;      // party(8) ‖ credential key(8) -> SubjectPublicKeyInfo(91)
    var policy : ?OT.Policy;
    var affordability : ?OT.AffordabilityModel;
    var scorecard : ?OT.Scorecard;
    var applications : Nat;
    var fulfilled : Nat;
    var declined : Nat;
    var withdrawn : Nat;
    var expired : Nat;
    var passkeyCount : Nat;
  };

  public func newState(arena : RI.Arena) : State {
    {
      rows = RI.newStateIn(arena, { keyBytes = 8; valBytes = ROW_BYTES });
      byStage = RI.newStateIn(arena, { keyBytes = 9; valBytes = 1 });
      byParty = RI.newStateIn(arena, { keyBytes = 16; valBytes = 1 });
      byAccount = RI.newStateIn(arena, { keyBytes = 8; valBytes = 8 });
      conditions = RI.newStateIn(arena, { keyBytes = 16; valBytes = 1 });
      passkeys = RI.newStateIn(arena, { keyBytes = 16; valBytes = SPKI_BYTES });
      var policy = null; var affordability = null; var scorecard = null;
      var applications = 0; var fulfilled = 0; var declined = 0; var withdrawn = 0; var expired = 0; var passkeyCount = 0;
    }
  };

  // ─── codes ────────────────────────────────────────────────────────────────

  public func bandCode(b : OT.ScoreBand) : Nat8 { switch (b) { case (#approve) 0; case (#refer) 1; case (#decline) 2 } };
  public func bandOfCode(c : Nat8) : ?OT.ScoreBand { switch (c) { case 0 ?#approve; case 1 ?#refer; case 2 ?#decline; case _ null } };
  public func bandText(b : OT.ScoreBand) : Text { switch (b) { case (#approve) "approve"; case (#refer) "refer"; case (#decline) "decline" } };
  func verdictCode(v : { #pass; #fail; #refer }) : Nat8 { switch (v) { case (#pass) 0; case (#fail) 1; case (#refer) 2 } };
  func verdictOfCode(c : Nat8) : { #pass; #fail; #refer } { switch (c) { case 1 #fail; case 2 #refer; case _ #pass } };
  public func verdictKind(v : OT.Verdict) : { #pass; #fail; #refer } { switch (v) { case (#pass) #pass; case (#fail(_)) #fail; case (#refer(_)) #refer } };

  // ─── rows ─────────────────────────────────────────────────────────────────

  func encodeRow(r : Row) : Blob {
    let b = R.buf();
    R.putByte(b, OT.stageCode(r.stage));
    var flags : Nat8 = 0;
    if (r.party != null) flags |= 1; if (r.facts != null) flags |= 2; if (r.verdict != null) flags |= 4; if (r.bureauRequested) flags |= 8;
    if (r.bureau != null) flags |= 16; if (r.score != null) flags |= 32; if (r.decision != null) flags |= 64; if (r.offer != null) flags |= 128;
    R.putByte(b, flags);
    var flags2 : Nat8 = 0;
    if (r.agreementRecorded) flags2 |= 1; if (r.account != null) flags2 |= 2;
    R.putByte(b, flags2);
    R.putNat(b, switch (r.party) { case (?p) p; case null 0 }, 8);
    R.putText(b, r.book, 32); R.putText(b, r.product, 32); R.putText(b, r.currency, 8);
    R.putNat(b, r.amount, 8); R.putNat(b, r.termDays, 4); R.putNat(b, r.openedDay, 4); R.putNat(b, r.openedBlock, 8); R.putNat(b, r.lastBlock, 8);
    switch (r.facts) {
      case (?f) { R.putNat(b, f.income, 8); R.putNat(b, f.obligations, 8); R.putNat(b, f.proposedInstalment, 8); R.putNat(b, f.dependants, 2) };
      case null { R.putNat(b, 0, 8); R.putNat(b, 0, 8); R.putNat(b, 0, 8); R.putNat(b, 0, 2) };
    };
    R.putByte(b, switch (r.verdict) { case (?v) verdictCode(v); case null 0 });
    switch (r.bureau) { case (?x) { R.putNat(b, x.score, 4); R.putNat(b, x.flags, 2) }; case null { R.putNat(b, 0, 4); R.putNat(b, 0, 2) } };
    switch (r.score) { case (?x) { R.putNat(b, x.points, 4); R.putByte(b, bandCode(x.band)) }; case null { R.putNat(b, 0, 4); R.putByte(b, 0) } };
    switch (r.decision) {
      case (?#approve(a)) { R.putByte(b, 0); R.putNat(b, a.amount, 8); R.putNat(b, a.termDays, 4); R.putNat(b, a.rateBps, 4) };
      case (?#decline) { R.putByte(b, 1); R.putNat(b, 0, 8); R.putNat(b, 0, 4); R.putNat(b, 0, 4) };
      case (?#refer) { R.putByte(b, 2); R.putNat(b, 0, 8); R.putNat(b, 0, 4); R.putNat(b, 0, 4) };
      case null { R.putByte(b, 0); R.putNat(b, 0, 8); R.putNat(b, 0, 4); R.putNat(b, 0, 4) };
    };
    switch (r.offer) { case (?o) { R.putBlob(b, o.hash, 32); R.putNat(b, o.expiresAt, 4) }; case null { R.putBlob(b, zero32(), 32); R.putNat(b, 0, 4) } };
    R.putNat(b, r.documents, 2); R.putNat(b, r.conditions, 2); R.putNat(b, r.conditionsMet, 2);
    R.putNat(b, switch (r.account) { case (?a) a; case null 0 }, 8);
    R.done(b, ROW_BYTES)
  };

  func decodeRow(v : Blob) : Row {
    let a = Blob.toArray(v);
    let ?stage = OT.stageOfCode(a[0]) else Runtime.trap("OriginationCore: a row with an unknown stage code");
    let flags = a[1]; let flags2 = a[2];
    let decisionCode = a[153];
    {
      stage;
      party = if (flags & 1 == 0) null else ?R.getNat(a, 3, 8);
      book = R.getText(a, 11, 32); product = R.getText(a, 43, 32); currency = R.getText(a, 75, 8);
      amount = R.getNat(a, 83, 8); termDays = R.getNat(a, 91, 4); openedDay = R.getNat(a, 95, 4); openedBlock = R.getNat(a, 99, 8); lastBlock = R.getNat(a, 107, 8);
      facts = if (flags & 2 == 0) null else ?{ income = R.getNat(a, 115, 8); obligations = R.getNat(a, 123, 8); proposedInstalment = R.getNat(a, 131, 8); dependants = R.getNat(a, 139, 2) };
      verdict = if (flags & 4 == 0) null else ?verdictOfCode(a[141]);
      bureauRequested = flags & 8 != 0;
      bureau = if (flags & 16 == 0) null else ?{ score = R.getNat(a, 142, 4); flags = R.getNat(a, 146, 2) };
      score = if (flags & 32 == 0) null else ?{ points = R.getNat(a, 148, 4); band = switch (bandOfCode(a[152])) { case (?b) b; case null #decline } };
      decision = if (flags & 64 == 0) null else switch (decisionCode) {
        case 1 ?#decline; case 2 ?#refer;
        case _ ?#approve({ amount = R.getNat(a, 154, 8); termDays = R.getNat(a, 162, 4); rateBps = R.getNat(a, 166, 4) });
      };
      offer = if (flags & 128 == 0) null else ?{ hash = R.getBlob(a, 170, 32); expiresAt = R.getNat(a, 202, 4) };
      documents = R.getNat(a, 206, 2); agreementRecorded = flags2 & 1 != 0;
      conditions = R.getNat(a, 208, 2); conditionsMet = R.getNat(a, 210, 2);
      account = if (flags2 & 2 == 0) null else ?R.getNat(a, 212, 8);
    }
  };

  public func row(s : State, id : OT.ApplicationId) : ?Row {
    switch (RI.get(s.rows, R.key(id, 8))) { case (?v) ?decodeRow(v); case null null }
  };

  func hashKey(b : Blob) : Nat { R.getNat(Blob.toArray(Sha256.fromBlob(#sha256, b)), 0, 8) };
  func textKey(t : Text) : Nat { hashKey(Text.encodeUtf8(t)) };

  func putRow(s : State, id : OT.ApplicationId, r : Row, block : Nat) {
    let r2 = { r with lastBlock = block };
    ignore RI.put(s.rows, R.key(id, 8), encodeRow(r2));
    ignore RI.put(s.byStage, R.key2(Nat8.toNat(OT.stageCode(r2.stage)), 1, id, 8), Blob.fromArray([0]));
    switch (r2.party) { case (?p) ignore RI.put(s.byParty, R.key2(p, 8, id, 8), Blob.fromArray([OT.stageCode(r2.stage)])); case null {} };
    switch (r2.account) { case (?a) ignore RI.put(s.byAccount, R.key(a, 8), R.key(id, 8)); case null {} };
  };

  // ─── the models ───────────────────────────────────────────────────────────

  public func policy(s : State) : ?OT.Policy { s.policy };
  public func affordabilityModel(s : State) : ?OT.AffordabilityModel { s.affordability };
  public func scorecard(s : State) : ?OT.Scorecard { s.scorecard };

  public func bureauKey(p : OT.Policy, bureau : Text) : ?(PayT.SignatureScheme, Blob) {
    for ((name, scheme, key) in p.bureaus.vals()) { if (Text.equal(name, bureau)) return ?(scheme, key) };
    null
  };

  public func validPolicy(p : OT.Policy) : ?Text {
    if (Text.size(p.rpId) == 0) return ?"a relying-party id is required";
    if (Text.size(p.origin) == 0) return ?"an origin is required";
    if (p.offerValidityDays == 0) return ?"an offer must be valid for at least a day";
    var i = 0;
    for ((name, scheme, key) in p.bureaus.vals()) {
      if (Text.size(name) == 0) return ?"a bureau needs a name";
      if (scheme != #none and key.size() == 0) return ?("bureau " # name # " signs but carries no key");
      var j = 0;
      for ((other, _, _) in p.bureaus.vals()) { if (j < i and Text.equal(other, name)) return ?("bureau " # name # " is listed twice"); j += 1 };
      i += 1;
    };
    null
  };

  public func validAffordabilityModel(m : OT.AffordabilityModel) : ?Text {
    if (Text.size(m.id) == 0) return ?"a model needs an id";
    if (m.rules.size() == 0) return ?"a model needs at least one rule";
    var i = 0;
    for (r in m.rules.vals()) {
      if (Text.size(r.id) == 0) return ?"a rule needs an id";
      var j = 0;
      for (o in m.rules.vals()) { if (j < i and Text.equal(o.id, r.id)) return ?("rule " # r.id # " is listed twice"); j += 1 };
      switch (r.kind) {
        case (#maxDebtServiceRatioBps(b)) { if (b == 0 or b > 10000) return ?("rule " # r.id # ": a debt-service ratio is 1..10000 basis points") };
        case (#maxTermDays(t)) { if (t == 0) return ?("rule " # r.id # ": a maximum term of zero days admits nothing") };
        case (#maxAmount(a)) { if (a == 0) return ?("rule " # r.id # ": a maximum amount of zero admits nothing") };
        case (_) {};
      };
      i += 1;
    };
    null
  };

  public func validScorecard(c : OT.Scorecard) : ?Text {
    if (Text.size(c.id) == 0) return ?"a scorecard needs an id";
    if (c.attributes.size() == 0) return ?"a scorecard needs at least one attribute";
    if (c.declineBelow > c.referBelow) return ?"the decline cut-off cannot exceed the refer cut-off";
    var i = 0;
    for ((attr, bands) in c.attributes.vals()) {
      if (bands.size() == 0) return ?"an attribute needs at least one band";
      for (b in bands.vals()) { switch (b.hi) { case (?h) { if (h < b.lo) return ?"a band's upper bound is below its lower" }; case null {} } };
      var j = 0;
      for ((other, _) in c.attributes.vals()) { if (j < i and other == attr) return ?"an attribute is listed twice"; j += 1 };
      i += 1;
    };
    null
  };

  // ─── the evaluations: pure, the oracle's twins ────────────────────────────

  public func ruleFires(k : OT.RuleKind, f : OT.Facts, req : OT.Request) : Bool {
    switch (k) {
      case (#maxDebtServiceRatioBps(bps)) (f.obligations + f.proposedInstalment) * 10000 > bps * f.income;
      case (#minResidualIncome(perHead)) {
        let committed = f.obligations + f.proposedInstalment;
        let residual : Nat = if (f.income > committed) f.income - committed else 0;
        residual < perHead * (f.dependants + 1)
      };
      case (#maxTermDays(t)) req.termDays > t;
      case (#maxAmount(a)) req.amount > a;
      case (#minIncome(m)) f.income < m;
    }
  };

  /// The verdict of a model over the facts: the failing rules that fired, else the referring ones, else pass.
  public func assess(m : OT.AffordabilityModel, f : OT.Facts, req : OT.Request) : OT.Verdict {
    let failed = List.empty<Text>();
    let referred = List.empty<Text>();
    for (r in m.rules.vals()) {
      if (ruleFires(r.kind, f, req)) { switch (r.onFail) { case (#fail) List.add(failed, r.id); case (#refer) List.add(referred, r.id) } };
    };
    if (List.size(failed) > 0) #fail(List.toArray(failed))
    else if (List.size(referred) > 0) #refer(List.toArray(referred))
    else #pass
  };

  /// The value an attribute takes, if it has one: a ratio of zero income is the largest representable
  /// ratio (every band with an unbounded top holds it); a bureau attribute without a report has no value.
  public func attributeValue(a : OT.Attribute, f : OT.Facts, req : OT.Request, bureau : ?{ score : Nat; flags : Nat }) : ?Nat {
    switch (a) {
      case (#income) ?f.income;
      case (#obligationsRatioBps) ?(if (f.income == 0) 0xFFFF_FFFF else f.obligations * 10000 / f.income);
      case (#bureauScore) { switch (bureau) { case (?b) ?b.score; case null null } };
      case (#bureauFlags) { switch (bureau) { case (?b) ?b.flags; case null null } };
      case (#termDays) ?req.termDays;
      case (#amount) ?req.amount;
    }
  };

  public func bandPoints(bands : [OT.Band], v : Nat) : Nat {
    for (b in bands.vals()) {
      let top = switch (b.hi) { case (?h) v <= h; case null true };
      if (v >= b.lo and top) return b.points;
    };
    0
  };

  public func score(c : OT.Scorecard, f : OT.Facts, req : OT.Request, bureau : ?{ score : Nat; flags : Nat }) : (Nat, OT.ScoreBand) {
    var points = 0;
    for ((attr, bands) in c.attributes.vals()) {
      switch (attributeValue(attr, f, req, bureau)) { case (?v) points += bandPoints(bands, v); case null {} };
    };
    let band : OT.ScoreBand = if (points < c.declineBelow) #decline else if (points < c.referBelow) #refer else #approve;
    (points, band)
  };

  /// A decision departs from the band when it approves what the card declined or declines what it approved;
  /// a referred band is the human's to decide either way.
  public func departsFromBand(d : OT.Decision, band : OT.ScoreBand) : Bool {
    switch (d, band) { case (#approve(_), #decline) true; case (#decline(_), #approve) true; case (_, _) false }
  };

  // ─── canonical bytes the signers sign ─────────────────────────────────────

  /// What a bureau signs: the report's figures with the application they answer, under a domain.
  public func bureauReportBytes(application : OT.ApplicationId, r : OT.BureauReport) : Blob {
    let w = C.Writer();
    w.text("THEBES-BANK-BUREAU-REPORT-v1");
    w.nat(application); w.text(r.bureau); w.nat(r.score); w.len16(r.flags.size()); for (f in r.flags.vals()) w.text(f);
    w.blob(r.reportHash); w.nat(r.reportedOn);
    w.toBlob()
  };

  /// The offer's hash: the challenge the applicant's passkey signs.
  public func offerHash(application : OT.ApplicationId, t : OT.OfferTerms, expiresAt : Nat) : Blob {
    let w = C.Writer();
    w.text("THEBES-BANK-OFFER-v1");
    w.nat(application); w.nat(t.amount); w.nat(t.termDays); w.nat(t.rateBps); w.text(t.product); w.text(t.currency);
    w.len16(t.conditions.size()); for (c in t.conditions.vals()) w.text(c);
    w.nat(expiresAt);
    Sha256.fromBlob(#sha256, w.toBlob())
  };

  public func assertionHash(a : OT.PasskeyAssertion) : Blob {
    let d = Sha256.Digest(#sha256);
    d.writeBlob(a.credentialId); d.writeBlob(a.authenticatorData); d.writeBlob(a.clientDataJSON); d.writeBlob(a.signature);
    d.sum()
  };

  // ─── passkeys ─────────────────────────────────────────────────────────────

  public func passkey(s : State, party : PT.PartyId, credentialId : Blob) : ?Blob {
    RI.get(s.passkeys, R.key2(party, 8, hashKey(credentialId), 8))
  };

  /// A WebAuthn assertion (Level 2 §7.2) over `challenge` under the party's registered passkey: the client
  /// data names the ceremony, the challenge (base64url, unpadded) and the policy's origin; the authenticator
  /// data carries the policy's relying-party id hash and the user-present flag; the ECDSA P-256 signature is
  /// over SHA-256(authenticatorData ‖ SHA-256(clientDataJSON)). Every refusal names its reason.
  public func verifyAssertion(s : State, party : PT.PartyId, challenge : Blob, a : OT.PasskeyAssertion) : Result.Result<(), OT.OriginationError> {
    let ?pol = s.policy else return #err(#NoPolicy);
    let ?spki = passkey(s, party, a.credentialId) else return #err(#UnknownPasskey({ party; credentialId = a.credentialId }));
    let ?(qx, qy) = P256.parseSpki(spki) else return #err(#AssertionRefused({ reason = "the registered key is not a P-256 SubjectPublicKeyInfo" }));
    let ?clientText = Text.decodeUtf8(a.clientDataJSON) else return #err(#AssertionRefused({ reason = "the client data is not UTF-8" }));
    let client = switch (Json.parse(clientText)) { case (#ok(j)) j; case (#err(e)) return #err(#AssertionRefused({ reason = "the client data is not JSON: " # e })) };
    switch (Json.str(client, "type")) { case (?"webauthn.get") {}; case (_) return #err(#AssertionRefused({ reason = "the client data is not a webauthn.get ceremony" })) };
    switch (Json.str(client, "challenge")) {
      case (?c) { if (not Text.equal(c, Base64.encodeUrl(challenge))) return #err(#AssertionRefused({ reason = "the challenge is not the hash offered for signature" })) };
      case null return #err(#AssertionRefused({ reason = "the client data carries no challenge" }));
    };
    switch (Json.str(client, "origin")) {
      case (?o) { if (not Text.equal(o, pol.origin)) return #err(#AssertionRefused({ reason = "the origin is not the bank's" })) };
      case null return #err(#AssertionRefused({ reason = "the client data carries no origin" }));
    };
    let auth = Blob.toArray(a.authenticatorData);
    if (auth.size() < 37) return #err(#AssertionRefused({ reason = "the authenticator data is shorter than 37 bytes" }));
    let rpHash = Blob.toArray(Sha256.fromBlob(#sha256, Text.encodeUtf8(pol.rpId)));
    for (i in Nat.range(0, 32)) { if (auth[i] != rpHash[i]) return #err(#AssertionRefused({ reason = "the relying party is not the bank's" })) };
    if (auth[32] & 0x01 == 0) return #err(#AssertionRefused({ reason = "the user was not present" }));
    let ?(r, sg) = P256.parseDerSignature(a.signature) else return #err(#AssertionRefused({ reason = "the signature is not a DER ECDSA-Sig-Value" }));
    let d = Sha256.Digest(#sha256);
    d.writeBlob(a.authenticatorData);
    d.writeBlob(Sha256.fromBlob(#sha256, a.clientDataJSON));
    let e = P256.natOf(Blob.toArray(d.sum()));
    if (not P256.verify(qx, qy, e, r, sg)) return #err(#AssertionRefused({ reason = "the signature does not verify under the registered passkey" }));
    #ok(())
  };

  // ─── the decided acts, planned ────────────────────────────────────────────

  public type Planned = Result.Result<OT.OriginationEvent, OT.OriginationError>;

  func wrongStage(id : OT.ApplicationId, r : Row, wanted : Text) : OT.OriginationError {
    #WrongStage({ application = id; stage = OT.stageText(r.stage); wanted })
  };

  public func planPolicy(p : OT.Policy) : Planned {
    switch (validPolicy(p)) { case (?reason) #err(#InvalidModel({ reason })); case null #ok(#policySet(p)) }
  };
  public func planAffordabilityModel(s : State, m : OT.AffordabilityModel) : Planned {
    switch (validAffordabilityModel(m)) { case (?reason) return #err(#InvalidModel({ reason })); case null {} };
    switch (s.affordability) {
      case (?cur) { if (Text.equal(cur.id, m.id) and m.version <= cur.version) return #err(#InvalidModel({ reason = "version " # Nat.toText(m.version) # " does not follow " # Nat.toText(cur.version) })) };
      case null {};
    };
    #ok(#affordabilityModelSet(m))
  };
  public func planScorecard(s : State, c : OT.Scorecard) : Planned {
    switch (validScorecard(c)) { case (?reason) return #err(#InvalidModel({ reason })); case null {} };
    switch (s.scorecard) {
      case (?cur) { if (Text.equal(cur.id, c.id) and c.version <= cur.version) return #err(#InvalidModel({ reason = "version " # Nat.toText(c.version) # " does not follow " # Nat.toText(cur.version) })) };
      case null {};
    };
    #ok(#scorecardSet(c))
  };

  public func planRegisterPasskey(s : State, party : PT.PartyId, credentialId : Blob, spki : Blob) : Planned {
    if (credentialId.size() == 0 or credentialId.size() > 1023) return #err(#InvalidRequest({ reason = "a credential id is 1..1023 bytes" }));
    if (P256.parseSpki(spki) == null) return #err(#InvalidRequest({ reason = "the public key is not an uncompressed P-256 SubjectPublicKeyInfo on the curve" }));
    if (passkey(s, party, credentialId) != null) return #err(#PasskeyExists({ party; credentialId }));
    #ok(#passkeyRegistered({ party; credentialId; publicKeySpki = spki }))
  };

  public func planOpen(party : ?PT.PartyId, book : Text, req : OT.Request, channel : Text, day : Nat) : Planned {
    if (req.amount == 0) return #err(#InvalidRequest({ reason = "an application for nothing" }));
    if (req.termDays == 0) return #err(#InvalidRequest({ reason = "a term of zero days" }));
    if (Text.size(req.product) == 0 or Text.encodeUtf8(req.product).size() > 32) return #err(#InvalidRequest({ reason = "a product id is 1..32 bytes" }));
    if (Text.size(req.currency) == 0 or Text.encodeUtf8(req.currency).size() > 8) return #err(#InvalidRequest({ reason = "a currency code is 1..8 bytes" }));
    if (Text.encodeUtf8(book).size() > 32) return #err(#InvalidRequest({ reason = "a book id is at most 32 bytes" }));
    if (Text.encodeUtf8(channel).size() > 64) return #err(#InvalidRequest({ reason = "a channel is at most 64 bytes" }));
    #ok(#applicationOpened({ party; book; request = req; channel; day }))
  };

  /// Facts may be recorded and re-recorded until the decision: a new set sends the application back to
  /// capture, so every evaluation on the log names facts recorded before it.
  public func planRecordData(s : State, id : OT.ApplicationId, facts : OT.Facts, commitments : [(Text, PT.Commitment)]) : Planned {
    let ?r = row(s, id) else return #err(#UnknownApplication({ application = id }));
    switch (r.stage) { case (#capture or #assessed or #scored) {}; case (_) return #err(wrongStage(id, r, "capture, assessed or scored")) };
    for ((k, c) in commitments.vals()) {
      if (Text.size(k) == 0) return #err(#InvalidRequest({ reason = "a commitment needs a field name" }));
      if (c.size() != 32) return #err(#InvalidRequest({ reason = "a commitment is 32 bytes" }));
    };
    #ok(#dataRecorded({ application = id; facts; commitments }))
  };

  public func planAssess(s : State, id : OT.ApplicationId) : Planned {
    let ?r = row(s, id) else return #err(#UnknownApplication({ application = id }));
    let ?m = s.affordability else return #err(#NoModel({ kind = "affordability" }));
    if (r.stage != #capture) return #err(wrongStage(id, r, "capture"));
    let ?f = r.facts else return #err(#InvalidRequest({ reason = "no facts are recorded on the application" }));
    #ok(#affordabilityAssessed({ application = id; model = m.id; version = m.version; verdict = assess(m, f, request(r)) }))
  };

  public func planRequestBureau(s : State, id : OT.ApplicationId, bureau : Text, consentCommit : PT.Commitment, day : Nat) : Planned {
    let ?r = row(s, id) else return #err(#UnknownApplication({ application = id }));
    let ?pol = s.policy else return #err(#NoPolicy);
    if (bureauKey(pol, bureau) == null) return #err(#UnknownBureau({ bureau }));
    switch (r.stage) { case (#capture or #assessed) {}; case (_) return #err(wrongStage(id, r, "capture or assessed")) };
    if (consentCommit.size() != 32) return #err(#InvalidRequest({ reason = "the consent commitment is 32 bytes" }));
    #ok(#bureauRequested({ application = id; bureau; consentCommit; day }))
  };

  /// The report, verified by `verify` under the bureau's registered key over `bureauReportBytes`.
  public func planRecordBureau(s : State, id : OT.ApplicationId, report : OT.BureauReport, signature : Blob, verify : (PayT.SignatureScheme, Blob, Blob, Blob) -> Bool) : Planned {
    let ?r = row(s, id) else return #err(#UnknownApplication({ application = id }));
    let ?pol = s.policy else return #err(#NoPolicy);
    let ?(scheme, key) = bureauKey(pol, report.bureau) else return #err(#UnknownBureau({ bureau = report.bureau }));
    switch (r.stage) { case (#capture or #assessed) {}; case (_) return #err(wrongStage(id, r, "capture or assessed")) };
    if (not r.bureauRequested) return #err(#BureauNotRequested({ application = id; bureau = report.bureau }));
    if (report.reportHash.size() != 32) return #err(#InvalidRequest({ reason = "the report hash is 32 bytes" }));
    if (report.flags.size() > 64) return #err(#InvalidRequest({ reason = "at most 64 flags" }));
    if (not verify(scheme, key, bureauReportBytes(id, report), signature)) return #err(#SignatureInvalid({ bureau = report.bureau }));
    #ok(#bureauRecorded({ application = id; report }))
  };

  public func planScore(s : State, id : OT.ApplicationId) : Planned {
    let ?r = row(s, id) else return #err(#UnknownApplication({ application = id }));
    let ?c = s.scorecard else return #err(#NoModel({ kind = "scorecard" }));
    if (r.stage != #assessed) return #err(wrongStage(id, r, "assessed"));
    let ?f = r.facts else return #err(#InvalidRequest({ reason = "no facts are recorded on the application" }));
    let (points, band) = score(c, f, request(r), r.bureau);
    #ok(#scored({ application = id; scorecard = c.id; version = c.version; points; band }))
  };

  /// The credit decision, four eyes: an approval within the request, a decision against the band only with
  /// a rationale, a failed affordability never approved.
  public func planUnderwrite(s : State, id : OT.ApplicationId, d : OT.Decision, rationale : Text) : Planned {
    let ?r = row(s, id) else return #err(#UnknownApplication({ application = id }));
    if (r.stage != #scored) return #err(wrongStage(id, r, "scored"));
    let ?sc = r.score else return #err(#InvalidRequest({ reason = "the application carries no score" }));
    if (Text.encodeUtf8(rationale).size() > 512) return #err(#InvalidRequest({ reason = "a rationale is at most 512 bytes" }));
    switch (d) {
      case (#approve(a)) {
        if (a.amount == 0 or a.amount > r.amount) return #err(#InvalidRequest({ reason = "an approval is for 1..the requested amount" }));
        if (a.termDays == 0) return #err(#InvalidRequest({ reason = "an approval needs a term" }));
        if (a.rateBps > 100_000) return #err(#InvalidRequest({ reason = "a rate above 1000% a year" }));
        if (a.conditions.size() > 32) return #err(#InvalidRequest({ reason = "at most 32 conditions" }));
        var i = 0;
        for (c in a.conditions.vals()) {
          if (Text.size(c) == 0) return #err(#InvalidRequest({ reason = "a condition needs a name" }));
          var j = 0;
          for (o in a.conditions.vals()) { if (j < i and Text.equal(o, c)) return #err(#InvalidRequest({ reason = "condition " # c # " is listed twice" })); j += 1 };
          i += 1;
        };
        if (r.verdict == ?#fail) return #err(#DecisionAgainstBand({ band = "affordability failed"; reason = "a failed affordability is never approved" }));
      };
      case (#decline(x)) { if (x.reasons.size() == 0) return #err(#InvalidRequest({ reason = "a decline needs a reason" })) };
      case (#refer(x)) { if (Text.size(x.to) == 0) return #err(#InvalidRequest({ reason = "a referral needs a destination" })) };
    };
    let overrode = departsFromBand(d, sc.band);
    if (overrode and Text.size(rationale) == 0) return #err(#DecisionAgainstBand({ band = bandText(sc.band); reason = "a decision against the band needs a rationale" }));
    #ok(#underwritten({ application = id; decision = d; rationale; overrode }))
  };

  /// The offer is the approval's terms, or less; its hash is what the applicant signs.
  public func planIssueOffer(s : State, id : OT.ApplicationId, t : OT.OfferTerms, today : Nat) : Planned {
    let ?r = row(s, id) else return #err(#UnknownApplication({ application = id }));
    let ?pol = s.policy else return #err(#NoPolicy);
    if (r.stage != #underwritten) return #err(wrongStage(id, r, "underwritten"));
    let ?#approve(a) = r.decision else return #err(#OfferMismatch({ reason = "the application was not approved" }));
    if (t.amount == 0 or t.amount > a.amount) return #err(#OfferMismatch({ reason = "the offer exceeds the approved amount" }));
    if (t.termDays != a.termDays) return #err(#OfferMismatch({ reason = "the offer's term is not the approved term" }));
    if (t.rateBps != a.rateBps) return #err(#OfferMismatch({ reason = "the offer's rate is not the approved rate" }));
    if (not Text.equal(t.product, r.product)) return #err(#OfferMismatch({ reason = "the offer's product is not the application's" }));
    if (not Text.equal(t.currency, r.currency)) return #err(#OfferMismatch({ reason = "the offer's currency is not the application's" }));
    if (t.conditions.size() != r.conditions) return #err(#OfferMismatch({ reason = "the offer's conditions are not the approval's" }));
    for (c in t.conditions.vals()) { if (RI.get(s.conditions, conditionKey(id, c)) == null) return #err(#OfferMismatch({ reason = "condition " # c # " is not the approval's" })) };
    let expiresAt = today + pol.offerValidityDays;
    #ok(#offerIssued({ application = id; terms = t; offerHash = offerHash(id, t, expiresAt); expiresAt }))
  };

  public func planAccept(s : State, id : OT.ApplicationId, a : OT.PasskeyAssertion, today : Nat) : Planned {
    let ?r = row(s, id) else return #err(#UnknownApplication({ application = id }));
    if (r.stage != #offered) return #err(wrongStage(id, r, "offered"));
    let ?o = r.offer else return #err(#InvalidRequest({ reason = "the application carries no offer" }));
    if (today > o.expiresAt) return #err(#OfferExpired({ application = id; expiresAt = o.expiresAt; today }));
    let ?party = r.party else return #err(#NoParty({ application = id }));
    switch (verifyAssertion(s, party, o.hash, a)) { case (#err(e)) return #err(e); case (#ok(_)) {} };
    #ok(#offerAccepted({ application = id; credentialId = a.credentialId; assertionHash = assertionHash(a); day = today }))
  };

  public func planDeclineOffer(s : State, id : OT.ApplicationId, today : Nat) : Planned {
    let ?r = row(s, id) else return #err(#UnknownApplication({ application = id }));
    if (r.stage != #offered) return #err(wrongStage(id, r, "offered"));
    #ok(#offerDeclined({ application = id; day = today }))
  };

  /// A document's hash, and whether the applicant signed it (the hash as the challenge).
  public func planRecordDocument(s : State, id : OT.ApplicationId, kind : OT.DocumentKind, sha256 : Blob, signed : ?OT.PasskeyAssertion) : Planned {
    let ?r = row(s, id) else return #err(#UnknownApplication({ application = id }));
    switch (r.stage) { case (#accepted or #documented) {}; case (_) return #err(wrongStage(id, r, "accepted or documented")) };
    if (sha256.size() != 32) return #err(#InvalidRequest({ reason = "a document hash is 32 bytes" }));
    switch (kind) { case (#other(t)) { if (Text.size(t) == 0 or Text.encodeUtf8(t).size() > 64) return #err(#InvalidRequest({ reason = "a document kind is 1..64 bytes" })) }; case (_) {} };
    let isSigned = switch (signed) {
      case null false;
      case (?a) {
        let ?party = r.party else return #err(#NoParty({ application = id }));
        switch (verifyAssertion(s, party, sha256, a)) { case (#err(e)) return #err(e); case (#ok(_)) true };
      };
    };
    #ok(#documentRecorded({ application = id; kind; sha256; signed = isSigned }))
  };

  public func planConditionsMet(s : State, id : OT.ApplicationId, conds : [Text]) : Planned {
    let ?r = row(s, id) else return #err(#UnknownApplication({ application = id }));
    switch (r.stage) { case (#accepted or #documented) {}; case (_) return #err(wrongStage(id, r, "accepted or documented")) };
    if (conds.size() == 0) return #err(#InvalidRequest({ reason = "name the conditions met" }));
    var newlyMet = 0;
    var i = 0;
    for (c in conds.vals()) {
      var j = 0;
      for (o in conds.vals()) { if (j < i and Text.equal(o, c)) return #err(#InvalidRequest({ reason = "condition " # c # " is listed twice" })); j += 1 };
      switch (RI.get(s.conditions, conditionKey(id, c))) {
        case null return #err(#UnknownCondition({ application = id; condition = c }));
        case (?v) { if (Blob.toArray(v)[0] == 0) newlyMet += 1 };
      };
      i += 1;
    };
    let met = r.conditionsMet + newlyMet;
    #ok(#conditionsMet({ application = id; conditions = conds; outstanding = r.conditions - met }))
  };

  /// Documentation is complete when the applicant has accepted, every condition is met and the facility
  /// agreement is on file.
  public func documentationComplete(r : Row) : Bool {
    r.stage == #accepted and r.conditionsMet == r.conditions and r.agreementRecorded
  };
  /// Whether the act just planned completes the documentation, so the planner adds the block that says so.
  public func completesDocumentation(s : State, id : OT.ApplicationId, ev : OT.OriginationEvent) : Bool {
    let ?r = row(s, id) else return false;
    switch (ev) {
      case (#documentRecorded(x)) documentationComplete({ r with agreementRecorded = r.agreementRecorded or x.kind == #facilityAgreement });
      case (#conditionsMet(x)) documentationComplete({ r with conditionsMet = r.conditions - x.outstanding });
      case (_) false;
    }
  };

  /// What the drawing needs: the approved terms of a documented application with a party.
  public func planFulfil(s : State, id : OT.ApplicationId) : Result.Result<{ party : PT.PartyId; book : Text; product : Text; currency : Text; amount : Nat; termDays : Nat; rateBps : Nat }, OT.OriginationError> {
    let ?r = row(s, id) else return #err(#UnknownApplication({ application = id }));
    if (r.stage != #documented) return #err(wrongStage(id, r, "documented"));
    let ?party = r.party else return #err(#NoParty({ application = id }));
    if (r.conditionsMet < r.conditions) return #err(#ConditionsOutstanding({ application = id; outstanding = r.conditions - r.conditionsMet }));
    let ?#approve(a) = r.decision else return #err(#InvalidRequest({ reason = "the application was not approved" }));
    #ok({ party; book = r.book; product = r.product; currency = r.currency; amount = a.amount; termDays = a.termDays; rateBps = a.rateBps })
  };

  public func planWithdraw(s : State, id : OT.ApplicationId, reason : Text, today : Nat) : Planned {
    let ?r = row(s, id) else return #err(#UnknownApplication({ application = id }));
    if (OT.terminal(r.stage)) return #err(wrongStage(id, r, "an open application"));
    if (Text.encodeUtf8(reason).size() > 256) return #err(#InvalidRequest({ reason = "a reason is at most 256 bytes" }));
    #ok(#withdrawn({ application = id; reason; day = today }))
  };

  /// An onboarding that names an application: the application is a prospect's (no party yet) and open.
  public func planOnboard(s : State, id : OT.ApplicationId) : Result.Result<Row, OT.OriginationError> {
    let ?r = row(s, id) else return #err(#UnknownApplication({ application = id }));
    if (r.party != null) return #err(#PartyMismatch({ application = id }));
    if (OT.terminal(r.stage)) return #err(wrongStage(id, r, "an open application"));
    #ok(r)
  };

  /// The offers that lapsed by `day`: those still offered whose validity ended before it.
  public func expiredOffers(s : State, day : Nat) : [OT.ApplicationId] {
    let out = List.empty<OT.ApplicationId>();
    let (lo, hi) = R.prefixRange(Nat8.toNat(OT.stageCode(#offered)), 1, 8);
    var cursor : ?Blob = null;
    label walk loop {
      let page = RI.range(s.byStage, lo, hi, cursor, MAX_PAGE);
      for ((k, _) in page.entries.vals()) {
        let id = R.getNat(Blob.toArray(k), 1, 8);
        switch (row(s, id)) {
          case (?r) { if (r.stage == #offered) { switch (r.offer) { case (?o) { if (o.expiresAt < day) List.add(out, id) }; case null {} } } };
          case null {};
        };
      };
      switch (page.cursor) { case null break walk; case (?c) cursor := ?c };
    };
    List.toArray(out)
  };

  /// The applications of a book with an offer standing, by id.
  public func offeredInBookIds(s : State, book : Text) : [OT.ApplicationId] {
    let out = List.empty<OT.ApplicationId>();
    let (lo, hi) = R.prefixRange(Nat8.toNat(OT.stageCode(#offered)), 1, 8);
    var cursor : ?Blob = null;
    label walk loop {
      let page = RI.range(s.byStage, lo, hi, cursor, MAX_PAGE);
      for ((k, _) in page.entries.vals()) {
        let id = R.getNat(Blob.toArray(k), 1, 8);
        switch (row(s, id)) { case (?r) { if (r.stage == #offered and Text.equal(r.book, book)) List.add(out, id) }; case null {} };
      };
      switch (page.cursor) { case null break walk; case (?c) cursor := ?c };
    };
    List.toArray(out)
  };
  public func offeredInBook(s : State, book : Text) : Nat { offeredInBookIds(s, book).size() };

  func request(r : Row) : OT.Request { { product = r.product; amount = r.amount; currency = r.currency; termDays = r.termDays; purpose = "" } };
  func conditionKey(id : OT.ApplicationId, c : Text) : Blob { R.key2(id, 8, textKey(c), 8) };

  // ─── the fold ─────────────────────────────────────────────────────────────

  func existing(s : State, id : OT.ApplicationId) : Row {
    let ?r = row(s, id) else Runtime.trap("OriginationCore: an act on an application the log never opened");
    r
  };

  public func apply(s : State, block : Nat, e : OT.OriginationEvent) {
    switch (e) {
      case (#policySet(p)) s.policy := ?p;
      case (#affordabilityModelSet(m)) s.affordability := ?m;
      case (#scorecardSet(c)) s.scorecard := ?c;
      case (#passkeyRegistered(x)) {
        ignore RI.put(s.passkeys, R.key2(x.party, 8, hashKey(x.credentialId), 8), x.publicKeySpki);
        s.passkeyCount += 1;
      };
      case (#applicationOpened(x)) {
        let r : Row = {
          stage = #capture; party = x.party; book = x.book; product = x.request.product; currency = x.request.currency; amount = x.request.amount;
          termDays = x.request.termDays; openedDay = x.day; openedBlock = block; lastBlock = block; facts = null; verdict = null; bureauRequested = false;
          bureau = null; score = null; decision = null; offer = null; documents = 0; agreementRecorded = false; conditions = 0; conditionsMet = 0; account = null;
        };
        putRow(s, block, r, block);
        s.applications += 1;
      };
      case (#dataRecorded(x)) {
        let r = existing(s, x.application);
        putRow(s, x.application, { r with stage = #capture; facts = ?x.facts; verdict = null; score = null }, block);
      };
      case (#affordabilityAssessed(x)) {
        let r = existing(s, x.application);
        putRow(s, x.application, { r with stage = #assessed; verdict = ?verdictKind(x.verdict) }, block);
      };
      case (#bureauRequested(x)) {
        let r = existing(s, x.application);
        putRow(s, x.application, { r with bureauRequested = true }, block);
      };
      case (#bureauRecorded(x)) {
        let r = existing(s, x.application);
        putRow(s, x.application, { r with bureau = ?{ score = x.report.score; flags = x.report.flags.size() } }, block);
      };
      case (#scored(x)) {
        let r = existing(s, x.application);
        putRow(s, x.application, { r with stage = #scored; score = ?{ points = x.points; band = x.band } }, block);
      };
      case (#underwritten(x)) {
        let r = existing(s, x.application);
        switch (x.decision) {
          case (#approve(a)) {
            for (c in a.conditions.vals()) { ignore RI.put(s.conditions, conditionKey(x.application, c), Blob.fromArray([0])) };
            putRow(s, x.application, { r with stage = #underwritten; decision = ?#approve({ amount = a.amount; termDays = a.termDays; rateBps = a.rateBps }); conditions = a.conditions.size(); conditionsMet = 0 }, block);
          };
          case (#decline(_)) { putRow(s, x.application, { r with stage = #declined; decision = ?#decline }, block); s.declined += 1 };
          case (#refer(_)) putRow(s, x.application, { r with stage = #scored; decision = ?#refer }, block);
        };
      };
      case (#offerIssued(x)) {
        let r = existing(s, x.application);
        putRow(s, x.application, { r with stage = #offered; offer = ?{ hash = x.offerHash; expiresAt = x.expiresAt } }, block);
      };
      case (#offerAccepted(x)) {
        let r = existing(s, x.application);
        putRow(s, x.application, { r with stage = #accepted }, block);
      };
      case (#offerDeclined(x)) {
        let r = existing(s, x.application);
        putRow(s, x.application, { r with stage = #declined }, block);
        s.declined += 1;
      };
      case (#offerExpired(x)) {
        let r = existing(s, x.application);
        putRow(s, x.application, { r with stage = #expired }, block);
        s.expired += 1;
      };
      case (#documentRecorded(x)) {
        let r = existing(s, x.application);
        putRow(s, x.application, { r with documents = r.documents + 1; agreementRecorded = r.agreementRecorded or x.kind == #facilityAgreement }, block);
      };
      case (#conditionsMet(x)) {
        let r = existing(s, x.application);
        for (c in x.conditions.vals()) { ignore RI.put(s.conditions, conditionKey(x.application, c), Blob.fromArray([1])) };
        putRow(s, x.application, { r with conditionsMet = r.conditions - x.outstanding }, block);
      };
      case (#documentationComplete(x)) {
        let r = existing(s, x.application);
        putRow(s, x.application, { r with stage = #documented }, block);
      };
      case (#prospectOnboarded(x)) {
        let r = existing(s, x.application);
        putRow(s, x.application, { r with party = ?x.party }, block);
      };
      case (#fulfilled(x)) {
        let r = existing(s, x.application);
        putRow(s, x.application, { r with stage = #fulfilled; account = ?x.account }, block);
        s.fulfilled += 1;
      };
      case (#withdrawn(x)) {
        let r = existing(s, x.application);
        putRow(s, x.application, { r with stage = #withdrawn }, block);
        s.withdrawn += 1;
      };
    };
  };

  // ─── reads ────────────────────────────────────────────────────────────────

  public func view(s : State, id : OT.ApplicationId) : ?OT.ApplicationView {
    let ?r = row(s, id) else return null;
    ?{
      id; party = r.party; book = r.book; stage = r.stage; product = r.product; currency = r.currency; amount = r.amount; termDays = r.termDays;
      facts = r.facts; verdict = r.verdict; bureauScore = switch (r.bureau) { case (?b) ?b.score; case null null };
      points = switch (r.score) { case (?x) ?x.points; case null null }; band = switch (r.score) { case (?x) ?x.band; case null null };
      approved = switch (r.decision) { case (?#approve(a)) ?a; case (_) null };
      offerHash = switch (r.offer) { case (?o) ?o.hash; case null null }; offerExpiresAt = switch (r.offer) { case (?o) ?o.expiresAt; case null null };
      documents = r.documents; conditions = r.conditions; conditionsMet = r.conditionsMet; account = r.account;
      openedDay = r.openedDay; openedBlock = r.openedBlock; lastBlock = r.lastBlock;
    }
  };

  public type Page = { entries : [OT.ApplicationView]; cursor : ?Blob };

  public func listByStage(s : State, stage : OT.Stage, cursor : ?Blob, limit : Nat) : Page {
    let (lo, hi) = R.prefixRange(Nat8.toNat(OT.stageCode(stage)), 1, 8);
    let page = RI.range(s.byStage, lo, hi, cursor, Nat.min(limit, MAX_PAGE));
    let out = List.empty<OT.ApplicationView>();
    for ((k, _) in page.entries.vals()) {
      let id = R.getNat(Blob.toArray(k), 1, 8);
      switch (view(s, id)) { case (?v) { if (v.stage == stage) List.add(out, v) }; case null {} };
    };
    { entries = List.toArray(out); cursor = page.cursor }
  };

  public func listByParty(s : State, party : PT.PartyId, cursor : ?Blob, limit : Nat) : Page {
    let (lo, hi) = R.prefixRange(party, 8, 8);
    let page = RI.range(s.byParty, lo, hi, cursor, Nat.min(limit, MAX_PAGE));
    let out = List.empty<OT.ApplicationView>();
    for ((k, _) in page.entries.vals()) {
      let id = R.getNat(Blob.toArray(k), 8, 8);
      switch (view(s, id)) { case (?v) List.add(out, v); case null {} };
    };
    { entries = List.toArray(out); cursor = page.cursor }
  };

  public func applicationOfAccount(s : State, account : Nat) : ?OT.ApplicationId {
    switch (RI.get(s.byAccount, R.key(account, 8))) { case (?v) ?R.getNat(Blob.toArray(v), 0, 8); case null null }
  };

  /// The conditions of an approval with whether each is met — read from the index under the approval's
  /// own list, so the names are the block's.
  public func conditionsOf(s : State, id : OT.ApplicationId, names : [Text]) : [(Text, Bool)] {
    Array.map<Text, (Text, Bool)>(names, func(c) { (c, switch (RI.get(s.conditions, conditionKey(id, c))) { case (?v) Blob.toArray(v)[0] == 1; case null false }) })
  };

  public func counts(s : State) : { applications : Nat; fulfilled : Nat; declined : Nat; withdrawn : Nat; expired : Nat; passkeys : Nat } {
    { applications = s.applications; fulfilled = s.fulfilled; declined = s.declined; withdrawn = s.withdrawn; expired = s.expired; passkeys = s.passkeyCount }
  };

  /// Applications per stage, walked — the pipeline figure, bounded by the rows.
  public func stageDistribution(s : State) : [(Text, Nat)] {
    let counts = VarArray.repeat<Nat>(0, OT.STAGES);
    let (lo, hi) = R.fullRange(8);
    var cursor : ?Blob = null;
    label walk loop {
      let page = RI.range(s.rows, lo, hi, cursor, MAX_PAGE);
      for ((_, v) in page.entries.vals()) { let r = decodeRow(v); counts[Nat8.toNat(OT.stageCode(r.stage))] += 1 };
      switch (page.cursor) { case null break walk; case (?c) cursor := ?c };
    };
    Array.tabulate<(Text, Nat)>(OT.STAGES, func(i) { let ?st = OT.stageOfCode(Nat8.fromNat(i)) else Runtime.trap("stage"); (OT.stageText(st), counts[i]) })
  };

  // ─── fingerprint ──────────────────────────────────────────────────────────

  func fingerprintRows(w : C.Writer, idx : RI.State, width : Nat) {
    let (lo, hi) = R.fullRange(width);
    var cursor : ?Blob = null;
    label walk loop {
      let page = RI.range(idx, lo, hi, cursor, MAX_PAGE);
      for ((k, v) in page.entries.vals()) { w.blobRaw(k); w.blobRaw(v) };
      switch (page.cursor) { case null break walk; case (?c) cursor := ?c };
    };
  };

  public func fingerprintInto(w : C.Writer, s : State) {
    switch (s.policy) { case null w.byte(0); case (?p) { w.byte(1); OC.writePolicy(w, p) } };
    switch (s.affordability) { case null w.byte(0); case (?m) { w.byte(1); OC.writeAffordabilityModel(w, m) } };
    switch (s.scorecard) { case null w.byte(0); case (?c) { w.byte(1); OC.writeScorecard(w, c) } };
    w.nat(s.applications); w.nat(s.fulfilled); w.nat(s.declined); w.nat(s.withdrawn); w.nat(s.expired); w.nat(s.passkeyCount);
    fingerprintRows(w, s.rows, 8);
    fingerprintRows(w, s.byStage, 9);
    fingerprintRows(w, s.byParty, 16);
    fingerprintRows(w, s.byAccount, 8);
    fingerprintRows(w, s.conditions, 16);
    fingerprintRows(w, s.passkeys, 16);
  };
}
