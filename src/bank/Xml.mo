/// Xml.mo: a conforming-enough XML 1.0 parser for ISO 20022 business messages, with stable rule ids.
///
/// The payments component reads messages from the network; what it accepts is what this parser
/// builds. It is a real parser; a tree of elements with their namespaces, attributes and text;
/// not a tag scanner, and every way a document can be malformed that matters to a conforming
/// consumer is a refusal with a rule id the integration kit can test against:
///
///   XML-DECL-POSITION   an XML declaration anywhere but the very first bytes (after whitespace, a
///                       comment, an element; the defect the compact codec had)
///   XML-DECL-DUPLICATE  a second declaration
///   XML-DECL-ENCODING   a declaration naming an encoding other than UTF-8
///   XML-BOM-POSITION    a byte-order mark after the first byte
///   XML-UNSAFE-DECL     a DOCTYPE or any declaration (`<!…` other than a comment or CDATA)
///   XML-PI              a processing instruction
///   XML-UTF8            bytes that are not UTF-8
///   XML-CHAR            a character not allowed in content or an unescaped `<` / `&`
///   XML-ENTITY          a reference other than the five predefined ones and numeric ones
///   XML-NAME            an element or attribute name that is not a name
///   XML-ATTRIBUTE       a malformed or duplicated attribute
///   XML-TAG-MISMATCH    an end tag that does not close the open element
///   XML-UNCLOSED        the document ends inside an element
///   XML-ROOT            no root element, or content after it (in single-document mode)
///   XML-NAMESPACE       an undeclared prefix
///   XML-SIZE            a document over the size cap
///
/// Comments and CDATA sections are content. Whitespace between elements is dropped where an
/// element has child elements (ISO 20022 has no mixed content); an element's `text` is exactly its
/// character data otherwise. Two top-level elements; a Business Application Header followed by a
/// Document, the way a SWIFT business message is carried; are accepted by `parseMessage`, which
/// is the one place a document with more than one root is admitted, and it says so.

import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Char "mo:core/Char";
import List "mo:core/List";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Nat32 "mo:core/Nat32";
import Result "mo:core/Result";
import Text "mo:core/Text";

module {

  public type Element = {
    /// The local name and the resolved namespace (empty when none is in scope).
    name : Text;
    namespace : Text;
    /// Attributes other than namespace declarations, in document order: (name, value).
    attributes : [(Text, Text)];
    children : [Element];
    /// The character data, with references resolved. Empty when the element has child elements.
    text : Text;
    /// Byte offset of the start tag, for diagnostics.
    offset : Nat;
  };

  public type Issue = { rule : Text; offset : Nat; detail : Text };

  public let MAX_BYTES : Nat = 1_000_000;

  /// One document: exactly one root element.
  public func parse(bytes : Blob) : Result.Result<Element, Issue> {
    switch (parseRoots(bytes, false)) { case (#ok(roots)) #ok(roots[0]); case (#err(e)) #err(e) }
  };

  /// A business message: one root element, or a header element followed by the document element.
  public func parseMessage(bytes : Blob) : Result.Result<[Element], Issue> { parseRoots(bytes, true) };

  func parseRoots(blob : Blob, allowTwo : Bool) : Result.Result<[Element], Issue> {
    if (blob.size() > MAX_BYTES) return #err({ rule = "XML-SIZE"; offset = 0; detail = "document of " # Nat.toText(blob.size()) # " bytes exceeds the cap of " # Nat.toText(MAX_BYTES) });
    // UTF-8 is checked once, whole; the scanner then works on bytes and decodes slices
    switch (Text.decodeUtf8(blob)) { case null return #err({ rule = "XML-UTF8"; offset = 0; detail = "the document is not UTF-8" }); case (?_) {} };
    let b = Blob.toArray(blob);
    let n = b.size();
    var pos = 0;
    var sawDecl = false;
    var issue : ?Issue = null;

    func fail(rule : Text, at : Nat, detail : Text) { if (issue == null) issue := ?{ rule; offset = at; detail } };
    func at(i : Nat) : Nat8 { if (i < n) b[i] else 0 };
    func startsWith(i : Nat, s : Text) : Bool {
      var j = i;
      for (c in s.chars()) { if (j >= n or Nat32.toNat(Char.toNat32(c)) != Nat8.toNat(b[j])) return false; j += 1 };
      true
    };
    func isSpace(c : Nat8) : Bool { c == 0x20 or c == 0x09 or c == 0x0A or c == 0x0D };
    func isNameStart(c : Nat8) : Bool { (c >= 0x41 and c <= 0x5A) or (c >= 0x61 and c <= 0x7A) or c == 0x5F or c == 0x3A or c >= 0x80 };
    func isNameChar(c : Nat8) : Bool { isNameStart(c) or (c >= 0x30 and c <= 0x39) or c == 0x2D or c == 0x2E };
    func slice(from : Nat, to : Nat) : Text {
      switch (Text.decodeUtf8(Blob.fromArray(Array.tabulate<Nat8>(to - from, func(i) { b[from + i] })))) { case (?t) t; case null "" }
    };
    func skipSpace() { while (pos < n and isSpace(b[pos])) pos += 1 };

    // the byte-order mark: allowed at byte 0 only
    if (startsWith(0, "\u{EF}\u{BB}\u{BF}")) pos := 3;
    // the declaration: allowed right here only
    if (startsWith(pos, "<?xml") and (isSpace(at(pos + 5)))) {
      let start = pos;
      pos += 5;
      var end : ?Nat = null;
      label d loop { if (pos + 1 >= n) break d; if (b[pos] == 0x3F and b[pos + 1] == 0x3E) { end := ?pos; break d }; pos += 1 };
      switch (end) {
        case null return #err({ rule = "XML-UNCLOSED"; offset = start; detail = "the declaration is not closed" });
        case (?e) {
          let decl = slice(start, e);
          if (Text.contains(decl, #text "encoding=")) {
            let ok = Text.contains(decl, #text "encoding=\"UTF-8\"") or Text.contains(decl, #text "encoding='UTF-8'") or Text.contains(decl, #text "encoding=\"utf-8\"") or Text.contains(decl, #text "encoding='utf-8'");
            if (not ok) return #err({ rule = "XML-DECL-ENCODING"; offset = start; detail = "a declared encoding other than UTF-8" });
          };
          pos := e + 2;
          sawDecl := true;
        };
      };
    };

    func name() : ?Text {
      let start = pos;
      if (pos >= n or not isNameStart(b[pos])) return null;
      pos += 1;
      while (pos < n and isNameChar(b[pos])) pos += 1;
      ?slice(start, pos)
    };

    /// Character data with references resolved, up to `stop` (a byte); returns null on a bad reference.
    func resolve(raw : Text, offset : Nat) : ?Text {
      if (not Text.contains(raw, #text "&")) return ?raw;
      var out = "";
      var ent : ?Text = null;
      for (c in raw.chars()) {
        switch (ent) {
          case (?e) {
            if (c == ';') {
              let v : ?Text = switch (e) {
                case ("lt") ?"<"; case ("gt") ?">"; case ("amp") ?"&"; case ("quot") ?"\""; case ("apos") ?"'";
                case (_) {
                  if (Text.startsWith(e, #text "#x")) { numeric(Text.trimStart(e, #text "#x"), 16) }
                  else if (Text.startsWith(e, #text "#")) { numeric(Text.trimStart(e, #text "#"), 10) }
                  else null
                };
              };
              switch (v) { case (?t) { out #= t; ent := null }; case null { fail("XML-ENTITY", offset, "undefined entity &" # e # ";"); return null } };
            } else { ent := ?(e # Char.toText(c)); if (Text.size(e) > 8) { fail("XML-ENTITY", offset, "unterminated entity reference"); return null } };
          };
          case null { if (c == '&') ent := ?"" else out #= Char.toText(c) };
        };
      };
      if (ent != null) { fail("XML-ENTITY", offset, "unterminated entity reference"); return null };
      ?out
    };
    func numeric(digits : Text, base : Nat) : ?Text {
      if (Text.size(digits) == 0) return null;
      var v : Nat = 0;
      for (c in digits.chars()) {
        let d = if (Char.isDigit(c)) Nat32.toNat(Char.toNat32(c) - 48)
          else if (base == 16 and c >= 'a' and c <= 'f') Nat32.toNat(Char.toNat32(c) - 97 + 10)
          else if (base == 16 and c >= 'A' and c <= 'F') Nat32.toNat(Char.toNat32(c) - 65 + 10)
          else return null;
        if (d >= base) return null;
        v := v * base + d;
        if (v > 0x10FFFF) return null;
      };
      if (v == 0 or (v >= 0xD800 and v <= 0xDFFF)) return null;
      ?Char.toText(Char.fromNat32(Nat32.fromNat(v)))
    };

    /// Parse one element starting at `<`; `scope` is the namespace bindings in effect.
    func element(scope : [(Text, Text)]) : ?Element {
      let start = pos;
      pos += 1;   // '<'
      let ?qname = name() else { fail("XML-NAME", start, "a start tag without a name"); return null };
      let attrs = List.empty<(Text, Text)>();
      let bindings = List.fromArray<(Text, Text)>(scope);
      var selfClosing = false;
      label attributes loop {
        let before = pos;
        skipSpace();
        if (pos >= n) { fail("XML-UNCLOSED", start, "the document ends inside a start tag"); return null };
        if (b[pos] == 0x3E) { pos += 1; break attributes };
        if (b[pos] == 0x2F) { if (at(pos + 1) == 0x3E) { pos += 2; selfClosing := true; break attributes } else { fail("XML-ATTRIBUTE", pos, "a stray / in a start tag"); return null } };
        if (b[pos] == 0x3C) { fail("XML-CHAR", pos, "< inside a start tag"); return null };
        if (pos == before) { fail("XML-ATTRIBUTE", pos, "attributes must be separated by whitespace"); return null };
        let aStart = pos;
        let ?aname = name() else { fail("XML-ATTRIBUTE", pos, "an attribute without a name"); return null };
        skipSpace();
        if (at(pos) != 0x3D) { fail("XML-ATTRIBUTE", aStart, "attribute " # aname # " without ="); return null };
        pos += 1;
        skipSpace();
        let q = at(pos);
        if (q != 0x22 and q != 0x27) { fail("XML-ATTRIBUTE", aStart, "attribute " # aname # " value not quoted"); return null };
        pos += 1;
        let vStart = pos;
        while (pos < n and b[pos] != q) { if (b[pos] == 0x3C) { fail("XML-CHAR", pos, "< in an attribute value"); return null }; pos += 1 };
        if (pos >= n) { fail("XML-UNCLOSED", aStart, "the document ends inside an attribute value"); return null };
        let ?value = resolve(slice(vStart, pos), vStart) else return null;
        pos += 1;
        for ((k, _) in List.values(attrs)) { if (k == aname) { fail("XML-ATTRIBUTE", aStart, "attribute " # aname # " repeated"); return null } };
        if (aname == "xmlns") List.add(bindings, ("", value))
        else if (Text.startsWith(aname, #text "xmlns:")) List.add(bindings, (Text.trimStart(aname, #text "xmlns:"), value))
        else List.add(attrs, (aname, value));
      };
      let scopeNow = List.toArray(bindings);
      func resolveNs(q : Text) : ?(Text, Text) {
        let parts = Array.fromIter<Text>(Text.split(q, #char ':'));
        let (prefix, local) = if (parts.size() == 2) (parts[0], parts[1]) else ("", q);
        var found : ?Text = null;
        // the innermost binding wins: walk from the end
        var i = scopeNow.size();
        while (i > 0 and found == null) { i -= 1; if (scopeNow[i].0 == prefix) found := ?scopeNow[i].1 };
        switch (found) {
          case (?ns) ?(local, ns);
          case null { if (prefix == "") ?(local, "") else null };
        }
      };
      let ?(local, ns) = resolveNs(qname) else { fail("XML-NAMESPACE", start, "undeclared prefix in " # qname); return null };
      if (selfClosing) return ?{ name = local; namespace = ns; attributes = List.toArray(attrs); children = []; text = ""; offset = start };
      // content
      let kids = List.empty<Element>();
      var text = "";
      label content loop {
        if (pos >= n) { fail("XML-UNCLOSED", start, "the document ends inside <" # qname # ">"); return null };
        if (b[pos] == 0x3C) {
          if (startsWith(pos, "</")) {
            let eStart = pos;
            pos += 2;
            let ?ename = name() else { fail("XML-NAME", eStart, "an end tag without a name"); return null };
            skipSpace();
            if (at(pos) != 0x3E) { fail("XML-TAG-MISMATCH", eStart, "malformed end tag"); return null };
            pos += 1;
            if (ename != qname) { fail("XML-TAG-MISMATCH", eStart, "</" # ename # "> closes <" # qname # ">"); return null };
            break content;
          } else if (startsWith(pos, "<!--")) {
            let cStart = pos;
            pos += 4;
            label c loop { if (pos + 2 >= n) { fail("XML-UNCLOSED", cStart, "unterminated comment"); return null }; if (startsWith(pos, "-->")) { pos += 3; break c }; pos += 1 };
          } else if (startsWith(pos, "<![CDATA[")) {
            let cStart = pos;
            pos += 9;
            let dStart = pos;
            label c loop { if (pos + 2 >= n) { fail("XML-UNCLOSED", cStart, "unterminated CDATA section"); return null }; if (startsWith(pos, "]]>")) break c; pos += 1 };
            text #= slice(dStart, pos);
            pos += 3;
          } else if (startsWith(pos, "<?")) {
            if (startsWith(pos, "<?xml") and isSpace(at(pos + 5))) { fail("XML-DECL-POSITION", pos, "an XML declaration inside the document"); return null };
            fail("XML-PI", pos, "a processing instruction"); return null;
          } else if (startsWith(pos, "<!")) {
            fail("XML-UNSAFE-DECL", pos, "a declaration (DOCTYPE, ENTITY or other) is not allowed"); return null;
          } else {
            let ?child = element(scopeNow) else return null;
            List.add(kids, child);
          };
        } else {
          let tStart = pos;
          while (pos < n and b[pos] != 0x3C) {
            let c = b[pos];
            if (c < 0x20 and not isSpace(c)) { fail("XML-CHAR", pos, "a control character in content"); return null };
            pos += 1;
          };
          let ?piece = resolve(slice(tStart, pos), tStart) else return null;
          text #= piece;
        };
      };
      let children = List.toArray(kids);
      if (children.size() > 0) {
        // no mixed content: only whitespace may sit between child elements
        for (c in text.chars()) { if (c != ' ' and c != '\t' and c != '\n' and c != '\r') { fail("XML-CHAR", start, "text and child elements mixed in <" # qname # ">"); return null } };
        text := "";
      };
      ?{ name = local; namespace = ns; attributes = List.toArray(attrs); children; text; offset = start }
    };

    // the prolog after the declaration: whitespace and comments only, then the root(s)
    let roots = List.empty<Element>();
    label top loop {
      skipSpace();
      if (pos >= n) break top;
      if (startsWith(pos, "<!--")) {
        let cStart = pos; pos += 4;
        label c loop { if (pos + 2 >= n) return #err({ rule = "XML-UNCLOSED"; offset = cStart; detail = "unterminated comment" }); if (startsWith(pos, "-->")) { pos += 3; break c }; pos += 1 };
        continue top;
      };
      if (startsWith(pos, "\u{EF}\u{BB}\u{BF}")) return #err({ rule = "XML-BOM-POSITION"; offset = pos; detail = "a byte-order mark after the first byte" });
      if (startsWith(pos, "<?xml") and isSpace(at(pos + 5))) return #err({ rule = if (sawDecl) "XML-DECL-DUPLICATE" else "XML-DECL-POSITION"; offset = pos; detail = if (sawDecl) "a second XML declaration" else "an XML declaration not at the start of the document" });
      if (startsWith(pos, "<?")) return #err({ rule = "XML-PI"; offset = pos; detail = "a processing instruction" });
      if (startsWith(pos, "<!")) return #err({ rule = "XML-UNSAFE-DECL"; offset = pos; detail = "a declaration (DOCTYPE, ENTITY or other) is not allowed" });
      if (b[pos] != 0x3C) return #err({ rule = "XML-ROOT"; offset = pos; detail = "character data outside the root element" });
      if (List.size(roots) >= (if (allowTwo) 2 else 1)) return #err({ rule = "XML-ROOT"; offset = pos; detail = "content after the root element" });
      switch (element([])) {
        case (?e) List.add(roots, e);
        case null { switch (issue) { case (?i) return #err(i); case null return #err({ rule = "XML-UNCLOSED"; offset = pos; detail = "malformed element" }) } };
      };
    };
    if (List.size(roots) == 0) return #err({ rule = "XML-ROOT"; offset = pos; detail = "no root element" });
    #ok(List.toArray(roots))
  };

  // ─── reading a tree ───

  public func child(e : Element, name : Text) : ?Element { for (c in e.children.vals()) { if (c.name == name) return ?c }; null };
  public func children(e : Element, name : Text) : [Element] { Array.filter<Element>(e.children, func(c) { c.name == name }) };
  /// The element at a path of local names below `e`, the first match at each step.
  public func path(e : Element, names : [Text]) : ?Element {
    var cur = e;
    for (nm in names.vals()) { switch (child(cur, nm)) { case (?c) cur := c; case null return null } };
    ?cur
  };
  public func textAt(e : Element, names : [Text]) : ?Text { switch (path(e, names)) { case (?x) ?x.text; case null null } };
  public func attribute(e : Element, name : Text) : ?Text { for ((k, v) in e.attributes.vals()) { if (k == name) return ?v }; null };

  /// The text with its leading and trailing whitespace removed (XSD whitespace collapse for the
  /// non-string lexical types).
  public func trim(t : Text) : Text { Text.trim(t, #predicate(func(c : Char) : Bool { c == ' ' or c == '\t' or c == '\n' or c == '\r' })) };

  /// Escaping for the five reserved characters, for emitters.
  public func escape(t : Text) : Text {
    var out = "";
    for (c in t.chars()) {
      switch (c) { case ('&') out #= "&amp;"; case ('<') out #= "&lt;"; case ('>') out #= "&gt;"; case ('\u{22}') out #= "&quot;"; case ('\u{27}') out #= "&apos;"; case (_) out #= Char.toText(c) };
    };
    out
  };

  /// The element written back as a document: every element in its namespace (declared as the default
  /// namespace wherever it differs from the parent's), attributes and text escaped, no whitespace
  /// between elements. `parse(serialize(e))` reads back the same tree. Used to hand a payload of a
  /// business file (head.002) to the ingest as a message of its own.
  public func serialize(e : Element) : Text { "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" # serializeIn(e, "") };
  /// The element alone, without the declaration (a Document appended to its AppHdr).
  public func serializeBody(e : Element) : Text { serializeIn(e, "") };

  func serializeIn(e : Element, parentNs : Text) : Text {
    var out = "<" # e.name;
    if (e.namespace != parentNs) out #= " xmlns=\"" # escape(e.namespace) # "\"";
    for ((k, v) in e.attributes.vals()) out #= " " # k # "=\"" # escape(v) # "\"";
    if (e.children.size() == 0 and Text.size(e.text) == 0) return out # "/>";
    out #= ">";
    if (e.children.size() == 0) out #= escape(e.text)
    else { for (c in e.children.vals()) out #= serializeIn(c, e.namespace) };
    out # "</" # e.name # ">"
  };
}
