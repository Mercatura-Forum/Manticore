/// CardMessages.mo — the cards domain's ISO 20022 documents (cards): the acquirer's authorization request as
/// cain.001.001.04 parsed into the request the decision engine reads (the token in place of the PAN, the HSM's
/// verdicts as verification results), and the issuer's response as cain.002.001.04 rendered from the decision with
/// the ISO 8583 response code and the approval code. ISO 8583 itself is the connector's dialect: the battery's
/// Python translator renders and reads it against jPOS's packagers, and feeds the contract what cain carries.
///
/// The PAN boundary holds here too: `Card/PAN` is refused when present — a request must carry `Tkn/PmtTkn`.

import Array "mo:core/Array";
import Char "mo:core/Char";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Nat32 "mo:core/Nat32";
import Nat64 "mo:core/Nat64";
import Result "mo:core/Result";
import Text "mo:core/Text";

import CivilDate "mo:journal/CivilDate";
import Sha256 "mo:sha2/Sha256";

import CT "CardTypes";
import Xml "Xml";
import TM "TreasuryMessages";

module {

  /// ISO 4217 numeric codes for the currencies the bank deals in, with their minor units — the standard's own
  /// table (ISO 4217:2015, list one), not a rule of the bank's; a code outside it passes through as text and the
  /// decision engine declines the currency mismatch.
  public let ISO4217 : [(Text, Text, Nat8)] = [
    ("818", "EGP", 2), ("840", "USD", 2), ("978", "EUR", 2), ("826", "GBP", 2), ("682", "SAR", 2), ("784", "AED", 2), ("414", "KWD", 3), ("048", "BHD", 3), ("512", "OMR", 3), ("634", "QAR", 2),
    ("392", "JPY", 0), ("756", "CHF", 2), ("124", "CAD", 2), ("036", "AUD", 2), ("356", "INR", 2), ("710", "ZAR", 2), ("949", "TRY", 2), ("400", "JOD", 3), ("504", "MAD", 2), ("788", "TND", 3),
  ];
  public func alphaOf(numeric : Text) : ?(Text, Nat8) { for ((n, a, mu) in ISO4217.vals()) { if (Text.equal(n, numeric)) return ?(a, mu) }; null };
  public func numericOf(alpha : Text) : ?(Text, Nat8) { for ((n, a, mu) in ISO4217.vals()) { if (Text.equal(a, alpha)) return ?(n, mu) }; null };
  /// ISO 3166-1 numeric to alpha-2 for the countries the battery and the acquirers name; unknown passes through.
  public let COUNTRIES : [(Text, Text)] = [("818", "EG"), ("840", "US"), ("826", "GB"), ("276", "DE"), ("250", "FR"), ("682", "SA"), ("784", "AE"), ("414", "KW"), ("792", "TR"), ("356", "IN"), ("156", "CN"), ("392", "JP")];
  public func countryAlpha(numeric : Text) : Text { for ((n, a) in COUNTRIES.vals()) { if (Text.equal(n, numeric)) return a }; numeric };
  public func countryNumeric(alpha : Text) : Text { for ((n, a) in COUNTRIES.vals()) { if (Text.equal(a, alpha)) return n }; alpha };

  func el(indent : Nat, name : Text, body : Text) : Text { sp(indent) # "<" # name # ">" # Xml.escape(body) # "</" # name # ">\n" };
  func sp(n : Nat) : Text { var s = ""; var i = 0; while (i < n) { s #= " "; i += 1 }; s };
  func clip(t : Text, n : Nat) : Text { if (t.size() <= n) t else Text.fromArray(Array.sliceToArray<Char>(Text.toArray(t), 0, n)) };
  func isDigits(t : Text) : Bool { if (t.size() == 0) return false; for (c in t.chars()) { if (c < '0' or c > '9') return false }; true };
  func digitsToNat(t : Text) : Nat { var n = 0; for (c in t.chars()) n := n * 10 + (Nat32.toNat(Char.toNat32(c)) - 48); n };

  /// The ISO 8583 processing code (DE 3, first two digits) of a request kind, and back.
  public func processingCode(k : CT.AuthKind) : Text { switch (k) { case (#purchase) "00"; case (#preAuthorization) "00"; case (#incremental(_)) "00"; case (#completion(_)) "00"; case (#refund) "20"; case (#reversal(_)) "00" } };
  /// The transaction attribute cain carries for the kinds ISO 8583 tells apart by message type and DE 25/60.
  func attributeOf(k : CT.AuthKind) : ?Text { switch (k) { case (#preAuthorization) ?"PAUT"; case (#incremental(_)) ?"INCR"; case (#completion(_)) ?"CPLT"; case (_) null } };
  func kindOf(txTp : Text, attr : ?Text, msgFctn : Text, original : ?Nat) : CT.AuthKind {
    if (Text.equal(msgFctn, "RVRA") or Text.equal(msgFctn, "RVRQ")) return #reversal({ of = switch (original) { case (?o) o; case null 0 } });
    if (Text.equal(txTp, "20")) return #refund;
    switch (attr) {
      case (?"PAUT") #preAuthorization;
      case (?"INCR") #incremental({ of = switch (original) { case (?o) o; case null 0 } });
      case (?"CPLT") #completion({ of = switch (original) { case (?o) o; case null 0 } });
      case (_) #purchase;
    }
  };
  func entryMode(ch : CT.Channel) : Text { switch (ch) { case (#pos) "ICCY"; case (#atm) "ICCY"; case (#ecom) "KEEN"; case (#contactless) "ICPY" } };

  /// The acquirer's cain.001 as an `AuthRequest`. `day` is the day the request is recorded on.
  public func parseCain001(doc : Blob) : Result.Result<{ request : CT.AuthRequest; acquirerCountry : Text; messageFunction : Text }, Text> {
    let root = switch (Xml.parse(doc)) { case (#ok(e)) e; case (#err(i)) return #err("not well-formed XML: " # i.rule) };
    if (root.name != "Document") return #err("the root is Document");
    let ?m = Xml.child(root, "AuthstnInitn") else return #err("AuthstnInitn missing");
    if (Xml.textAt(m, ["Card", "PAN"]) != null) return #err("a PAN is not accepted: the contract knows a card by its token");
    if (Xml.textAt(m, ["Card", "Trck2"]) != null or Xml.textAt(m, ["Card", "Trck1"]) != null) return #err("track data is not accepted");
    let ?tokenT = Xml.textAt(m, ["Tkn", "PmtTkn"]) else return #err("Tkn/PmtTkn missing");
    let token = Text.encodeUtf8(Xml.trim(tokenT));
    let ?msgFctn = Xml.textAt(m, ["Hdr", "MsgFctn"]) else return #err("Hdr/MsgFctn missing");
    let ?txTp = Xml.textAt(m, ["TxChrtcs", "TxTp"]) else return #err("TxChrtcs/TxTp missing");
    let attr = switch (Xml.textAt(m, ["TxChrtcs", "TxAttr"])) { case (?a) ?Xml.trim(a); case null null };
    let ?acq = Xml.textAt(m, ["Acqrr", "Id"]) else return #err("Acqrr/Id missing");
    let acquirerCountry = switch (Xml.textAt(m, ["Acqrr", "Ctry"])) { case (?c) countryAlpha(Xml.trim(c)); case null "" };
    let ?stan = Xml.textAt(m, ["TxId", "SysTracAudtNb"]) else return #err("TxId/SysTracAudtNb missing");
    let ?rrn = Xml.textAt(m, ["TxId", "RtrvlRefNb"]) else return #err("TxId/RtrvlRefNb missing");
    let ?amtT = Xml.textAt(m, ["TxAmts", "Amt"]) else return #err("TxAmts/Amt missing");
    let ?ccyN = Xml.textAt(m, ["TxAmts", "Ccy"]) else return #err("TxAmts/Ccy missing");
    let (currency, mu) = switch (alphaOf(Xml.trim(ccyN))) { case (?x) x; case null (Xml.trim(ccyN), 2 : Nat8) };
    let ?amount = TM.parseDecimal(amtT, mu) else return #err("TxAmts/Amt is not a decimal of the currency's minor units");
    let ?mccT = Xml.textAt(m, ["Cntxt", "MrchntCtgyCd"]) else return #err("Cntxt/MrchntCtgyCd missing");
    if (not isDigits(Xml.trim(mccT))) return #err("MrchntCtgyCd is four digits");
    let mcc = digitsToNat(Xml.trim(mccT));
    let entry = switch (Xml.textAt(m, ["Cntxt", "CardDataNtryMd"])) { case (?e) Xml.trim(e); case null "" };
    let ecom = switch (Xml.textAt(m, ["Cntxt", "EComrc"])) { case (?e) Text.equal(Xml.trim(e), "true"); case null false };
    let terminalType = switch (Xml.textAt(m, ["Termnl", "Tp"])) { case (?t) Xml.trim(t); case null "" };
    let channel : CT.Channel = if (Text.equal(terminalType, "ATMT")) #atm else if (ecom) #ecom else if (Text.equal(entry, "ICPY") or Text.equal(entry, "RFID")) #contactless else #pos;
    let merchantId = switch (Xml.textAt(m, ["Accptr", "Id"])) { case (?i) Xml.trim(i); case null "" };
    let merchantName = switch (Xml.textAt(m, ["Accptr", "NmAndLctn"])) { case (?n) Xml.trim(n); case null "" };
    let merchantCountry = switch (Xml.textAt(m, ["Accptr", "Adr", "Ctry"])) { case (?c) countryAlpha(Xml.trim(c)); case null acquirerCountry };
    var cryptogramValid = false; var pinVerified : ?Bool = null;
    for (v in Xml.children(m, "Vrfctn").vals()) {
      let tp = switch (Xml.textAt(v, ["Tp"])) { case (?t) Xml.trim(t); case null "" };
      let ok = switch (Xml.textAt(v, ["Rslt"])) { case (?r) Text.equal(Xml.trim(r), "SUCC"); case null false };
      if (Text.equal(tp, "CRYP")) cryptogramValid := ok;
      if (Text.equal(tp, "PINV")) pinVerified := ?ok;
    };
    let original : ?Nat = switch (Xml.textAt(m, ["OrgnlDataElmts", "ApprvlCd"])) { case (?c) authIdOfCode(Xml.trim(c)); case null null };
    let localTime : Nat64 = switch (Xml.textAt(m, ["TxId", "LclDt"]), Xml.textAt(m, ["TxId", "LclTm"])) {
      case (?d, t) {
        switch (CivilDate.fromText(Xml.trim(d))) {
          case (?day) { let secs = switch (t) { case (?tt) secondsOf(Xml.trim(tt)); case null 0 }; Nat64.fromNat(day) * 86_400_000_000_000 + Nat64.fromNat(secs) * 1_000_000_000 };
          case null 0;
        }
      };
      case (_, _) 0;
    };
    let request : CT.AuthRequest = {
      token; kind = kindOf(Xml.trim(txTp), attr, Xml.trim(msgFctn), original); amount; currency; mcc; merchantHash = merchantHashOf(merchantId, merchantName); merchantCountry; acquirer = Xml.trim(acq);
      channel; cryptogramValid; pinVerified; stan = Xml.trim(stan); rrn = Xml.trim(rrn); localTime;
    };
    #ok({ request; acquirerCountry; messageFunction = Xml.trim(msgFctn) })
  };
  func secondsOf(t : Text) : Nat {
    // HH:MM:SS, the rest ignored
    let parts = Array.fromIter<Text>(Text.split(t, #char ':'));
    if (parts.size() < 3) return 0;
    func n(x : Text) : Nat { let s = clip(x, 2); if (isDigits(s)) digitsToNat(s) else 0 };
    n(parts[0]) * 3600 + n(parts[1]) * 60 + n(parts[2])
  };
  /// The merchant as a digest of its acceptor id and name — never the name itself in a block.
  public func merchantHashOf(id : Text, name : Text) : Blob { Sha256.fromBlob(#sha256, Text.encodeUtf8(id # "|" # name)) };
  func authIdOfCode(code : Text) : ?Nat {
    if (code.size() != 6) return null;
    var n = 0;
    for (c in code.chars()) {
      let v : Nat = if (c >= '0' and c <= '9') Nat32.toNat(Char.toNat32(c)) - 48 else if (c >= 'A' and c <= 'Z') Nat32.toNat(Char.toNat32(c)) - 55 else return null;
      n := n * 36 + v;
    };
    ?n
  };

  /// The issuer's cain.002: the request echoed in its identification and amounts, the processing result with the
  /// ISO 8583 response code and, for an approval, the approval code.
  public func cain002Xml(req : CT.AuthRequest, decision : CT.Decision, issuerId : Text, acquirerCountry : Text, createdDay : Nat, messageFunction : Text) : Text {
    let (ccyN, mu) = switch (numericOf(req.currency)) { case (?x) x; case null (req.currency, 2 : Nat8) };
    let date = CivilDate.toText(createdDay);
    let fctn = if (Text.equal(messageFunction, "RVRQ")) "RVRP" else if (Text.equal(messageFunction, "AUTQ")) "AUTP" else if (Text.equal(messageFunction, "FINQ")) "FINP" else "AUTP";
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
    # "<Document xmlns=\"urn:iso:std:iso:20022:tech:xsd:cain.002.001.04\">\n"
    # "  <AuthstnRspn>\n"
    # "    <Hdr>\n" # el(6, "MsgFctn", fctn) # el(6, "PrtcolVrsn", "4.0") # el(6, "CreDtTm", date # "T12:00:00Z") # sp(6) # "<InitgPty><Id>" # Xml.escape(clip(issuerId, 35)) # "</Id><Tp>CISS</Tp></InitgPty>\n" # "    </Hdr>\n"
    # "    <TxChrtcs>\n" # el(6, "TxTp", processingCode(req.kind)) # (switch (attributeOf(req.kind)) { case (?a) el(6, "TxAttr", a); case null "" }) # "    </TxChrtcs>\n"
    # "    <Acqrr>\n" # el(6, "Id", clip(req.acquirer, 11)) # (if (acquirerCountry.size() > 0) el(6, "Ctry", countryNumeric(acquirerCountry)) else "") # "    </Acqrr>\n"
    # "    <TxId>\n" # el(6, "SysTracAudtNb", clip(req.stan, 12)) # el(6, "RtrvlRefNb", rrn12(req.rrn)) # "    </TxId>\n"
    # "    <TxAmts>\n" # el(6, "Amt", TM.decimalText(req.amount, mu)) # el(6, "Ccy", ccyN) # "    </TxAmts>\n"
    # "    <Cntxt>\n" # el(6, "CardDataNtryMd", entryMode(req.channel)) # el(6, "MrchntCtgyCd", mcc4(req.mcc)) # "    </Cntxt>\n"
    # "    <Tkn>\n" # el(6, "PmtTkn", tokenText(req.token)) # "    </Tkn>\n"
    # "    <PrcgRslt>\n" # el(6, "RspnSrcTp", "CISS") # el(6, "RspnCd", CT.responseCode(decision)) # (switch (decision) { case (#approved(a)) el(6, "ApprvlCd", a.authCode); case (_) "" }) # "    </PrcgRslt>\n"
    # "  </AuthstnRspn>\n"
    # "</Document>\n"
  };
  func rrn12(r : Text) : Text { var t = clip(r, 12); while (t.size() < 12) t := t # " "; t };
  func mcc4(m : Nat) : Text { var t = Nat.toText(m); while (t.size() < 4) t := "0" # t; t };
  /// The token as the numeric text cain carries; a token that is not digits is shown as its decimal bytes.
  public func tokenText(t : Blob) : Text {
    switch (Text.decodeUtf8(t)) { case (?s) { if (isDigits(s) and s.size() <= 19) return s }; case null {} };
    var out = "";
    for (b in t.vals()) { var d = Nat.toText(Nat8.toNat(b)); while (d.size() < 3) d := "0" # d; out #= d };
    clip(out, 19)
  };
}
