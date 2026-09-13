/// TradeMessages.mo — the messages a trade instrument exchanges (trade finance), rendered from the recorded state and read
/// back into terms: SWIFT FIN MT of the 7-series (700 issue, 707 amendment, 750 advice of discrepancy, 752
/// authorisation to pay, 754 advice of payment / acceptance / negotiation, 760 undertaking, 765 demand, 767
/// amendment of an undertaking, 768 acknowledgement, 769 reduction or release, 799 free format) and the ISO 20022
/// trade-services undertakings family (tsrv.001 issuance, tsrv.005 amendment, tsrv.013 demand, tsrv.016 demand
/// refusal, tsrv.012 termination). An outgoing message is a function of the block; an incoming MT 700 or MT 760 is
/// parsed into the terms the advising bank records, the message itself kept by its hash.

import Array "mo:core/Array";
import Char "mo:core/Char";
import Iter "mo:core/Iter";
import List "mo:core/List";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Nat32 "mo:core/Nat32";
import Nat64 "mo:core/Nat64";
import Text "mo:core/Text";

import CivilDate "mo:journal/CivilDate";

import TrT "TradeTypes";
import Xml "Xml";

module {

  // ─── text helpers ─────────────────────────────────────────────────────────

  func pad2(n : Nat) : Text { if (n < 10) "0" # Nat.toText(n) else Nat.toText(n) };
  /// YYMMDD, the FIN date.
  public func finDate(day : Nat) : Text { let (y, m, d) = CivilDate.toCivil(day); pad2(y % 100) # pad2(m) # pad2(d) };
  public func parseFinDate(t : Text) : ?Nat {
    let cs = Text.toArray(t);
    if (cs.size() < 6) return null;
    func dig(c : Char) : ?Nat { if (c >= '0' and c <= '9') ?(Nat32.toNat(Char.toNat32(c)) - 48) else null };
    let v : [var Nat] = Array.toVarArray<Nat>(Array.repeat<Nat>(0, 6));
    var i = 0;
    while (i < 6) { let ?d = dig(cs[i]) else return null; v[i] := d; i += 1 };
    CivilDate.fromCivil(2000 + v[0] * 10 + v[1], v[2] * 10 + v[3], v[4] * 10 + v[5])
  };
  /// A FIN amount: the integer part, a comma, the minor units.
  public func finAmount(minor : Nat, minorUnits : Nat8) : Text {
    let mu = Nat8.toNat(minorUnits);
    if (mu == 0) return Nat.toText(minor) # ",";
    var scale = 1; var i = 0; while (i < mu) { scale *= 10; i += 1 };
    var frac = Nat.toText(minor % scale);
    while (frac.size() < mu) frac := "0" # frac;
    Nat.toText(minor / scale) # "," # frac
  };
  public func parseFinAmount(t : Text, minorUnits : Nat8) : ?Nat {
    let mu = Nat8.toNat(minorUnits);
    var whole = 0; var frac = 0; var fracDigits = 0; var inFrac = false; var any = false;
    for (c in t.chars()) {
      if (c == ',') { if (inFrac) return null; inFrac := true }
      else if (c >= '0' and c <= '9') { any := true; let d = Nat32.toNat(Char.toNat32(c)) - 48; if (inFrac) { if (fracDigits < mu) { frac := frac * 10 + d; fracDigits += 1 } else if (d != 0) return null } else whole := whole * 10 + d }
      else return null;
    };
    if (not any) return null;
    while (fracDigits < mu) { frac *= 10; fracDigits += 1 };
    var scale = 1; var i = 0; while (i < mu) { scale *= 10; i += 1 };
    ?(whole * scale + frac)
  };
  /// The 12-character logical terminal address of a BIC: eight characters, the terminal 'X', the branch or XXX.
  public func terminal(bic : Text) : Text {
    let cs = Text.toArray(bic);
    if (cs.size() < 8) return bic;
    let eight = Text.fromArray(Array.sliceToArray<Char>(cs, 0, 8));
    let branch = if (cs.size() >= 11) Text.fromArray(Array.sliceToArray<Char>(cs, 8, 11)) else "XXX";
    eight # "X" # branch
  };
  func lines(xs : [Text]) : Text { var out = ""; var first = true; for (x in xs.vals()) { out := if (first) x else out # "\n" # x; first := false }; out };
  func lines2(sep : Text, xs : [Text]) : Text { var out = ""; var first = true; for (x in xs.vals()) { out := if (first) x else out # sep # x; first := false }; out };
  func clip(t : Text, n : Nat) : Text { if (t.size() <= n) t else Text.fromArray(Array.sliceToArray<Char>(Text.toArray(t), 0, n)) };
  func upper(t : Text) : Text { Text.toUpper(t) };
  func cpLines(c : TrT.Counterparty, ownName : Text) : Text {
    switch (c) { case (#party(p)) ownName # " " # Nat.toText(p.party) # "\nACCOUNT " # Nat.toText(p.account); case (#external(e)) { (if (e.account != "") "/" # e.account # "\n" else "") # clip(upper(e.name), 35) # "\n" # e.bic } }
  };
  func documentLine(d : TrT.RequiredDocument) : Text {
    let name = switch (d.kind) {
      case (#invoice) "SIGNED COMMERCIAL INVOICE"; case (#transport) "FULL SET CLEAN ON BOARD TRANSPORT DOCUMENT"; case (#insurance) "INSURANCE POLICY OR CERTIFICATE";
      case (#origin) "CERTIFICATE OF ORIGIN"; case (#packing) "PACKING LIST"; case (#inspection) "INSPECTION CERTIFICATE"; case (#draft) "DRAFT AT SIGHT"; case (#other(t)) upper(t);
    };
    "+" # name # " IN " # Nat.toText(d.copies) # (if (d.copies == 1) " ORIGINAL" else " ORIGINALS")
  };
  public func documentKindOfLine(line : Text) : TrT.DocumentKind {
    let u = upper(line);
    if (Text.contains(u, #text "INVOICE")) #invoice
    else if (Text.contains(u, #text "TRANSPORT") or Text.contains(u, #text "BILL OF LADING") or Text.contains(u, #text "WAYBILL")) #transport
    else if (Text.contains(u, #text "INSURANCE")) #insurance
    else if (Text.contains(u, #text "PACKING")) #packing
    else if (Text.contains(u, #text "OF ORIGIN")) #origin   // "IN 3 ORIGINALS" is not a certificate of origin
    else if (Text.contains(u, #text "INSPECTION")) #inspection
    else if (Text.contains(u, #text "DRAFT")) #draft
    else #other(Text.trim(Text.trimStart(line, #char '+'), #char ' '))
  };
  func copiesOfLine(line : Text) : Nat {
    // "... IN 3 ORIGINALS" — the number before ORIGINAL / COPIES
    let words = Iter.toArray(Text.split(upper(line), #char ' '));
    var i = 0;
    while (i + 1 < words.size()) {
      if (words[i] == "IN") { switch (Nat.fromText(words[i + 1])) { case (?n) return n; case null {} } };
      i += 1;
    };
    1
  };

  /// A FIN message: blocks 1, 2 and 4.
  public func fin(sender : Text, receiver : Text, mt : Nat, fields : [Text]) : Text {
    "{1:F01" # terminal(sender) # "0000000000}{2:I" # Nat.toText(mt) # terminal(receiver) # "N}{4:\n" # lines(fields) # "\n-}"
  };

  // ─── the documentary credit, MT 700 / 707 / 750 / 752 / 754 ─────────────

  public type LcFacts = { lc : TrT.LetterOfCredit; amount : Nat; currency : Text; minorUnits : Nat8; expiry : Nat; placeOfExpiry : Text; issuedDay : Nat; bankName : Text };

  public func mt700(bic : Text, f : LcFacts) : Text {
    let t = f.lc.terms;
    let fields = List.empty<Text>();
    List.add(fields, ":27:1/1");
    List.add(fields, ":40A:IRREVOCABLE");
    List.add(fields, ":20:" # clip(f.lc.reference, 16));
    List.add(fields, ":31C:" # finDate(f.issuedDay));
    List.add(fields, ":40E:UCP LATEST VERSION");
    List.add(fields, ":31D:" # finDate(f.expiry) # clip(upper(f.placeOfExpiry), 29));
    List.add(fields, ":50:" # cpLines(f.lc.applicant, "CUSTOMER"));
    List.add(fields, ":59:" # cpLines(f.lc.beneficiary, "CUSTOMER"));
    List.add(fields, ":32B:" # f.currency # finAmount(f.amount, f.minorUnits));
    switch (f.lc.tolerance) { case (?bps) List.add(fields, ":39A:" # Nat.toText(bps / 100) # "/" # Nat.toText(bps / 100)); case null {} };
    let by = switch (t.availableBy) { case (#sight) "BY PAYMENT"; case (#deferred(_)) "BY DEF PAYMENT"; case (#acceptance(_)) "BY ACCEPTANCE"; case (#negotiation) "BY NEGOTIATION" };
    List.add(fields, ":41A:" # (if (f.lc.counterpartyBank != "") f.lc.counterpartyBank else bic) # "\n" # by);
    switch (t.availableBy) {
      case (#deferred(d)) List.add(fields, ":42P:" # Nat.toText(d.days) # " DAYS AFTER PRESENTATION");
      case (#acceptance(d)) { List.add(fields, ":42C:AT " # Nat.toText(d.days) # " DAYS AFTER PRESENTATION"); List.add(fields, ":42A:" # bic) };
      case (_) {};
    };
    List.add(fields, ":43P:" # (if (t.partialShipments) "ALLOWED" else "NOT ALLOWED"));
    List.add(fields, ":43T:" # (if (t.transhipment) "ALLOWED" else "NOT ALLOWED"));
    if (t.portOfLoading != "") List.add(fields, ":44E:" # clip(upper(t.portOfLoading), 65));
    if (t.portOfDischarge != "") List.add(fields, ":44F:" # clip(upper(t.portOfDischarge), 65));
    switch (t.latestShipment) { case (?d) List.add(fields, ":44C:" # finDate(d)); case null {} };
    let goods = clip(upper(t.goods), 60) # (switch (t.incoterm) { case (?i) "\nINCOTERMS 2020: " # i; case null "" });
    List.add(fields, ":45A:" # goods);
    List.add(fields, ":46A:" # lines(Array.map<TrT.RequiredDocument, Text>(t.documents, documentLine)));
    List.add(fields, ":47A:ALL DOCUMENTS MUST BEAR THE CREDIT NUMBER " # clip(f.lc.reference, 16));
    List.add(fields, ":48:" # Nat.toText(t.presentationDays) # "/DAYS FROM SHIPMENT DATE");
    List.add(fields, ":49:" # (if (f.lc.role == #confirming) "CONFIRM" else "WITHOUT"));
    fin(bic, if (f.lc.counterpartyBank != "") f.lc.counterpartyBank else bic, 700, List.toArray(fields))
  };

  public func mt707(bic : Text, receiver : Text, reference : Text, issuedDay : Nat, number : Nat, day : Nat, currency : Text, minorUnits : Nat8, oldAmount : Nat, a : TrT.Amendment) : Text {
    let fields = List.empty<Text>();
    List.add(fields, ":27:1/1");
    List.add(fields, ":20:" # clip(reference, 16));
    List.add(fields, ":21:NONREF");
    List.add(fields, ":23:" # clip(reference, 16));
    List.add(fields, ":31C:" # finDate(issuedDay));
    List.add(fields, ":26E:" # Nat.toText(number));
    List.add(fields, ":30:" # finDate(day));
    List.add(fields, ":22A:ISSU");
    switch (a.expiry) { case (?e) List.add(fields, ":31D:" # finDate(e) # "AS BEFORE"); case null {} };
    switch (a.amount) {
      case (?n) { if (n > oldAmount) List.add(fields, ":32B:" # currency # finAmount(n - oldAmount, minorUnits)) else if (n < oldAmount) List.add(fields, ":33B:" # currency # finAmount(oldAmount - n, minorUnits)) };
      case null {};
    };
    switch (a.latestShipment) { case (?d) List.add(fields, ":44C:" # finDate(d)); case null {} };
    if (a.other != "") List.add(fields, ":79Z:" # clip(upper(a.other), 1750));
    fin(bic, receiver, 707, List.toArray(fields))
  };

  /// MT 750: the advice of discrepancy — each discrepancy on its own line of field 77J (art. 16(c)(ii)).
  public func mt750(bic : Text, receiver : Text, reference : Text, currency : Text, minorUnits : Nat8, amount : Nat, discrepancies : [Text], disposal : TrT.Disposal) : Text {
    let disp = switch (disposal) { case (#held) "HOLD"; case (#returned) "RETURN"; case (#heldPendingWaiver) "HOLD"; case (#actingOnInstructions) "PREVINST" };
    fin(bic, receiver, 750, [":20:" # clip(reference, 16), ":21:" # clip(reference, 16), ":32B:" # currency # finAmount(amount, minorUnits),
                             ":77J:" # lines(Array.map<Text, Text>(discrepancies, func(d) { clip(upper(d), 50) })), ":77B:/" # disp # "/"])
  };
  public func mt752(bic : Text, receiver : Text, reference : Text, day : Nat, currency : Text, minorUnits : Nat8, amount : Nat) : Text {
    fin(bic, receiver, 752, [":20:" # clip(reference, 16), ":21:" # clip(reference, 16), ":23:" # "WAIVED", ":30:" # finDate(day), ":32B:" # currency # finAmount(amount, minorUnits)])
  };
  public func mt754(bic : Text, receiver : Text, reference : Text, currency : Text, minorUnits : Nat8, amount : Nat, honour : TrT.Honour) : Text {
    let how = switch (honour) { case (#sight) "PAID AT SIGHT"; case (#deferred(d)) "DEFERRED PAYMENT DUE " # finDate(d.due); case (#acceptance(d)) "ACCEPTED MATURITY " # finDate(d.due); case (#negotiation(d)) "NEGOTIATED REIMBURSEMENT " # finDate(d.due) };
    fin(bic, receiver, 754, [":20:" # clip(reference, 16), ":21:" # clip(reference, 16), ":32A:" # finDate(switch (honour) { case (#sight) 0; case (#deferred(d) or #acceptance(d) or #negotiation(d)) d.due }) # currency # finAmount(amount, minorUnits), ":72Z:" # how])
  };

  // ─── undertakings, MT 760 / 767 / 765 / 768 / 769 ────────────────────────

  public type GuaranteeFacts = { g : TrT.Guarantee; amount : Nat; currency : Text; minorUnits : Nat8; expiry : Nat; issuedDay : Nat; wordingText : Text };

  public func mt760(bic : Text, f : GuaranteeFacts) : Text {
    let g = f.g;
    let receiver = if (g.counterpartyBank != "") g.counterpartyBank else (switch (g.beneficiary) { case (#external(e)) e.bic; case (#party(_)) bic });
    let form = switch (g.kind) { case (#standby) "STBY"; case (#demandGuarantee or #counterGuarantee) "DGAR" };
    let rules = switch (g.rules) { case (#ISP98) "ISPR"; case (#URDG758) "URDG"; case (_) "NONE" };
    let fields = List.empty<Text>();
    List.add(fields, ":15A:");
    List.add(fields, ":27:1/1");
    List.add(fields, ":22A:" # (if (g.kind == #counterGuarantee) "ISCO" else "ISSU"));
    List.add(fields, ":15B:");
    List.add(fields, ":20:" # clip(g.reference, 16));
    List.add(fields, ":30:" # finDate(f.issuedDay));
    List.add(fields, ":22D:" # form);
    List.add(fields, ":40C:" # rules);
    List.add(fields, ":23B:FIXD");
    List.add(fields, ":31E:" # finDate(f.expiry));
    List.add(fields, ":50:" # cpLines(#party({ party = g.principal; account = g.principalAccount }), "CUSTOMER"));
    List.add(fields, ":52A:" # bic);
    List.add(fields, ":59:" # cpLines(g.beneficiary, "CUSTOMER"));
    List.add(fields, ":32B:" # f.currency # finAmount(f.amount, f.minorUnits));
    if (g.reductions.size() > 0) List.add(fields, ":39D:" # lines(Array.map<(Nat, Nat), Text>(g.reductions, func((d, a)) { "ON " # finDate(d) # " TO " # finAmount(a, f.minorUnits) })));
    List.add(fields, ":45C:" # clip(f.wordingText, 6500) # (if (g.statementRequired) "\nA DEMAND MUST BE SUPPORTED BY THE STATEMENT OF ARTICLE 15 URDG 758" else "\nNO SUPPORTING STATEMENT IS REQUIRED"));
    List.add(fields, ":24E:MAIL");
    fin(bic, receiver, 760, List.toArray(fields))
  };
  public func mt767(bic : Text, receiver : Text, reference : Text, issuedDay : Nat, number : Nat, day : Nat, currency : Text, minorUnits : Nat8, oldAmount : Nat, a : TrT.Amendment) : Text {
    let fields = List.empty<Text>();
    List.add(fields, ":15A:"); List.add(fields, ":27:1/1"); List.add(fields, ":21:NONREF"); List.add(fields, ":22A:ISSU");
    List.add(fields, ":15B:"); List.add(fields, ":20:" # clip(reference, 16)); List.add(fields, ":26E:" # Nat.toText(number)); List.add(fields, ":30:" # finDate(day)); List.add(fields, ":52A:" # bic);
    List.add(fields, ":31C:" # finDate(issuedDay));
    switch (a.amount) {
      case (?n) { if (n > oldAmount) List.add(fields, ":32B:" # currency # finAmount(n - oldAmount, minorUnits)) else if (n < oldAmount) List.add(fields, ":33B:" # currency # finAmount(oldAmount - n, minorUnits)) };
      case null {};
    };
    switch (a.expiry) { case (?e) List.add(fields, ":31E:" # finDate(e)); case null {} };
    if (a.other != "") List.add(fields, ":77U:" # clip(upper(a.other), 6500));
    fin(bic, receiver, 767, List.toArray(fields))
  };
  public func mt765(bic : Text, receiver : Text, reference : Text, day : Nat, currency : Text, minorUnits : Nat8, amount : Nat, supportingStatement : Bool) : Text {
    fin(bic, receiver, 765, [":20:" # clip(reference, 16), ":21:" # clip(reference, 16), ":31L:" # finDate(day), ":32B:" # currency # finAmount(amount, minorUnits),
                             ":77P:" # (if (supportingStatement) "THE BENEFICIARY STATES THAT THE APPLICANT IS IN BREACH OF ITS OBLIGATIONS UNDER THE UNDERLYING RELATIONSHIP" else "DEMAND WITHOUT SUPPORTING STATEMENT")])
  };
  public func mt768(bic : Text, receiver : Text, reference : Text, day : Nat) : Text {
    fin(bic, receiver, 768, [":20:" # clip(reference, 16), ":21:" # clip(reference, 16), ":30:" # finDate(day)])
  };
  public func mt769(bic : Text, receiver : Text, reference : Text, day : Nat, currency : Text, minorUnits : Nat8, reducedBy : Nat, outstanding : Nat) : Text {
    fin(bic, receiver, 769, [":20:" # clip(reference, 16), ":21:" # clip(reference, 16), ":30:" # finDate(day), ":33B:" # currency # finAmount(reducedBy, minorUnits), ":34B:" # currency # finAmount(outstanding, minorUnits)])
  };
  public func mt799(bic : Text, receiver : Text, reference : Text, narrative : Text) : Text {
    fin(bic, receiver, 799, [":20:" # clip(reference, 16), ":21:" # clip(reference, 16), ":79:" # clip(upper(narrative), 1750)])
  };

  // ─── parsing FIN block 4 ──────────────────────────────────────────────────

  /// The tagged fields of block 4 in order; a field's value keeps its continuation lines.
  public func fields(text : Text) : ?{ sender : Text; receiver : Text; mt : Nat; fields : [(Text, Text)] } {
    let ?b1 = after(text, "{1:") else return null;
    let sender = clip(Text.fromArray(Array.sliceToArray<Char>(Text.toArray(b1), 3, 15)), 12);
    let ?b2 = after(text, "{2:") else return null;
    let b2cs = Text.toArray(b2);
    if (b2cs.size() < 16) return null;
    let ?mt = Nat.fromText(Text.fromArray(Array.sliceToArray<Char>(b2cs, 1, 4))) else return null;
    let receiver = Text.fromArray(Array.sliceToArray<Char>(b2cs, 4, 16));
    let ?b4 = after(text, "{4:") else return null;
    let body = switch (Text.split(b4, #text "\n-}").next()) { case (?x) x; case null b4 };
    let out = List.empty<(Text, Text)>();
    var tag = ""; var value = "";
    for (rawLine in Text.split(body, #char '\n')) {
      let line = Text.trimEnd(rawLine, #char '\r');
      if (Text.startsWith(line, #char ':')) {
        if (tag != "") List.add(out, (tag, value));
        let rest = Text.trimStart(line, #char ':');
        let parts = Iter.toArray(Text.split(rest, #char ':'));
        if (parts.size() < 2) return null;
        tag := parts[0];
        value := lines2(":", Array.sliceToArray<Text>(parts, 1, parts.size()));
      } else if (tag != "") {
        if (line != "") value := value # "\n" # line;
      };
    };
    if (tag != "") List.add(out, (tag, value));
    func bic8(t : Text) : Text { let cs = Text.toArray(t); if (cs.size() >= 12) Text.fromArray(Array.sliceToArray<Char>(cs, 0, 8)) # (if (Text.fromArray(Array.sliceToArray<Char>(cs, 9, 12)) == "XXX") "" else Text.fromArray(Array.sliceToArray<Char>(cs, 9, 12))) else t };
    ?{ sender = bic8(sender); receiver = bic8(receiver); mt; fields = List.toArray(out) }
  };
  func after(text : Text, marker : Text) : ?Text {
    let parts = Iter.toArray(Text.split(text, #text marker));
    if (parts.size() < 2) null else ?parts[1]
  };
  public func field(fs : [(Text, Text)], tag : Text) : ?Text { for ((t, v) in fs.vals()) { if (t == tag) return ?v }; null };
  func firstLine(t : Text) : Text { switch (Text.split(t, #char '\n').next()) { case (?x) x; case null t } };
  func restLines(t : Text) : [Text] { let xs = Iter.toArray(Text.split(t, #char '\n')); if (xs.size() <= 1) [] else Array.sliceToArray<Text>(xs, 1, xs.size()) };

  public type ParsedLc = {
    reference : Text; issuedDay : Nat; expiry : Nat; placeOfExpiry : Text; applicant : TrT.Counterparty; beneficiaryName : Text; beneficiaryAccount : Text;
    currency : Text; amount : Nat; tolerance : ?Nat; terms : TrT.DocumentaryTerms; confirmationAsked : Bool; issuingBank : Text;
  };

  /// An MT 700 read into the terms of a credit; the documents called for become required documents of the kinds
  /// their lines name, with the checks the reading bank's own checklist assigns to each kind.
  public func parseMt700(text : Text, minorUnitsOf : Text -> ?Nat8, checklist : [(TrT.DocumentKind, [Text])]) : Result<ParsedLc> {
    let ?m = fields(text) else return #err("not a FIN message");
    if (m.mt != 700) return #err("not an MT 700: MT " # Nat.toText(m.mt));
    let f = m.fields;
    let ?reference = field(f, "20") else return #err("field 20 missing");
    let ?issued = field(f, "31C") else return #err("field 31C missing");
    let ?issuedDay = parseFinDate(issued) else return #err("field 31C is not a date");
    let ?d31 = field(f, "31D") else return #err("field 31D missing");
    let ?expiry = parseFinDate(d31) else return #err("field 31D is not a date");
    let placeOfExpiry = Text.trim(Text.fromArray(Array.sliceToArray<Char>(Text.toArray(firstLine(d31)), Nat.min(6, firstLine(d31).size()), firstLine(d31).size())), #char ' ');
    let ?a32 = field(f, "32B") else return #err("field 32B missing");
    let cs32 = Text.toArray(a32);
    if (cs32.size() < 4) return #err("field 32B is short");
    let currency = Text.fromArray(Array.sliceToArray<Char>(cs32, 0, 3));
    let ?mu = minorUnitsOf(currency) else return #err("currency " # currency # " is not registered");
    let ?amount = parseFinAmount(Text.fromArray(Array.sliceToArray<Char>(cs32, 3, cs32.size())), mu) else return #err("field 32B amount unreadable");
    let tolerance : ?Nat = switch (field(f, "39A")) { case (?t) { switch (Nat.fromText(firstLine(Text.replace(t, #char '/', "\n")))) { case (?p) ?(p * 100); case null null } }; case null null };
    let ?f50 = field(f, "50") else return #err("field 50 missing");
    let ?f59 = field(f, "59") else return #err("field 59 missing");
    let l59 = Iter.toArray(Text.split(f59, #char '\n'));
    let (beneficiaryAccount, beneficiaryName) = if (l59.size() > 1 and Text.startsWith(l59[0], #char '/')) (Text.trimStart(l59[0], #char '/'), l59[1]) else ("", l59[0]);
    let applicantLines = Iter.toArray(Text.split(f50, #char '\n'));
    let applicant : TrT.Counterparty = #external({ name = applicantLines[0]; bic = m.sender; account = if (applicantLines.size() > 1) applicantLines[1] else "" });
    let avail41 = switch (field(f, "41A")) { case (?t) t; case null { switch (field(f, "41D")) { case (?t) t; case null "" } } };
    let by = upper(lines(restLines(avail41)));
    let days42 : Nat = switch (field(f, "42P")) { case (?t) { switch (Nat.fromText(firstLine(Text.replace(t, #char ' ', "\n")))) { case (?n) n; case null 0 } }; case null { switch (field(f, "42C")) { case (?t) { var n = 0; for (w in Text.split(upper(t), #char ' ')) { switch (Nat.fromText(w)) { case (?k) { if (n == 0) n := k }; case null {} } }; n }; case null 0 } } };
    let availableBy : TrT.Availability = if (Text.contains(by, #text "DEF")) #deferred({ days = days42 }) else if (Text.contains(by, #text "ACCEPT")) #acceptance({ days = days42 }) else if (Text.contains(by, #text "NEGOT")) #negotiation else #sight;
    let partial = switch (field(f, "43P")) { case (?t) not Text.contains(upper(t), #text "NOT"); case null false };
    let tranship = switch (field(f, "43T")) { case (?t) not Text.contains(upper(t), #text "NOT"); case null false };
    let portOfLoading = switch (field(f, "44E")) { case (?t) firstLine(t); case null "" };
    let portOfDischarge = switch (field(f, "44F")) { case (?t) firstLine(t); case null "" };
    let latestShipment : ?Nat = switch (field(f, "44C")) { case (?t) parseFinDate(t); case null null };
    let f45 = switch (field(f, "45A")) { case (?t) t; case null "" };
    var incoterm : ?Text = null;
    var goods = "";
    for (l in Text.split(f45, #char '\n')) {
      if (Text.startsWith(upper(l), #text "INCOTERMS 2020:")) incoterm := ?Text.trim(Text.fromArray(Array.sliceToArray<Char>(Text.toArray(l), 15, l.size())), #char ' ')
      else goods := (if (goods == "") l else goods # "\n" # l);
    };
    let ?f46 = field(f, "46A") else return #err("field 46A missing");
    let docs = List.empty<TrT.RequiredDocument>();
    for (l in Text.split(f46, #char '\n')) {
      if (Text.trim(l, #char ' ') == "") continue;
      let kind = documentKindOfLine(l);
      var checks : [Text] = [];
      for ((k, cs) in checklist.vals()) { if (k == kind) checks := cs };
      List.add(docs, { kind; copies = copiesOfLine(l); checks });
    };
    let presentationDays = switch (field(f, "48")) { case (?t) { switch (Nat.fromText(firstLine(Text.replace(t, #char '/', "\n")))) { case (?n) n; case null 21 } }; case null 21 };
    let confirmationAsked = switch (field(f, "49")) { case (?t) Text.contains(upper(t), #text "CONFIRM") and not Text.contains(upper(t), #text "WITHOUT"); case null false };
    #ok({
      reference; issuedDay; expiry; placeOfExpiry; applicant; beneficiaryName; beneficiaryAccount; currency; amount; tolerance;
      terms = { documents = List.toArray(docs); latestShipment; presentationDays; partialShipments = partial; transhipment = tranship; incoterm; availableBy; portOfLoading; portOfDischarge; goods };
      confirmationAsked; issuingBank = m.sender;
    })
  };

  public type ParsedGuarantee = { reference : Text; issuedDay : Nat; expiry : Nat; kind : TrT.GuaranteeKind; rules : TrT.Rules; currency : Text; amount : Nat; applicantName : Text; beneficiaryName : Text; beneficiaryAccount : Text; wordingText : Text; statementRequired : Bool; issuingBank : Text };
  public func parseMt760(text : Text, minorUnitsOf : Text -> ?Nat8) : Result<ParsedGuarantee> {
    let ?m = fields(text) else return #err("not a FIN message");
    if (m.mt != 760) return #err("not an MT 760: MT " # Nat.toText(m.mt));
    let f = m.fields;
    let ?reference = field(f, "20") else return #err("field 20 missing");
    let ?d30 = field(f, "30") else return #err("field 30 missing");
    let ?issuedDay = parseFinDate(d30) else return #err("field 30 is not a date");
    let ?d31 = field(f, "31E") else return #err("field 31E missing");
    let ?expiry = parseFinDate(d31) else return #err("field 31E is not a date");
    let kind : TrT.GuaranteeKind = switch (field(f, "22D"), field(f, "22A")) { case (?"STBY", _) #standby; case (_, ?"ISCO") #counterGuarantee; case (_, _) #demandGuarantee };
    let rules : TrT.Rules = switch (field(f, "40C")) { case (?"ISPR") #ISP98; case (_) #URDG758 };
    let ?a32 = field(f, "32B") else return #err("field 32B missing");
    let cs32 = Text.toArray(a32);
    if (cs32.size() < 4) return #err("field 32B is short");
    let currency = Text.fromArray(Array.sliceToArray<Char>(cs32, 0, 3));
    let ?mu = minorUnitsOf(currency) else return #err("currency " # currency # " is not registered");
    let ?amount = parseFinAmount(Text.fromArray(Array.sliceToArray<Char>(cs32, 3, cs32.size())), mu) else return #err("field 32B amount unreadable");
    let applicantName = switch (field(f, "50")) { case (?t) firstLine(t); case null "" };
    let ?f59 = field(f, "59") else return #err("field 59 missing");
    let l59 = Iter.toArray(Text.split(f59, #char '\n'));
    let (beneficiaryAccount, beneficiaryName) = if (l59.size() > 1 and Text.startsWith(l59[0], #char '/')) (Text.trimStart(l59[0], #char '/'), l59[1]) else ("", l59[0]);
    let wordingText = switch (field(f, "45C")) { case (?t) t; case null "" };
    let statementRequired = not Text.contains(upper(wordingText), #text "NO SUPPORTING STATEMENT");
    #ok({ reference; issuedDay; expiry; kind; rules; currency; amount; applicantName; beneficiaryName; beneficiaryAccount; wordingText; statementRequired; issuingBank = m.sender })
  };
  public type Result<T> = { #ok : T; #err : Text };

  // ─── ISO 20022 tsrv ───────────────────────────────────────────────────────

  func esc(t : Text) : Text { Xml.escape(t) };
  /// An ISO amount: the integer part, a point, the minor units.
  public func isoAmount(minor : Nat, minorUnits : Nat8) : Text { Text.replace(finAmount(minor, minorUnits), #char ',', ".") };
  func amountEl(name : Text, minor : Nat, ccy : Text, mu : Nat8) : Text { "<" # name # " Ccy=\"" # ccy # "\">" # (if (mu == 0) Nat.toText(minor) else isoAmount(minor, mu)) # "</" # name # ">" };
  func partyEl(name : Text, nm : Text, bic : Text) : Text {
    "<" # name # "><Nm>" # esc(clip(nm, 140)) # "</Nm>" # (if (bic != "") "<Id><OrgId><AnyBIC>" # bic # "</AnyBIC></OrgId></Id>" else "") # "</" # name # ">"
  };
  func cpParty(name : Text, c : TrT.Counterparty, ownName : Text) : Text {
    switch (c) { case (#party(p)) partyEl(name, ownName # " " # Nat.toText(p.party), ""); case (#external(e)) partyEl(name, e.name, e.bic) }
  };
  func doc(ns : Text, body : Text) : Text { "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Document xmlns=\"urn:iso:std:iso:20022:tech:xsd:" # ns # "\">" # body # "</Document>" };

  public func tsrv001(bic : Text, bankName : Text, f : GuaranteeFacts) : Text {
    let g = f.g;
    let nm = switch (g.kind) { case (#standby) "STBY"; case (_) "DGAR" };
    let rules = switch (g.rules) { case (#ISP98) "ISPR"; case (#URDG758) "URDG"; case (#UCP600) "UCPR"; case (#URC522) "NONE" };
    doc("tsrv.001.001.01",
      "<UdrtkgIssnc><UdrtkgIssncDtls>" #
      "<Id>" # esc(clip(g.reference, 35)) # "</Id><Nm>" # nm # "</Nm><IssncTp>" # (if (g.kind == #counterGuarantee) "ISCO" else "ISSU") # "</IssncTp>" #
      cpParty("Applcnt", #party({ party = g.principal; account = g.principalAccount }), "CUSTOMER") #
      partyEl("Issr", bankName, bic) #
      cpParty("Bnfcry", g.beneficiary, "CUSTOMER") #
      "<DtOfIssnc>" # CivilDate.toText(f.issuedDay) # "</DtOfIssnc>" #
      "<UdrtkgAmt>" # amountEl("Amt", f.amount, f.currency, f.minorUnits) # "</UdrtkgAmt>" #
      "<XpryDtls><XpryTerms><DtTm><Dt>" # CivilDate.toText(f.expiry) # "</Dt></DtTm></XpryTerms></XpryDtls>" #
      "<GovncRulesAndLaw><RuleId><Cd>" # rules # "</Cd></RuleId></GovncRulesAndLaw>" #
      "<UdrtkgTermsAndConds><Txt>" # esc(clip(f.wordingText, 20000)) # "</Txt></UdrtkgTermsAndConds>" #
      "</UdrtkgIssncDtls></UdrtkgIssnc>")
  };
  public func tsrv005(bic : Text, bankName : Text, reference : Text, number : Nat, day : Nat, currency : Text, minorUnits : Nat8, oldAmount : Nat, a : TrT.Amendment) : Text {
    let adj = switch (a.amount) {
      case (?n) { if (n > oldAmount) "<UdrtkgAmtAdjstmnt><AmtChc>" # amountEl("IncrAmt", n - oldAmount, currency, minorUnits) # "</AmtChc></UdrtkgAmtAdjstmnt>" else if (n < oldAmount) "<UdrtkgAmtAdjstmnt><AmtChc>" # amountEl("DcrAmt", oldAmount - n, currency, minorUnits) # "</AmtChc></UdrtkgAmtAdjstmnt>" else "" };
      case null "";
    };
    let exp = switch (a.expiry) { case (?e) "<NewXpryDtls><XpryTerms><DtTm><Dt>" # CivilDate.toText(e) # "</Dt></DtTm></XpryTerms></NewXpryDtls>"; case null "" };
    doc("tsrv.005.001.01",
      "<UdrtkgAmdmnt><UdrtkgAmdmntDtls><SeqNb>" # Nat.toText(number) # "</SeqNb><DtOfIssnc>" # CivilDate.toText(day) # "</DtOfIssnc>" #
      "<UdrtkgId><Id>" # esc(clip(reference, 35)) # "</Id>" # partyEl("Issr", bankName, bic) # "</UdrtkgId>" # adj # exp #
      (if (a.other != "") "<AddtlInf>" # esc(clip(a.other, 2000)) # "</AddtlInf>" else "") #
      "</UdrtkgAmdmntDtls></UdrtkgAmdmnt>")
  };
  public func tsrv013(issuerBic : Text, issuerName : Text, reference : Text, demandId : Text, currency : Text, minorUnits : Nat8, amount : Nat, supportingStatement : Bool) : Text {
    doc("tsrv.013.001.01",
      "<UdrtkgDmnd><UdrtkgDmndDtls><Id>" # esc(clip(demandId, 35)) # "</Id><Tp>PAYM</Tp>" #
      "<UdrtkgId><Id>" # esc(clip(reference, 35)) # "</Id>" # partyEl("Issr", issuerName, issuerBic) # "</UdrtkgId>" #
      "<DmndAmt>" # amountEl("Amt", amount, currency, minorUnits) # (if (supportingStatement) "<AddtlInf>SUPPORTING STATEMENT OF BREACH ENCLOSED (URDG 758 ART. 15)</AddtlInf>" else "") # "</DmndAmt>" #
      "</UdrtkgDmndDtls></UdrtkgDmnd>")
  };
  public func tsrv016(bic : Text, bankName : Text, reference : Text, demandId : Text, submitted : Nat64, currency : Text, minorUnits : Nat8, amount : Nat, discrepancies : [Text], disposal : Text) : Text {
    var dsc = ""; var di = 0; for (d in discrepancies.vals()) { di += 1; dsc := dsc # "<Dscrpncy><Id>D" # Nat.toText(di) # "</Id><Nrrtv>" # esc(clip(d, 20000)) # "</Nrrtv></Dscrpncy>" };
    doc("tsrv.016.001.01",
      "<DmndRfslNtfctn><DmndRfslNtfctnDtls>" #
      "<UdrtkgId><Id>" # esc(clip(reference, 35)) # "</Id>" # partyEl("Issr", bankName, bic) # "</UdrtkgId>" #
      "<DmndDtls><Id>" # esc(clip(demandId, 35)) # "</Id><SubmissnDtTm>" # isoDateTime(submitted) # "</SubmissnDtTm>" # amountEl("Amt", amount, currency, minorUnits) # "</DmndDtls>" #
      "<Sts>REFUSED</Sts>" # dsc # "<DspstnOfDocs>" # esc(clip(disposal, 2000)) # "</DspstnOfDocs>" #
      "</DmndRfslNtfctnDtls></DmndRfslNtfctn>")
  };
  public func tsrv012(bic : Text, bankName : Text, reference : Text, effective : Nat, reason : Text) : Text {
    let code = if (Text.contains(upper(reason), #text "EXPIR")) "WOEX" else if (Text.contains(upper(reason), #text "RELEAS") or Text.contains(upper(reason), #text "RETURN")) "REFU" else "NOAC";
    doc("tsrv.012.001.01",
      "<UdrtkgTermntnNtfctn><UdrtkgTermntnNtfctnDtls>" #
      "<UdrtkgId><Id>" # esc(clip(reference, 35)) # "</Id>" # partyEl("Issr", bankName, bic) # "</UdrtkgId>" #
      "<TermntnDtls><FctvDt>" # CivilDate.toText(effective) # "</FctvDt><Rsn><Cd>" # code # "</Cd></Rsn><AddtlInf>" # esc(clip(reason, 2000)) # "</AddtlInf></TermntnDtls>" #
      "</UdrtkgTermntnNtfctnDtls></UdrtkgTermntnNtfctn>")
  };
  func isoDateTime(nanos : Nat64) : Text {
    let secs = Nat64.toNat(nanos / 1_000_000_000);
    let day = secs / 86_400; let rem = secs % 86_400;
    CivilDate.toText(day) # "T" # pad2(rem / 3600) # ":" # pad2(rem % 3600 / 60) # ":" # pad2(rem % 60) # "Z"
  };
}
