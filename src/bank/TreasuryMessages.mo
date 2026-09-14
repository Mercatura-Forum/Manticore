/// TreasuryMessages.mo: the treasury's ISO 20022 documents (treasury): an FX deal's confirmation as fxtr.014.001.04
/// (rendered from the deal, and parsed from the counterparty's so the contract matches it field by field), a
/// security trade's settlement instruction as sese.023.001.09, and the correspondent's camt.053.001.08 statement
/// parsed into the entries the nostro reconciliation matches. Schema-valid against the official XSDs the battery
/// carries; amounts in the schema's decimal notation from the currency's minor units and back, exactly.
///
/// Derivative confirmations (FpML) and the regulatory derivative report (auth.030) are the hub's renderings of the
/// deal block, which `treasuryDeal` exposes in full; the contract keeps the deal, the hub speaks the dialects.

import Array "mo:core/Array";
import Char "mo:core/Char";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Nat32 "mo:core/Nat32";
import Result "mo:core/Result";
import Text "mo:core/Text";

import CivilDate "mo:journal/CivilDate";

import TT "TreasuryTypes";
import Xml "Xml";
import M "TreasuryMath";

module {

  // ─── amounts and rates in the schema's notation ────────────────────────────

  /// `1234.56` from 123456 minor units with two decimals; no decimal point for a currency without minor units.
  public func decimalText(minor : Nat, minorUnits : Nat8) : Text {
    let mu = Nat8.toNat(minorUnits);
    if (mu == 0) return Nat.toText(minor);
    var scale = 1; var i = 0; while (i < mu) { scale *= 10; i += 1 };
    var frac = Nat.toText(minor % scale);
    while (frac.size() < mu) frac := "0" # frac;
    Nat.toText(minor / scale) # "." # frac
  };
  /// Minor units from the schema's decimal; more decimals than the currency has are refused unless they are zeros.
  public func parseDecimal(t : Text, minorUnits : Nat8) : ?Nat {
    let mu = Nat8.toNat(minorUnits);
    var whole = 0; var frac = 0; var fracDigits = 0; var inFrac = false; var any = false;
    for (c in Xml.trim(t).chars()) {
      if (c == '.') { if (inFrac) return null; inFrac := true }
      else if (c >= '0' and c <= '9') { any := true; let d = Nat32.toNat(Char.toNat32(c)) - 48; if (inFrac) { if (fracDigits < mu) { frac := frac * 10 + d; fracDigits += 1 } else if (d != 0) return null } else whole := whole * 10 + d }
      else return null;
    };
    if (not any) return null;
    while (fracDigits < mu) { frac *= 10; fracDigits += 1 };
    var scale = 1; var i = 0; while (i < mu) { scale *= 10; i += 1 };
    ?(whole * scale + frac)
  };
  /// A rate in micro as the schema's `BaseOneRate` (up to ten decimals): six decimals, exactly.
  public func rateText(micro : Nat) : Text { decimalText(micro, 6) };
  public func parseRate(t : Text) : ?Nat { parseDecimal(t, 6) };
  public func priceText(micro : Nat) : Text { decimalText(micro, 6) };

  func el(indent : Nat, name : Text, body : Text) : Text { sp(indent) # "<" # name # ">" # Xml.escape(body) # "</" # name # ">\n" };
  func sp(n : Nat) : Text { var s = ""; var i = 0; while (i < n) { s #= " "; i += 1 }; s };
  func clip(t : Text, n : Nat) : Text { if (t.size() <= n) t else Text.fromArray(Array.sliceToArray<Char>(Text.toArray(t), 0, n)) };
  func party(indent : Nat, name : Text, bic : Text, lei : Text) : Text {
    // PartyIdentification73Choice: AnyBIC when the party has one, else its name
    if (bic.size() == 8 or bic.size() == 11) sp(indent) # "<SubmitgPty><AnyBIC><AnyBIC>" # Xml.escape(bic) # "</AnyBIC>" # (if (lei.size() == 20) "<AltrntvIdr>" # Xml.escape(lei) # "</AltrntvIdr>" else "") # "</AnyBIC></SubmitgPty>\n"
    else sp(indent) # "<SubmitgPty><NmAndAdr><Nm>" # Xml.escape(clip(name, 350)) # "</Nm></NmAndAdr></SubmitgPty>\n"
  };

  // ─── fxtr.014.001.04 ───────────────────────────────────────────────────────

  /// The confirmation of one FX leg from the trading side's view: the trading side buys the base when the bank
  /// buys it; amounts in the two currencies, the settlement (value) date, the agreed rate with its currencies.
  public func fxtr014Xml(reference : Text, tradeDay : Nat, ourBic : Text, ourName : Text, cp : TT.Counterparty, f : TT.FxForward, quoteAmount : Nat, baseMinor : Nat8, quoteMinor : Nat8, swapLeg : Bool) : Text {
    let (buyCcy, buyAmt, buyMu, sellCcy, sellAmt, sellMu) = if (f.direction == #buy) (f.base, f.baseAmount, baseMinor, f.quote, quoteAmount, quoteMinor) else (f.quote, quoteAmount, quoteMinor, f.base, f.baseAmount, baseMinor);
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
    # "<Document xmlns=\"urn:iso:std:iso:20022:tech:xsd:fxtr.014.001.04\">\n"
    # "  <FXTradInstr>\n"
    # "    <TradInf>\n" # el(6, "TradDt", CivilDate.toText(tradeDay)) # el(6, "OrgtrRef", clip(reference, 35)) # el(6, "PdctTp", if (swapLeg) "FXSWAP" else if (f.valueDate > tradeDay + 2) "FXFORWARD" else "FXSPOT") # "    </TradInf>\n"
    # "    <TradgSdId>\n" # party(6, ourName, ourBic, "") # "    </TradgSdId>\n"
    # "    <CtrPtySdId>\n" # party(6, cp.name, cp.bic, cp.lei) # "    </CtrPtySdId>\n"
    # "    <TradAmts>\n"
    # sp(6) # "<TradgSdBuyAmt Ccy=\"" # Xml.escape(buyCcy) # "\">" # decimalText(buyAmt, buyMu) # "</TradgSdBuyAmt>\n"
    # sp(6) # "<TradgSdSellAmt Ccy=\"" # Xml.escape(sellCcy) # "\">" # decimalText(sellAmt, sellMu) # "</TradgSdSellAmt>\n"
    # el(6, "SttlmDt", CivilDate.toText(f.valueDate))
    # "    </TradAmts>\n"
    # "    <AgrdRate>\n" # el(6, "XchgRate", rateText(f.rateMicro)) # el(6, "UnitCcy", f.base) # el(6, "QtdCcy", f.quote) # "    </AgrdRate>\n"
    # "  </FXTradInstr>\n"
    # "</Document>\n"
  };

  /// The counterparty's fxtr.014 as the fields the deal is matched against. Their buy is our sell: the document
  /// speaks from the sender's (counterparty's) trading side, so the amounts cross. `minorUnitsOf` resolves a
  /// currency's decimals; `base` names which of the two currencies is the deal's base.
  public func parseFxtr014(doc : Blob, base : Text, minorUnitsOf : Text -> ?Nat8) : Result.Result<TT.ConfirmationFields, Text> {
    let root = switch (Xml.parse(doc)) { case (#ok(e)) e; case (#err(i)) return #err("not well-formed XML: " # i.rule) };
    if (root.name != "Document") return #err("the root is Document");
    let ?instr = Xml.child(root, "FXTradInstr") else return #err("FXTradInstr missing");
    let ?amts = Xml.child(instr, "TradAmts") else return #err("TradAmts missing");
    let ?buyEl = Xml.child(amts, "TradgSdBuyAmt") else return #err("TradgSdBuyAmt missing");
    let ?sellEl = Xml.child(amts, "TradgSdSellAmt") else return #err("TradgSdSellAmt missing");
    let ?buyCcy = Xml.attribute(buyEl, "Ccy") else return #err("TradgSdBuyAmt has no Ccy");
    let ?sellCcy = Xml.attribute(sellEl, "Ccy") else return #err("TradgSdSellAmt has no Ccy");
    let ?buyMu = minorUnitsOf(buyCcy) else return #err("unknown currency " # buyCcy);
    let ?sellMu = minorUnitsOf(sellCcy) else return #err("unknown currency " # sellCcy);
    let ?buyAmt = parseDecimal(buyEl.text, buyMu) else return #err("TradgSdBuyAmt is not a decimal");
    let ?sellAmt = parseDecimal(sellEl.text, sellMu) else return #err("TradgSdSellAmt is not a decimal");
    let ?sttlm = Xml.textAt(amts, ["SttlmDt"]) else return #err("SttlmDt missing");
    let ?valueDate = CivilDate.fromText(Xml.trim(sttlm)) else return #err("SttlmDt is not a date");
    let ?rateT = Xml.textAt(instr, ["AgrdRate", "XchgRate"]) else return #err("XchgRate missing");
    let ?rate = parseRate(rateT) else return #err("XchgRate is not a decimal");
    // the counterparty buys what we sell: from our side, amount1 is the base we deal in either direction
    let (baseAmt, quoteAmt, quoteCcy) = if (Text.equal(buyCcy, base)) (buyAmt, sellAmt, sellCcy) else if (Text.equal(sellCcy, base)) (sellAmt, buyAmt, buyCcy) else return #err("neither amount is in the base currency " # base);
    let cpName = switch (Xml.textAt(instr, ["TradgSdId", "SubmitgPty", "AnyBIC", "AnyBIC"])) {
      case (?bic) Xml.trim(bic);
      case null { switch (Xml.textAt(instr, ["TradgSdId", "SubmitgPty", "NmAndAdr", "Nm"])) { case (?n) Xml.trim(n); case null "" } };
    };
    let kind = switch (Xml.textAt(instr, ["TradInf", "PdctTp"])) { case (?p) { let t = Xml.trim(p); if (Text.equal(t, "FXSWAP")) "fxSwap" else "fxForward" }; case null "fxForward" };
    #ok({ kind; amount1 = baseAmt; currency1 = base; amount2 = quoteAmt; currency2 = quoteCcy; valueDate; rateMicro = rate; counterparty = cpName })
  };

  // ─── sese.023.001.09 ───────────────────────────────────────────────────────

  /// A securities settlement instruction: receive against payment for a purchase, deliver against payment for a
  /// sale; the ISIN, the nominal as a face amount, the settlement date, the deal price, the settlement amount.
  public func sese023Xml(txId : Text, t : TT.SecurityTrade, sec : TT.SecurityTerms, settlementAmount : Nat, minorUnits : Nat8, safekeepingAccount : Text, tradeDay : Nat) : Text {
    let receive = t.direction == #buy;
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
    # "<Document xmlns=\"urn:iso:std:iso:20022:tech:xsd:sese.023.001.09\">\n"
    # "  <SctiesSttlmTxInstr>\n"
    # el(4, "TxId", clip(txId, 35))
    # "    <SttlmTpAndAddtlParams>\n" # el(6, "SctiesMvmntTp", if (receive) "RECE" else "DELI") # el(6, "Pmt", "APMT") # "    </SttlmTpAndAddtlParams>\n"
    # "    <TradDtls>\n"
    # sp(6) # "<TradDt><Dt><Dt>" # CivilDate.toText(tradeDay) # "</Dt></Dt></TradDt>\n"
    # sp(6) # "<SttlmDt><Dt><Dt>" # CivilDate.toText(t.settlement) # "</Dt></Dt></SttlmDt>\n"
    # sp(6) # "<DealPric><Tp><Yldd>false</Yldd></Tp><Val><Rate>" # priceText(t.priceMicro) # "</Rate></Val></DealPric>\n"
    # "    </TradDtls>\n"
    # "    <FinInstrmId>\n" # el(6, "ISIN", sec.isin) # "    </FinInstrmId>\n"
    # "    <FinInstrmAttrbts>\n" # el(6, "DnmtnCcy", sec.currency) # el(6, "MtrtyDt", CivilDate.toText(sec.maturity)) # el(6, "IsseDt", CivilDate.toText(sec.issue)) # el(6, "IntrstRate", decimalText(sec.couponBps, 2)) # "    </FinInstrmAttrbts>\n"
    # "    <QtyAndAcctDtls>\n"
    # sp(6) # "<SttlmQty><Qty><FaceAmt>" # decimalText(t.nominal, minorUnits) # "</FaceAmt></Qty></SttlmQty>\n"
    # sp(6) # "<SfkpgAcct><Id>" # Xml.escape(clip(safekeepingAccount, 35)) # "</Id></SfkpgAcct>\n"
    # "    </QtyAndAcctDtls>\n"
    # "    <SttlmParams>\n" # sp(6) # "<SctiesTxTp><Cd>TRAD</Cd></SctiesTxTp>\n" # "    </SttlmParams>\n"
    # "    <SttlmAmt>\n" # sp(6) # "<Amt Ccy=\"" # Xml.escape(sec.currency) # "\">" # decimalText(settlementAmount, minorUnits) # "</Amt>\n" # el(6, "CdtDbtInd", if (receive) "DBIT" else "CRDT") # "    </SttlmAmt>\n"
    # "  </SctiesSttlmTxInstr>\n"
    # "</Document>\n"
  };

  // ─── camt.053.001.08 ───────────────────────────────────────────────────────

  /// The entries of a correspondent's statement: the reference (the entry reference, else the end-to-end id, else
  /// the account servicer reference), the amount in the account's currency, the direction, the value and booking
  /// days, the related party's name. Every entry must be in the statement's account currency.
  public func parseCamt053(doc : Blob, currency : Text, minorUnits : Nat8) : Result.Result<{ entries : [TT.StatementEntry]; from : ?Nat; to : ?Nat; account : Text }, Text> {
    let root = switch (Xml.parse(doc)) { case (#ok(e)) e; case (#err(i)) return #err("not well-formed XML: " # i.rule) };
    if (root.name != "Document") return #err("the root is Document");
    let ?stmtRoot = Xml.child(root, "BkToCstmrStmt") else return #err("BkToCstmrStmt missing");
    let ?stmt = Xml.child(stmtRoot, "Stmt") else return #err("Stmt missing");
    let acctCcy = switch (Xml.textAt(stmt, ["Acct", "Ccy"])) { case (?c) Xml.trim(c); case null "" };
    if (acctCcy.size() > 0 and not Text.equal(acctCcy, currency)) return #err("the statement's account is in " # acctCcy # ", the nostro in " # currency);
    let account = switch (Xml.textAt(stmt, ["Acct", "Id", "IBAN"])) { case (?i) Xml.trim(i); case null { switch (Xml.textAt(stmt, ["Acct", "Id", "Othr", "Id"])) { case (?o) Xml.trim(o); case null "" } } };
    func dayOf(t : ?Text) : ?Nat { switch (t) { case (?x) { let s = Xml.trim(x); CivilDate.fromText(if (s.size() >= 10) Text.fromArray(Array.sliceToArray<Char>(Text.toArray(s), 0, 10)) else s) }; case null null } };
    let from = dayOf(Xml.textAt(stmt, ["FrToDt", "FrDtTm"]));
    let to = dayOf(Xml.textAt(stmt, ["FrToDt", "ToDtTm"]));
    var out : [TT.StatementEntry] = [];
    for (n in Xml.children(stmt, "Ntry").vals()) {
      let ?amtEl = Xml.child(n, "Amt") else return #err("an entry has no Amt");
      switch (Xml.attribute(amtEl, "Ccy")) { case (?c) { if (not Text.equal(c, currency)) return #err("an entry is in " # c # ", the nostro in " # currency) }; case null {} };
      let ?amount = parseDecimal(amtEl.text, minorUnits) else return #err("an entry's Amt is not a decimal");
      let ?cd = Xml.textAt(n, ["CdtDbtInd"]) else return #err("an entry has no CdtDbtInd");
      let credit = Text.equal(Xml.trim(cd), "CRDT");
      if (not credit and not Text.equal(Xml.trim(cd), "DBIT")) return #err("CdtDbtInd is CRDT or DBIT");
      let ?valueDay = dayOf(Xml.textAt(n, ["ValDt", "Dt"])) else return #err("an entry has no value date");
      let bookingDay = switch (dayOf(Xml.textAt(n, ["BookgDt", "Dt"]))) { case (?d) d; case null valueDay };
      let reference = switch (Xml.textAt(n, ["NtryRef"])) {
        case (?r) Xml.trim(r);
        case null { switch (Xml.textAt(n, ["NtryDtls", "TxDtls", "Refs", "EndToEndId"])) { case (?e) Xml.trim(e); case null { switch (Xml.textAt(n, ["AcctSvcrRef"])) { case (?a) Xml.trim(a); case null "" } } } };
      };
      let counterparty = switch (Xml.textAt(n, ["NtryDtls", "TxDtls", "RltdPties", "Dbtr", "Pty", "Nm"])) {
        case (?d) Xml.trim(d);
        case null { switch (Xml.textAt(n, ["NtryDtls", "TxDtls", "RltdPties", "Cdtr", "Pty", "Nm"])) { case (?c) Xml.trim(c); case null "" } };
      };
      out := Array.concat(out, [{ reference; amount; credit; valueDay; bookingDay; counterparty }]);
    };
    #ok({ entries = out; from; to; account })
  };

  /// The fields of a deal's own confirmation, so the battery can compare what the contract would send with what it
  /// accepts back.
  public func fieldsOfForward(kindText : Text, f : TT.FxForward, cpName : Text) : TT.ConfirmationFields {
    { kind = kindText; amount1 = f.baseAmount; currency1 = f.base; amount2 = M.quoteAmount(f.baseAmount, f.rateMicro); currency2 = f.quote; valueDate = f.valueDate; rateMicro = f.rateMicro; counterparty = cpName }
  };
}
