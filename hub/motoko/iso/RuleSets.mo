/// RuleSets.mo — market-practice rule sets as data: CBPR+ (Swift cross-border payments and
/// reporting) and HVPS+ (high-value payment systems) over the official-shape messages the schema profile admits.
///
/// A rule set is a list of rules; a rule is a stable id, the families it applies to, one check from a closed
/// vocabulary (`Check`), and the public basis the rule was taken from. `evaluate` walks the parsed message
/// (the vendored parser's element tree, after the official schema passed) and answers the disagreements under
/// the `usageGuideline` tier with the rule's own id — what a usage guideline adds on top of the base XSD.
///
/// What this is and is not. The rule content is drawn from the public descriptions of the two guidelines:
/// Swift's ISO 20022 programme pages and the CBPR+ User Handbook's published structure, the Payments Market
/// Practice Group's papers (structured addresses, UETR, charges), and the HVPS+ practice as the RTGS operators
/// publish it in their own ISO 20022 specifications (ECB T2, Bank of England CHAPS, Fed/TCH). The guidelines
/// themselves — the MyStandards usage guidelines with their rule identifiers — are access-controlled: this
/// harness could not fetch them (login-gated; swift.com refuses the programmatic fetch), so the rule ids here
/// are the hub's, each carrying its basis, and `reconciliation` on each set states that the identifier-by-
/// identifier comparison with MyStandards has not been performed. The counts `implemented` prints are of the
/// rules here, nothing more.

import Array "mo:core/Array";
import Char "mo:core/Char";
import List "mo:core/List";
import Nat "mo:core/Nat";
import Text "mo:core/Text";

import Xml "Xml";

module {

  public type Issue = { rule : Text; path : Text; detail : Text };

  /// The closed check vocabulary. (The UETR's RFC 4122 v4 shape is the base schema's own pattern — the
  /// schema tier refuses it — so it is not a guideline rule here.) Paths are element paths under the message root (the `Document`'s one
  /// child), every repetition of every segment included: `CdtTrfTxInf/PmtId/UETR` names the UETR of each
  /// transaction.
  public type Check = {
    #requireElement : Text;                  // at least one occurrence
    #forbidElement : Text;                   // no occurrence
    #exactOccurs : (Text, Nat);              // exactly n occurrences
    #maxOccurs : (Text, Nat);
    #textEquals : (Text, Text);              // every occurrence's text
    #codeIn : (Text, [Text]);                // every occurrence's text is one of
    #codesInclude : (Text, [Text]);          // the occurrences' texts include each of
    #maxLength : (Text, Nat);
    #restrictedFinX : Text;                  // FIN X character set, not starting with '/', no '//'
    #agentIdentified : Text;                 // FinInstnId carries BICFI, or ClrSysMmbId/MmbId, or Nm with PstlAdr
    #addressStructuredOrHybrid : Text;       // a PstlAdr, when present, has TwnNm and Ctry and at most two AdrLine
    #requireHeader;                          // the message travels with its head.001 AppHdr
  };

  public type Rule = { id : Text; families : [Text]; check : Check; basis : Text };
  public type RuleSet = { id : Text; name : Text; authority : Text; basis : [Text]; reconciliation : Text; rules : [Rule] };

  // ─── evaluation ───

  func select(root : Xml.Element, path : Text) : [Xml.Element] {
    var current : [Xml.Element] = [root];
    for (seg in Text.split(path, #char '/')) {
      let next = List.empty<Xml.Element>();
      for (e in current.vals()) { for (c in Xml.children(e, seg).vals()) List.add(next, c) };
      current := List.toArray(next);
    };
    current
  };
  func texts(root : Xml.Element, path : Text) : [Text] { Array.map<Xml.Element, Text>(select(root, path), func(e) { Xml.trim(e.text) }) };
  func finX(c : Char) : Bool {
    Char.isDigit(c) or (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '/' or c == '-' or c == '?' or c == ':' or c == '(' or c == ')' or c == '.' or c == ',' or c == '\'' or c == '+' or c == ' '
  };

  func evaluateRule(r : Rule, root : Xml.Element, hasHeader : Bool, out : List.List<Issue>) {
    let base = "/" # root.name # "/";
    func add(path : Text, detail : Text) { List.add(out, { rule = r.id; path = base # path; detail }) };
    switch (r.check) {
      case (#requireElement(p)) { if (select(root, p).size() == 0) add(p, "required by the guideline") };
      case (#forbidElement(p)) { if (select(root, p).size() > 0) add(p, "not allowed by the guideline") };
      case (#exactOccurs(p, n)) { let k = select(root, p).size(); if (k != n) add(p, "exactly " # Nat.toText(n) # " expected, " # Nat.toText(k) # " found") };
      case (#maxOccurs(p, n)) { let k = select(root, p).size(); if (k > n) add(p, "at most " # Nat.toText(n) # " allowed, " # Nat.toText(k) # " found") };
      case (#textEquals(p, v)) { for (t in texts(root, p).vals()) { if (t != v) add(p, "'" # t # "' where the guideline requires '" # v # "'") } };
      case (#codeIn(p, codes)) { for (t in texts(root, p).vals()) { if (Array.find<Text>(codes, func(c) { c == t }) == null) add(p, "'" # t # "' is not one of " # Text.join(codes.vals(), ", ")) } };
      case (#codesInclude(p, codes)) { let ts = texts(root, p); for (c in codes.vals()) { if (Array.find<Text>(ts, func(t) { t == c }) == null) add(p, c # " is required among the values") } };
      case (#maxLength(p, n)) { for (t in texts(root, p).vals()) { if (Text.size(t) > n) add(p, "longer than " # Nat.toText(n)) } };
      case (#restrictedFinX(p)) {
        for (t in texts(root, p).vals()) {
          if (Text.startsWith(t, #char '/')) add(p, "must not start with '/'")
          else if (Text.contains(t, #text "//")) add(p, "must not contain '//'")
          else { for (c in t.chars()) { if (not finX(c)) { add(p, "'" # Text.fromChar(c) # "' is outside the FIN X character set"); break } } };
        }
      };
      case (#agentIdentified(p)) {
        for (a in select(root, p).vals()) {
          let bic = Xml.textAt(a, ["FinInstnId", "BICFI"]) != null;
          let member = Xml.textAt(a, ["FinInstnId", "ClrSysMmbId", "MmbId"]) != null;
          let named = Xml.textAt(a, ["FinInstnId", "Nm"]) != null and Xml.path(a, ["FinInstnId", "PstlAdr"]) != null;
          if (not (bic or member or named)) add(p, "an agent is identified by BICFI, by a clearing-system member id, or by name and postal address");
        }
      };
      case (#addressStructuredOrHybrid(p)) {
        for (adr in select(root, p).vals()) {
          let town = Xml.child(adr, "TwnNm") != null;
          let country = Xml.child(adr, "Ctry") != null;
          let lines = Xml.children(adr, "AdrLine").size();
          if (not (town and country)) add(p, "a postal address carries TwnNm and Ctry (structured or hybrid); unstructured addresses are not allowed")
          else if (lines > 2) add(p, "a hybrid address carries at most two AdrLine");
        }
      };
      case (#requireHeader) { if (not hasHeader) add("", "the message travels with its business application header (head.001 AppHdr before the Document)") };
    }
  };

  /// The set's disagreements with a message of `family` ("pacs.008"), whose `root` is the message element
  /// under `Document`; `hasHeader` says whether an AppHdr travelled with it.
  public func evaluate(rs : RuleSet, family : Text, root : Xml.Element, hasHeader : Bool) : [Issue] {
    let out = List.empty<Issue>();
    for (r in rs.rules.vals()) { if (Array.find<Text>(r.families, func(f) { f == family }) != null) evaluateRule(r, root, hasHeader, out) };
    List.toArray(out)
  };

  /// The rules of the set that apply to each family it covers: (family, count).
  public func implemented(rs : RuleSet) : [(Text, Nat)] {
    let fams = List.empty<Text>();
    for (r in rs.rules.vals()) { for (f in r.families.vals()) { if (not List.contains(fams, Text.equal, f)) List.add(fams, f) } };
    Array.map<Text, (Text, Nat)>(List.toArray(fams), func(f) { (f, Array.filter<Rule>(rs.rules, func(r) { Array.find<Text>(r.families, func(x) { x == f }) != null }).size()) })
  };

  public func families(rs : RuleSet) : [Text] { Array.map<(Text, Nat), Text>(implemented(rs), func(p) { p.0 }) };

  // ─── the sets ───

  let SWIFT_UHB = "Swift, CBPR+ User Handbook (structure published; content on MyStandards)";
  let SWIFT_PROGRAMME = "Swift ISO 20022 programme, public CBPR+ pages: UETR, BAH, single transaction, settlement methods";
  let PMPG_ADDRESS = "PMPG market practice: structured and hybrid postal addresses (end of unstructured addresses, November 2026)";
  let PMPG_CHARSET = "CBPR+ restricted FIN X character set for identifiers (Swift public FAQ on character sets in ISO 20022)";
  let HVPS_PRACTICE = "HVPS+ market practice as published in RTGS operators' ISO 20022 specifications (ECB T2 UDFS, Bank of England CHAPS ISO 20022 schemas, Federal Reserve / TCH)";

  let PACS_PAYMENTS : [Text] = ["pacs.008", "pacs.009"];
  let CBPR_ALL : [Text] = ["pacs.008", "pacs.009", "pacs.002", "pacs.004", "camt.053", "camt.054", "camt.056", "camt.029"];
  let HVPS_ALL : [Text] = ["pacs.008", "pacs.009", "pacs.002", "camt.050", "camt.052", "camt.053"];

  public func cbprPlus() : RuleSet {
    {
      id = "CBPRPLUS"; name = "CBPR+ (cross-border payments and reporting plus)"; authority = "Swift";
      basis = [SWIFT_UHB, SWIFT_PROGRAMME, PMPG_ADDRESS, PMPG_CHARSET];
      reconciliation = "NOT RECONCILED with MyStandards rule identifiers: the CBPR+ usage guidelines are access-controlled and the harness could not fetch them. The rule ids are the hub's; each rule names its public basis.";
      rules = [
        // every CBPR+ message
        { id = "CBPR-BAH-REQUIRED"; families = CBPR_ALL; check = #requireHeader; basis = SWIFT_PROGRAMME },
        { id = "CBPR-MSGID-FINX"; families = ["pacs.008", "pacs.009", "pacs.002", "pacs.004"]; check = #restrictedFinX("GrpHdr/MsgId"); basis = PMPG_CHARSET },
        // pacs.008 / pacs.009
        { id = "CBPR-ONE-TX"; families = ["pacs.008"]; check = #exactOccurs("CdtTrfTxInf", 1); basis = SWIFT_PROGRAMME },
        { id = "CBPR-ONE-TX"; families = ["pacs.009"]; check = #exactOccurs("CdtTrfTxInf", 1); basis = SWIFT_PROGRAMME },
        { id = "CBPR-NBOFTXS-ONE"; families = PACS_PAYMENTS; check = #textEquals("GrpHdr/NbOfTxs", "1"); basis = SWIFT_PROGRAMME },
        { id = "CBPR-UETR-REQUIRED"; families = PACS_PAYMENTS; check = #requireElement("CdtTrfTxInf/PmtId/UETR"); basis = SWIFT_PROGRAMME },
        { id = "CBPR-STTLM-MTD"; families = PACS_PAYMENTS; check = #codeIn("GrpHdr/SttlmInf/SttlmMtd", ["INDA", "INGA", "COVE"]); basis = SWIFT_UHB },
        { id = "CBPR-STTLM-DT-REQUIRED"; families = PACS_PAYMENTS; check = #requireElement("CdtTrfTxInf/IntrBkSttlmDt"); basis = SWIFT_UHB },
        { id = "CBPR-CHRGBR"; families = ["pacs.008"]; check = #codeIn("CdtTrfTxInf/ChrgBr", ["DEBT", "CRED", "SHAR"]); basis = SWIFT_UHB },
        { id = "CBPR-E2E-FINX"; families = PACS_PAYMENTS; check = #restrictedFinX("CdtTrfTxInf/PmtId/EndToEndId"); basis = PMPG_CHARSET },
        { id = "CBPR-INSTRID-FINX"; families = PACS_PAYMENTS; check = #restrictedFinX("CdtTrfTxInf/PmtId/InstrId"); basis = PMPG_CHARSET },
        { id = "CBPR-DBTR-AGENT-ID"; families = ["pacs.008"]; check = #agentIdentified("CdtTrfTxInf/DbtrAgt"); basis = SWIFT_UHB },
        { id = "CBPR-CDTR-AGENT-ID"; families = ["pacs.008"]; check = #agentIdentified("CdtTrfTxInf/CdtrAgt"); basis = SWIFT_UHB },
        { id = "CBPR-DBTR-ADDRESS"; families = ["pacs.008"]; check = #addressStructuredOrHybrid("CdtTrfTxInf/Dbtr/PstlAdr"); basis = PMPG_ADDRESS },
        { id = "CBPR-CDTR-ADDRESS"; families = ["pacs.008"]; check = #addressStructuredOrHybrid("CdtTrfTxInf/Cdtr/PstlAdr"); basis = PMPG_ADDRESS },
        { id = "CBPR-FI-DBTR-ID"; families = ["pacs.009"]; check = #agentIdentified("CdtTrfTxInf/Dbtr"); basis = SWIFT_UHB },
        { id = "CBPR-FI-CDTR-ID"; families = ["pacs.009"]; check = #agentIdentified("CdtTrfTxInf/Cdtr"); basis = SWIFT_UHB },
        // pacs.002
        { id = "CBPR-STS-ONE-TX"; families = ["pacs.002"]; check = #exactOccurs("TxInfAndSts", 1); basis = SWIFT_UHB },
        { id = "CBPR-STS-ORGNL-UETR"; families = ["pacs.002"]; check = #requireElement("TxInfAndSts/OrgnlUETR"); basis = SWIFT_PROGRAMME },
        { id = "CBPR-STS-NO-GROUP-STATUS"; families = ["pacs.002"]; check = #forbidElement("OrgnlGrpInfAndSts/GrpSts"); basis = SWIFT_UHB },
        // pacs.004
        { id = "CBPR-RTR-ONE-TX"; families = ["pacs.004"]; check = #exactOccurs("TxInf", 1); basis = SWIFT_UHB },
        { id = "CBPR-RTR-ORGNL-UETR"; families = ["pacs.004"]; check = #requireElement("TxInf/OrgnlUETR"); basis = SWIFT_PROGRAMME },
        { id = "CBPR-RTR-REASON"; families = ["pacs.004"]; check = #requireElement("TxInf/RtrRsnInf"); basis = SWIFT_UHB },
        { id = "CBPR-RTR-STTLM-DT"; families = ["pacs.004"]; check = #requireElement("TxInf/IntrBkSttlmDt"); basis = SWIFT_UHB },
        // camt.053 / camt.054
        { id = "CBPR-STMT-ONE"; families = ["camt.053"]; check = #exactOccurs("Stmt", 1); basis = SWIFT_UHB },
        { id = "CBPR-STMT-BALANCES"; families = ["camt.053"]; check = #codesInclude("Stmt/Bal/Tp/CdOrPrtry/Cd", ["OPBD", "CLBD"]); basis = SWIFT_UHB },
        { id = "CBPR-STMT-BOOKED"; families = ["camt.053"]; check = #codeIn("Stmt/Ntry/Sts/Cd", ["BOOK"]); basis = SWIFT_UHB },
        { id = "CBPR-NTFCTN-ONE"; families = ["camt.054"]; check = #exactOccurs("Ntfctn", 1); basis = SWIFT_UHB },
        { id = "CBPR-NTFCTN-BOOKED"; families = ["camt.054"]; check = #codeIn("Ntfctn/Ntry/Sts/Cd", ["BOOK"]); basis = SWIFT_UHB },
        // camt.056 / camt.029
        { id = "CBPR-CXL-ONE"; families = ["camt.056"]; check = #exactOccurs("Undrlyg/TxInf", 1); basis = SWIFT_UHB },
        { id = "CBPR-CXL-ORGNL-UETR"; families = ["camt.056"]; check = #requireElement("Undrlyg/TxInf/OrgnlUETR"); basis = SWIFT_PROGRAMME },
        { id = "CBPR-CXL-REASON"; families = ["camt.056"]; check = #requireElement("Undrlyg/TxInf/CxlRsnInf"); basis = SWIFT_UHB },
        { id = "CBPR-RSLTN-ONE"; families = ["camt.029"]; check = #exactOccurs("CxlDtls/TxInfAndSts", 1); basis = SWIFT_UHB },
        { id = "CBPR-RSLTN-ORGNL-UETR"; families = ["camt.029"]; check = #requireElement("CxlDtls/TxInfAndSts/OrgnlUETR"); basis = SWIFT_PROGRAMME },
        { id = "CBPR-RSLTN-STATUS"; families = ["camt.029"]; check = #requireElement("CxlDtls/TxInfAndSts/TxCxlSts"); basis = SWIFT_UHB },
      ];
    }
  };

  public func hvpsPlus() : RuleSet {
    {
      id = "HVPSPLUS"; name = "HVPS+ (high-value payment systems plus)"; authority = "HVPS+ task force (RTGS operators)";
      basis = [HVPS_PRACTICE, SWIFT_PROGRAMME, PMPG_CHARSET];
      reconciliation = "NOT RECONCILED with MyStandards rule identifiers: the HVPS+ usage guidelines are access-controlled and the harness could not fetch them. The rule ids are the hub's; each rule names its public basis.";
      rules = [
        { id = "HVPS-BAH-REQUIRED"; families = HVPS_ALL; check = #requireHeader; basis = HVPS_PRACTICE },
        { id = "HVPS-MSGID-FINX"; families = ["pacs.008", "pacs.009", "pacs.002"]; check = #restrictedFinX("GrpHdr/MsgId"); basis = PMPG_CHARSET },
        { id = "HVPS-ONE-TX"; families = PACS_PAYMENTS; check = #exactOccurs("CdtTrfTxInf", 1); basis = HVPS_PRACTICE },
        { id = "HVPS-NBOFTXS-ONE"; families = PACS_PAYMENTS; check = #textEquals("GrpHdr/NbOfTxs", "1"); basis = HVPS_PRACTICE },
        { id = "HVPS-UETR-REQUIRED"; families = PACS_PAYMENTS; check = #requireElement("CdtTrfTxInf/PmtId/UETR"); basis = SWIFT_PROGRAMME },
        { id = "HVPS-STTLM-CLRG"; families = PACS_PAYMENTS; check = #codeIn("GrpHdr/SttlmInf/SttlmMtd", ["CLRG"]); basis = HVPS_PRACTICE },
        { id = "HVPS-CLRSYS-REQUIRED"; families = PACS_PAYMENTS; check = #requireElement("GrpHdr/SttlmInf/ClrSys"); basis = HVPS_PRACTICE },
        { id = "HVPS-STTLM-DT-REQUIRED"; families = PACS_PAYMENTS; check = #requireElement("CdtTrfTxInf/IntrBkSttlmDt"); basis = HVPS_PRACTICE },
        { id = "HVPS-INSTG-AGT-REQUIRED"; families = PACS_PAYMENTS; check = #requireElement("GrpHdr/InstgAgt"); basis = HVPS_PRACTICE },
        { id = "HVPS-INSTD-AGT-REQUIRED"; families = PACS_PAYMENTS; check = #requireElement("GrpHdr/InstdAgt"); basis = HVPS_PRACTICE },
        { id = "HVPS-E2E-FINX"; families = PACS_PAYMENTS; check = #restrictedFinX("CdtTrfTxInf/PmtId/EndToEndId"); basis = PMPG_CHARSET },
        { id = "HVPS-STS-ONE-TX"; families = ["pacs.002"]; check = #exactOccurs("TxInfAndSts", 1); basis = HVPS_PRACTICE },
        { id = "HVPS-STS-ORGNL-UETR"; families = ["pacs.002"]; check = #requireElement("TxInfAndSts/OrgnlUETR"); basis = SWIFT_PROGRAMME },
        { id = "HVPS-LQDTY-ID"; families = ["camt.050"]; check = #requireElement("LqdtyCdtTrf/LqdtyTrfId/EndToEndId"); basis = HVPS_PRACTICE },
        { id = "HVPS-LQDTY-CCY"; families = ["camt.050"]; check = #requireElement("LqdtyCdtTrf/TrfdAmt/AmtWthCcy"); basis = HVPS_PRACTICE },
        { id = "HVPS-LQDTY-ACCOUNTS"; families = ["camt.050"]; check = #requireElement("LqdtyCdtTrf/CdtrAcct"); basis = HVPS_PRACTICE },
        { id = "HVPS-RPT-ONE"; families = ["camt.052"]; check = #exactOccurs("Rpt", 1); basis = HVPS_PRACTICE },
        { id = "HVPS-RPT-BALANCE"; families = ["camt.052"]; check = #requireElement("Rpt/Bal"); basis = HVPS_PRACTICE },
        { id = "HVPS-STMT-ONE"; families = ["camt.053"]; check = #exactOccurs("Stmt", 1); basis = HVPS_PRACTICE },
        { id = "HVPS-STMT-BALANCES"; families = ["camt.053"]; check = #codesInclude("Stmt/Bal/Tp/CdOrPrtry/Cd", ["OPBD", "CLBD"]); basis = HVPS_PRACTICE },
      ];
    }
  };

  public func all() : [RuleSet] { [cbprPlus(), hvpsPlus()] };
  public func byId(id : Text) : ?RuleSet { for (rs in all().vals()) { if (rs.id == id) return ?rs }; null };

  /// A check as text, for the printed tables.
  public func checkText(c : Check) : Text {
    switch (c) {
      case (#requireElement(p)) "require " # p;
      case (#forbidElement(p)) "forbid " # p;
      case (#exactOccurs(p, n)) p # " occurs exactly " # Nat.toText(n);
      case (#maxOccurs(p, n)) p # " occurs at most " # Nat.toText(n);
      case (#textEquals(p, v)) p # " = '" # v # "'";
      case (#codeIn(p, cs)) p # " in {" # Text.join(cs.vals(), ", ") # "}";
      case (#codesInclude(p, cs)) p # " includes {" # Text.join(cs.vals(), ", ") # "}";
      case (#maxLength(p, n)) p # " at most " # Nat.toText(n) # " characters";
      case (#restrictedFinX(p)) p # " in the FIN X character set, no leading '/', no '//'";
      case (#agentIdentified(p)) p # " identified by BICFI, clearing member id, or name and address";
      case (#addressStructuredOrHybrid(p)) p # " structured or hybrid (TwnNm, Ctry, at most two AdrLine)";
      case (#requireHeader) "the head.001 AppHdr travels with the Document";
    }
  };
}
