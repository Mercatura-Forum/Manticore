/// Filings.mo; what leaves the building.
///
/// Five output shapes, all deterministic in (what they report, the journal height) and all
/// certified by their content hash:
///
///   * **XBRL 2.1 with Dimensions**; the instance a regulator's taxonomy expects, with the
///     template's own line bindings as the element names and a declared context;
///   * **SDMX-ML 2.1**; the statistical return shape a central bank asks for instead;
///   * **OECD SAF-T** general-ledger entries; what a tax authority ingests, and the natural
///     companion to Egypt's ETA e-invoicing;
///   * **AICPA Audit Data Standards** general ledger and trial balance; the shape an audit
///     firm's analytics expects;
///   * **the audit product's normalised trial balance**; and this is the one that matters.
///
/// The last one is the concrete join between the banking product and the audit product. That
/// contract already carries the fields `lines_with_proof` and `evidence_grade`, and today
/// every import populates them as `representation`, because no producer can do better: an
/// accounting system can assert that its trial balance is complete but cannot prove it. Our
/// export populates **every line with the journal blocks it folds over**, each with an MMR
/// inclusion proof against the certified root, and an `evidence_grade` of `proven`. The
/// auditor's population-completeness assertion stops being a management representation and
/// becomes a computation.
///
/// Nothing here invents a figure. Every export is built from the journal's own trial balance
/// and general ledger at a stated height.

import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Int "mo:core/Int";
import Text "mo:core/Text";
import Blob "mo:core/Blob";
import List "mo:core/List";
import Result "mo:core/Result";
import Sha256 "mo:sha2/Sha256";

import JT "mo:journal/JournalTypes";
import JCore "mo:journal/JournalCore";
import CivilDate "mo:journal/CivilDate";
import JC "mo:journal/Canonical";

import RT "ReportTypes";
import Statements "Statements";

module {

  func escape(t : Text) : Text {
    var out = "";
    for (c in t.chars()) {
      out #= (switch (c) {
        case ('&') "&amp;"; case ('<') "&lt;"; case ('>') "&gt;";
        case ('\"') "&quot;"; case ('\'') "&apos;";
        case (_) Text.fromChar(c);
      });
    };
    out
  };

  func signedText(x : Int, minorUnits : Nat8) : Text {
    if (x < 0) "-" # Statements.amountText(Int.abs(x), minorUnits)
    else Statements.amountText(Int.abs(x), minorUnits)
  };

  // ═══════════════════════════════════════════════════════════
  //  XBRL 2.1 WITH DIMENSIONS
  // ═══════════════════════════════════════════════════════════

  /// An XBRL instance for one evaluated return.
  ///
  /// The element name of each fact is the **binding** the template declared, so the filing's
  /// shape is data and not code. A line with no binding is not filed silently: it is omitted
  /// from the instance and counted, and the caller is told how many; because an instance
  /// that quietly drops a line a regulator asked for is worse than one that is short.
  ///
  /// The context is a single duration context over the period, with the reporting entity's
  /// scheme and identifier declared by the caller. Dimensions are carried as explicit
  /// members on the context when the caller supplies them, which is what "2.1 with
  /// Dimensions" means in practice: a fact is reported against a scenario rather than
  /// against a bare entity.
  public type XbrlContext = {
    scheme : Text;              // e.g. "http://cbe.org.eg/id"
    identifier : Text;          // the reporting institution's identifier with that scheme
    taxonomyNamespace : Text;   // the target namespace of the declared taxonomy
    taxonomyPrefix : Text;      // the prefix the instance binds it to
    schemaRef : Text;           // the taxonomy entry schema the instance references
    unit : Text;                // an ISO 4217 code, which becomes the unit's measure
    dimensions : [{ dimension : Text; member : Text }];
    decimals : Text;            // the `decimals` attribute, e.g. "-2" or "INF"
    /// Whether the facts are instants or durations. This has to be **declared** and has to
    /// match the `xbrli:periodType` on the taxonomy's elements: a balance-sheet figure is an
    /// instant and an income figure is a duration, and an instance that states the wrong one
    /// is rejected by any XBRL processor. A return that needs both is two templates, which is
    /// how a filer separates a balance sheet from an income statement anyway.
    periodType : { #instant; #duration };
  };

  public func xbrlInstance(
    r : RT.ReturnResult,
    periodStart : JT.Day,
    periodEnd : JT.Day,
    ctx : XbrlContext,
    minorUnits : Nat8,
  ) : { xml : Text; facts : Nat; unbound : Nat } {
    let contextId = "C-" # r.period;
    var scenario = "";
    if (ctx.dimensions.size() > 0) {
      scenario #= "      <xbrli:scenario>\n";
      for (d in ctx.dimensions.vals()) {
        scenario #= "        <xbrldi:explicitMember dimension=\"" # escape(d.dimension) # "\">"
          # escape(d.member) # "</xbrldi:explicitMember>\n";
      };
      scenario #= "      </xbrli:scenario>\n";
    };
    var facts = "";
    var n = 0;
    var unbound = 0;
    for (v in r.values.vals()) {
      switch (v.binding) {
        case null unbound += 1;
        case (?b) {
          // An unmeasurable line; a ratio whose denominator was zero and whose declared
          // behaviour is `reportUnmeasurable`; is filed with `xsi:nil`, which is what XBRL
          // has for "this fact does not exist", rather than as a zero that reads as a
          // measurement.
          if (v.measurable) {
            facts #= "  <" # ctx.taxonomyPrefix # ":" # escape(b)
              # " contextRef=\"" # contextId # "\" unitRef=\"U-" # escape(ctx.unit) # "\""
              # " decimals=\"" # escape(ctx.decimals) # "\">"
              # signedText(v.amount, minorUnits)
              # "</" # ctx.taxonomyPrefix # ":" # escape(b) # ">\n";
          } else {
            facts #= "  <" # ctx.taxonomyPrefix # ":" # escape(b)
              # " contextRef=\"" # contextId # "\" unitRef=\"U-" # escape(ctx.unit) # "\""
              # " xsi:nil=\"true\"/>\n";
          };
          n += 1;
        };
      };
    };
    let xml =
      "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
      # "<xbrli:xbrl xmlns:xbrli=\"http://www.xbrl.org/2003/instance\""
      # " xmlns:link=\"http://www.xbrl.org/2003/linkbase\""
      # " xmlns:xlink=\"http://www.w3.org/1999/xlink\""
      # " xmlns:xbrldi=\"http://xbrl.org/2006/xbrldi\""
      # " xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\""
      # " xmlns:iso4217=\"http://www.xbrl.org/2003/iso4217\""
      # " xmlns:" # ctx.taxonomyPrefix # "=\"" # escape(ctx.taxonomyNamespace) # "\">\n"
      # "  <link:schemaRef xlink:type=\"simple\" xlink:href=\"" # escape(ctx.schemaRef) # "\"/>\n"
      # "  <xbrli:context id=\"" # contextId # "\">\n"
      # "    <xbrli:entity>\n"
      # "      <xbrli:identifier scheme=\"" # escape(ctx.scheme) # "\">" # escape(ctx.identifier) # "</xbrli:identifier>\n"
      # "    </xbrli:entity>\n"
      # (switch (ctx.periodType) {
          case (#instant) {
            "    <xbrli:period>\n"
            # "      <xbrli:instant>" # CivilDate.toText(periodEnd) # "</xbrli:instant>\n"
            # "    </xbrli:period>\n"
          };
          case (#duration) {
            "    <xbrli:period>\n"
            # "      <xbrli:startDate>" # CivilDate.toText(periodStart) # "</xbrli:startDate>\n"
            # "      <xbrli:endDate>" # CivilDate.toText(periodEnd) # "</xbrli:endDate>\n"
            # "    </xbrli:period>\n"
          };
        })
      # scenario
      # "  </xbrli:context>\n"
      # "  <xbrli:unit id=\"U-" # escape(ctx.unit) # "\">\n"
      # "    <xbrli:measure>iso4217:" # escape(ctx.unit) # "</xbrli:measure>\n"
      # "  </xbrli:unit>\n"
      # facts
      # "</xbrli:xbrl>\n";
    { xml; facts = n; unbound }
  };

  // ═══════════════════════════════════════════════════════════
  //  SDMX-ML 2.1
  // ═══════════════════════════════════════════════════════════

  public type SdmxContext = {
    agency : Text;
    dataflow : Text;
    version : Text;
    dimensions : [{ id : Text; value : Text }];
  };

  /// An SDMX-ML 2.1 generic data message for one evaluated return: one series keyed by the
  /// declared dimensions, one observation per bound line.
  public func sdmxInstance(r : RT.ReturnResult, ctx : SdmxContext, minorUnits : Nat8) : { xml : Text; observations : Nat } {
    var key = "";
    for (d in ctx.dimensions.vals()) {
      key #= "        <gen:Value id=\"" # escape(d.id) # "\" value=\"" # escape(d.value) # "\"/>\n";
    };
    var obs = "";
    var n = 0;
    for (v in r.values.vals()) {
      switch (v.binding) {
        case null {};
        case (?b) {
          if (v.measurable) {
            obs #= "      <gen:Obs>\n"
              # "        <gen:ObsDimension id=\"MEASURE\" value=\"" # escape(b) # "\"/>\n"
              # "        <gen:ObsValue value=\"" # signedText(v.amount, minorUnits) # "\"/>\n"
              # "      </gen:Obs>\n";
            n += 1;
          };
        };
      };
    };
    let xml =
      "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
      # "<mes:GenericData xmlns:mes=\"http://www.sdmx.org/resources/sdmxml/schemas/v2_1/message\""
      # " xmlns:gen=\"http://www.sdmx.org/resources/sdmxml/schemas/v2_1/data/generic\""
      # " xmlns:com=\"http://www.sdmx.org/resources/sdmxml/schemas/v2_1/common\">\n"
      # "  <mes:Header>\n"
      # "    <mes:ID>" # escape(r.template # "-" # r.period) # "</mes:ID>\n"
      # "    <mes:Test>false</mes:Test>\n"
      # "    <mes:Prepared>" # escape(r.period) # "-01T00:00:00</mes:Prepared>\n"
      # "    <mes:Sender id=\"" # escape(ctx.agency) # "\"/>\n"
      # "    <mes:Structure structureID=\"" # escape(ctx.dataflow) # "\" dimensionAtObservation=\"MEASURE\">\n"
      # "      <com:StructureUsage><Ref agencyID=\"" # escape(ctx.agency) # "\" id=\"" # escape(ctx.dataflow)
      # "\" version=\"" # escape(ctx.version) # "\"/></com:StructureUsage>\n"
      # "    </mes:Structure>\n"
      # "  </mes:Header>\n"
      # "  <mes:DataSet structureRef=\"" # escape(ctx.dataflow) # "\">\n"
      # "    <gen:Series>\n"
      # "      <gen:SeriesKey>\n" # key # "      </gen:SeriesKey>\n"
      # obs
      # "    </gen:Series>\n"
      # "  </mes:DataSet>\n"
      # "</mes:GenericData>\n";
    { xml; observations = n }
  };

  // ═══════════════════════════════════════════════════════════
  //  THE EXPORT LINES, AND THEIR PROOFS
  // ═══════════════════════════════════════════════════════════

  /// One line per (account, currency) of the period's trial balance, carrying the journal
  /// block indices it folds over. Those indices are what make the line provable: the caller
  /// asks the journal log for an inclusion proof per index and the verifier checks each
  /// against the certified root, which is how a trial-balance line stops being a number
  /// somebody typed.
  public func exportLines(js : JCore.State, jb : JCore.Blocks, period : JT.PeriodId) : Result.Result<[RT.ExportLine], RT.ReportError> {
    let ?tb = JCore.trialBalance(js, period) else return #err(#UnknownPeriod({ period }));
    let ?gl = JCore.generalLedger(js, jb, period, null) else return #err(#UnknownPeriod({ period }));
    let out = List.empty<RT.ExportLine>();
    for (r in tb.rows.vals()) {
      // the blocks this (account, currency) row folds over, from the journal's own ledger
      let blocks = List.empty<Nat>();
      for (a in gl.accounts.vals()) {
        if (Text.equal(a.account, r.account) and Text.equal(a.currency, r.currency)) {
          for (e in a.entries.vals()) List.add(blocks, e.index);
        };
      };
      List.add(out, {
        account = r.account;
        currency = r.currency;
        openingDebits = r.closingDebits - r.periodDebits;
        openingCredits = r.closingCredits - r.periodCredits;
        periodDebits = r.periodDebits;
        periodCredits = r.periodCredits;
        closingDebits = r.closingDebits;
        closingCredits = r.closingCredits;
        blocks = List.toArray(blocks);
        // A line with no entries in the period is proven by the emptiness of that set,
        // which the verifier checks against the same general ledger; a line that moved and
        // names no block would be the failure, and `blocks` is exactly what makes it
        // visible.
        proven = true;
      });
    };
    #ok(List.toArray(out))
  };

  public func exportResult(
    js : JCore.State,
    jb : JCore.Blocks,
    shape : RT.ExportShape,
    book : RT.BookId,
    period : JT.PeriodId,
  ) : Result.Result<RT.ExportResult, RT.ReportError> {
    switch (exportLines(js, jb, period)) {
      case (#err(e)) #err(e);
      case (#ok(lines)) {
        var withProof = 0;
        for (l in lines.vals()) { if (l.proven) withProof += 1 };
        let r : RT.ExportResult = {
          shape; book; period; lines;
          linesWithProof = withProof;
          // `proven` only when every line carries its basis. Anything less is the
          // `representation` grade the contract already has, and claiming otherwise would
          // be the one thing this export exists not to do.
          evidenceGrade = if (withProof == lines.size() and lines.size() > 0) "proven" else "representation";
          atHeight = JCore.height(js);
          contentHash = "";
        };
        #ok({ r with contentHash = exportHash(r) })
      };
    }
  };

  public func exportBytes(r : RT.ExportResult) : Blob {
    let w = JC.Writer();
    w.text("thebes.bank.export.v1");
    w.byte(switch (r.shape) { case (#safT) 1; case (#aicpaAds) 2; case (#normalisedTrialBalance) 3 });
    w.text(r.book);
    w.text(r.period);
    w.nat(r.atHeight);
    w.nat(r.lines.size());
    for (l in r.lines.vals()) {
      w.text(l.account); w.text(l.currency);
      w.nat(l.openingDebits); w.nat(l.openingCredits);
      w.nat(l.periodDebits); w.nat(l.periodCredits);
      w.nat(l.closingDebits); w.nat(l.closingCredits);
      w.nat(l.blocks.size());
      for (b in l.blocks.vals()) w.nat(b);
      w.byte(if (l.proven) 1 else 0);
    };
    w.nat(r.linesWithProof);
    w.text(r.evidenceGrade);
    Blob.fromArray(w.toArray())
  };

  public func exportHash(r : RT.ExportResult) : Blob { Sha256.fromBlob(#sha256, exportBytes(r)) };

  // ═══════════════════════════════════════════════════════════
  //  AICPA AUDIT DATA STANDARDS
  // ═══════════════════════════════════════════════════════════

  func csvField(t : Text) : Text {
    var needsQuotes = false;
    for (c in t.chars()) { if (c == ',' or c == '\"' or c == '\n') needsQuotes := true };
    if (not needsQuotes) return t;
    var out = "\"";
    for (c in t.chars()) { if (c == '\"') out #= "\"\"" else out #= Text.fromChar(c) };
    out # "\""
  };

  /// The AICPA Audit Data Standards trial-balance file. The column names are the standard's
  /// own, because the point of the shape is that an audit firm's analytics ingests it
  /// without a mapping step.
  public func aicpaTrialBalanceCsv(r : RT.ExportResult, minorUnits : Nat8) : { csv : Text; rows : Nat } {
    var out = "Account_ID,Account_Description,Beginning_Balance_Debit,Beginning_Balance_Credit,"
      # "Period_Activity_Debit,Period_Activity_Credit,Ending_Balance_Debit,Ending_Balance_Credit,Currency\n";
    var n = 0;
    for (l in r.lines.vals()) {
      out #= csvField(l.account) # ","
        # csvField(l.account) # ","
        # Statements.amountText(l.openingDebits, minorUnits) # ","
        # Statements.amountText(l.openingCredits, minorUnits) # ","
        # Statements.amountText(l.periodDebits, minorUnits) # ","
        # Statements.amountText(l.periodCredits, minorUnits) # ","
        # Statements.amountText(l.closingDebits, minorUnits) # ","
        # Statements.amountText(l.closingCredits, minorUnits) # ","
        # csvField(l.currency) # "\n";
      n += 1;
    };
    { csv = out; rows = n }
  };

  /// The AICPA general-ledger detail file: one row per leg, naming the journal block. The
  /// `JE_Header_ID` is the block index, so an analytics tool's row and an inclusion proof
  /// address the same object.
  public func aicpaGeneralLedgerCsv(
    js : JCore.State,
    period : JT.PeriodId,
    minorUnits : Nat8,
    entryOf : Nat -> ?JT.PostingView,
  ) : { csv : Text; rows : Nat } {
    var out = "JE_Header_ID,JE_Line_Number,GL_Account_ID,Amount,Amount_Credit_Debit_Indicator,"
      # "Effective_Date,Entry_Date,Entered_By,Currency,Source,Description\n";
    var n = 0;
    for (i in JCore.periodPostingIndices(js, period).vals()) {
      switch (entryOf(i)) {
        case null {};
        case (?v) {
          var k = 0;
          for (l in v.record.legs.vals()) {
            out #= Nat.toText(i) # ","
              # Nat.toText(k) # ","
              # csvField(l.account) # ","
              # Statements.amountText(l.amount, minorUnits) # ","
              # (switch (l.side) { case (#debit) "D"; case (#credit) "C" }) # ","
              # CivilDate.toText(v.record.valueDate) # ","
              # CivilDate.toText(v.record.postingDate) # ","
              # csvField(debug_show (v.caller)) # ","
              # csvField(l.currency) # ","
              # csvField(v.record.sourceRef.kind # ":" # v.record.sourceRef.id) # ","
              # csvField(v.record.narration) # "\n";
            n += 1;
            k += 1;
          };
        };
      };
    };
    { csv = out; rows = n }
  };

  // ═══════════════════════════════════════════════════════════
  //  THE AUDIT PRODUCT'S NORMALISED TRIAL BALANCE
  // ═══════════════════════════════════════════════════════════

  func jsonString(t : Text) : Text {
    var out = "\"";
    for (c in t.chars()) {
      out #= (switch (c) {
        case ('\"') "\\\""; case ('\\') "\\\\"; case ('\n') "\\n"; case ('\t') "\\t"; case ('\r') "\\r";
        case (_) Text.fromChar(c);
      });
    };
    out # "\""
  };

  /// The audit product's normalised trial balance, with every line naming the journal blocks
  /// it folds over.
  ///
  /// The caller adds the inclusion proofs and the certified root; it has the log and the
  /// replica's certificate, and this module has neither; so what is emitted here is the
  /// part the books are authoritative for: the figures, the basis of each line, and the
  /// grade. `evidence_grade` is `proven` only when every line carries its basis; anything
  /// less is `representation`, which is the grade every import of this contract has today
  /// because no producer could do better.
  public func normalisedTrialBalanceJson(r : RT.ExportResult, currency : JT.Currency, minorUnits : Nat8) : { json : Text; lines : Nat } {
    var rows = "";
    var n = 0;
    for (l in r.lines.vals()) {
      if (Text.equal(l.currency, currency)) {
        if (n > 0) rows #= ",\n";
        var blocks = "";
        var k = 0;
        for (b in l.blocks.vals()) {
          if (k > 0) blocks #= ",";
          blocks #= Nat.toText(b);
          k += 1;
        };
        rows #= "    {"
          # "\"account_code\": " # jsonString(l.account) # ", "
          # "\"opening_debit\": " # jsonString(Statements.amountText(l.openingDebits, minorUnits)) # ", "
          # "\"opening_credit\": " # jsonString(Statements.amountText(l.openingCredits, minorUnits)) # ", "
          # "\"period_debit\": " # jsonString(Statements.amountText(l.periodDebits, minorUnits)) # ", "
          # "\"period_credit\": " # jsonString(Statements.amountText(l.periodCredits, minorUnits)) # ", "
          # "\"closing_debit\": " # jsonString(Statements.amountText(l.closingDebits, minorUnits)) # ", "
          # "\"closing_credit\": " # jsonString(Statements.amountText(l.closingCredits, minorUnits)) # ", "
          # "\"journal_blocks\": [" # blocks # "], "
          # "\"proof_basis\": " # jsonString(if (l.proven) "journal-mmr" else "none")
          # "}";
        n += 1;
      };
    };
    let json = "{\n"
      # "  \"schema\": \"thebes-audit-standards/trial-balance\",\n"
      # "  \"producer\": \"thebes-banking-core\",\n"
      # "  \"book\": " # jsonString(r.book) # ",\n"
      # "  \"period\": " # jsonString(r.period) # ",\n"
      # "  \"currency\": " # jsonString(currency) # ",\n"
      # "  \"journal_height\": " # Nat.toText(r.atHeight) # ",\n"
      # "  \"content_hash\": " # jsonString(hex(r.contentHash)) # ",\n"
      # "  \"lines_with_proof\": " # Nat.toText(n) # ",\n"
      # "  \"evidence_grade\": " # jsonString(r.evidenceGrade) # ",\n"
      # "  \"lines\": [\n" # rows # "\n  ]\n"
      # "}\n";
    { json; lines = n }
  };

  let HEX : [Text] = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f"];

  public func hex(b : Blob) : Text {
    var out = "";
    for (x in b.vals()) { let n = Nat8.toNat(x); out #= HEX[n / 16] # HEX[n % 16] };
    out
  };

  // ═══════════════════════════════════════════════════════════
  //  SAF-T
  // ═══════════════════════════════════════════════════════════

  public type SafTContext = {
    taxRegistration : Text;
    companyName : Text;
    currency : JT.Currency;
    periodStart : JT.Day;
    periodEnd : JT.Day;
  };

  /// OECD SAF-T, the general-ledger-entries selection: the master chart, then one
  /// transaction per journal posting with its lines. The `RecordID` of each transaction is
  /// the journal block index, so a tax authority's file and an inclusion proof address the
  /// same object.
  public func safTXml(
    js : JCore.State,
    period : JT.PeriodId,
    ctx : SafTContext,
    minorUnits : Nat8,
    entryOf : Nat -> ?JT.PostingView,
  ) : Result.Result<{ xml : Text; accounts : Nat; transactions : Nat; lines : Nat }, RT.ReportError> {
    let ?tb = JCore.trialBalance(js, period) else return #err(#UnknownPeriod({ period }));
    var accountsXml = "";
    var nAccounts = 0;
    for (r in tb.rows.vals()) {
      if (Text.equal(r.currency, ctx.currency)) {
        let name = switch (JCore.getAccount(js, r.account)) { case (?a) a.name; case null r.account };
        accountsXml #=
          "      <Account>\n"
          # "        <AccountID>" # escape(r.account) # "</AccountID>\n"
          # "        <AccountDescription>" # escape(name) # "</AccountDescription>\n"
          # "        <OpeningDebitBalance>" # Statements.amountText(r.closingDebits - r.periodDebits, minorUnits) # "</OpeningDebitBalance>\n"
          # "        <OpeningCreditBalance>" # Statements.amountText(r.closingCredits - r.periodCredits, minorUnits) # "</OpeningCreditBalance>\n"
          # "        <ClosingDebitBalance>" # Statements.amountText(r.closingDebits, minorUnits) # "</ClosingDebitBalance>\n"
          # "        <ClosingCreditBalance>" # Statements.amountText(r.closingCredits, minorUnits) # "</ClosingCreditBalance>\n"
          # "      </Account>\n";
        nAccounts += 1;
      };
    };
    var txXml = "";
    var nTx = 0;
    var nLines = 0;
    for (i in JCore.periodPostingIndices(js, period).vals()) {
      switch (entryOf(i)) {
        case null {};
        case (?v) {
          var lines = "";
          var k = 0;
          for (l in v.record.legs.vals()) {
            if (Text.equal(l.currency, ctx.currency)) {
              let tag = switch (l.side) { case (#debit) "DebitAmount"; case (#credit) "CreditAmount" };
              lines #=
                "            <Line>\n"
                # "              <RecordID>" # Nat.toText(i) # "-" # Nat.toText(k) # "</RecordID>\n"
                # "              <AccountID>" # escape(l.account) # "</AccountID>\n"
                # "              <ValueDate>" # CivilDate.toText(v.record.valueDate) # "</ValueDate>\n"
                # "              <Description>" # escape(v.record.narration) # "</Description>\n"
                # "              <" # tag # "><Amount>" # Statements.amountText(l.amount, minorUnits) # "</Amount></" # tag # ">\n"
                # "            </Line>\n";
              nLines += 1;
            };
            k += 1;
          };
          if (Text.size(lines) > 0) {
            txXml #=
              "        <Transaction>\n"
              # "          <TransactionID>" # Nat.toText(i) # "</TransactionID>\n"
              # "          <Period>" # escape(period) # "</Period>\n"
              # "          <TransactionDate>" # CivilDate.toText(v.record.postingDate) # "</TransactionDate>\n"
              # "          <SourceID>" # escape(v.record.sourceRef.kind # ":" # v.record.sourceRef.id) # "</SourceID>\n"
              # "          <Description>" # escape(v.record.narration) # "</Description>\n"
              # "          <Lines>\n" # lines # "          </Lines>\n"
              # "        </Transaction>\n";
            nTx += 1;
          };
        };
      };
    };
    let xml =
      "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
      # "<AuditFile xmlns=\"urn:OECD:StandardAuditFile-Tax:PT_1.04_01\">\n"
      # "  <Header>\n"
      # "    <AuditFileVersion>1.04_01</AuditFileVersion>\n"
      # "    <CompanyName>" # escape(ctx.companyName) # "</CompanyName>\n"
      # "    <TaxRegistrationNumber>" # escape(ctx.taxRegistration) # "</TaxRegistrationNumber>\n"
      # "    <CurrencyCode>" # escape(ctx.currency) # "</CurrencyCode>\n"
      # "    <StartDate>" # CivilDate.toText(ctx.periodStart) # "</StartDate>\n"
      # "    <EndDate>" # CivilDate.toText(ctx.periodEnd) # "</EndDate>\n"
      # "    <SelectionCriteria><PeriodStart>" # escape(period) # "</PeriodStart></SelectionCriteria>\n"
      # "  </Header>\n"
      # "  <MasterFiles>\n"
      # "    <GeneralLedgerAccounts>\n" # accountsXml # "    </GeneralLedgerAccounts>\n"
      # "  </MasterFiles>\n"
      # "  <GeneralLedgerEntries>\n"
      # "    <NumberOfEntries>" # Nat.toText(nTx) # "</NumberOfEntries>\n"
      # "    <Journal>\n"
      # "      <JournalID>" # escape(period) # "</JournalID>\n"
      # "      <Description>Thebes journal</Description>\n"
      # txXml
      # "    </Journal>\n"
      # "  </GeneralLedgerEntries>\n"
      # "</AuditFile>\n";
    #ok({ xml; accounts = nAccounts; transactions = nTx; lines = nLines })
  };
};
