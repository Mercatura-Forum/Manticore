"""iso_instances.py — schema-valid ISO 20022 instances and their invalid mutations, for the profile
agreement check and the cross-parser corpus.

Every `valid_*` template is checked against the official XSD with `xmllint --schema` before it is used
before it is used; every mutation is applied mechanically so the harness, not a hand, decides what is
invalid. The mutations are the disagreements a schema-derived profile must catch: a required element
removed, an element out of order, an element the model does not have, an enumeration value, a
pattern, a length, a decimal's fraction digits, a date, a namespace, one element too many.
"""
import copy
import random
import re
import subprocess

NS = {
    "pacs.008.001.08": "urn:iso:std:iso:20022:tech:xsd:pacs.008.001.08",
    "pacs.009.001.08": "urn:iso:std:iso:20022:tech:xsd:pacs.009.001.08",
    "pacs.002.001.10": "urn:iso:std:iso:20022:tech:xsd:pacs.002.001.10",
    "pacs.004.001.09": "urn:iso:std:iso:20022:tech:xsd:pacs.004.001.09",
    "camt.053.001.08": "urn:iso:std:iso:20022:tech:xsd:camt.053.001.08",
    "camt.054.001.08": "urn:iso:std:iso:20022:tech:xsd:camt.054.001.08",
    "head.001.001.02": "urn:iso:std:iso:20022:tech:xsd:head.001.001.02",
}
DECL = '<?xml version="1.0" encoding="UTF-8"?>\n'


def uetr(rng):
    h = "%032x" % rng.getrandbits(128)
    return f"{h[:8]}-{h[8:12]}-4{h[13:16]}-{rng.choice('89ab')}{h[17:20]}-{h[20:32]}"


def amount(rng, minor_units=2, lo=100, hi=50_000_00):
    v = rng.randrange(lo, hi)
    return f"{v // 10 ** minor_units}.{v % 10 ** minor_units:0{minor_units}d}"


def valid_pacs008(rng, payer_bic, payee_bic, n_tx=1, ccy="EGP", msg_id=None, uetrs=None, amounts=None):
    txs = ""
    for i in range(n_tx):
        u = uetrs[i] if uetrs else uetr(rng)
        amt = amounts[i] if amounts else amount(rng)
        txs += f"""    <CdtTrfTxInf>
      <PmtId><EndToEndId>E2E-{rng.randrange(10**9)}</EndToEndId><UETR>{u}</UETR></PmtId>
      <IntrBkSttlmAmt Ccy="{ccy}">{amt}</IntrBkSttlmAmt>
      <IntrBkSttlmDt>2026-09-09</IntrBkSttlmDt>
      <ChrgBr>SLEV</ChrgBr>
      <Dbtr><Nm>Debtor {rng.randrange(1000)} &amp; Sons</Nm><PstlAdr><Ctry>EG</Ctry><AdrLine>1 Nile Corniche</AdrLine></PstlAdr></Dbtr>
      <DbtrAcct><Id><IBAN>EG380019000500000000263180002</IBAN></Id></DbtrAcct>
      <DbtrAgt><FinInstnId><BICFI>{payer_bic}</BICFI></FinInstnId></DbtrAgt>
      <CdtrAgt><FinInstnId><BICFI>{payee_bic}</BICFI></FinInstnId></CdtrAgt>
      <Cdtr><Nm>Creditor {rng.randrange(1000)}</Nm></Cdtr>
      <CdtrAcct><Id><Othr><Id>ACC{rng.randrange(10**8)}</Id></Othr></Id></CdtrAcct>
      <RmtInf><Ustrd>invoice {rng.randrange(10**6)}</Ustrd></RmtInf>
    </CdtTrfTxInf>
"""
    mid = msg_id or f"MSG{rng.randrange(10**12)}"
    return f"""{DECL}<Document xmlns="{NS['pacs.008.001.08']}">
  <FIToFICstmrCdtTrf>
    <GrpHdr>
      <MsgId>{mid}</MsgId>
      <CreDtTm>2026-09-09T10:00:00Z</CreDtTm>
      <NbOfTxs>{n_tx}</NbOfTxs>
      <SttlmInf><SttlmMtd>CLRG</SttlmMtd></SttlmInf>
    </GrpHdr>
{txs}  </FIToFICstmrCdtTrf>
</Document>
"""


def valid_pacs009(rng, payer_bic, payee_bic, ccy="EGP", msg_id=None, u=None, amt=None):
    u = u or uetr(rng)
    return f"""{DECL}<Document xmlns="{NS['pacs.009.001.08']}">
  <FICdtTrf>
    <GrpHdr>
      <MsgId>{msg_id or f"FI{rng.randrange(10**12)}"}</MsgId>
      <CreDtTm>2026-09-09T10:00:00Z</CreDtTm>
      <NbOfTxs>1</NbOfTxs>
      <SttlmInf><SttlmMtd>CLRG</SttlmMtd></SttlmInf>
    </GrpHdr>
    <CdtTrfTxInf>
      <PmtId><InstrId>I{rng.randrange(10**9)}</InstrId><EndToEndId>E{rng.randrange(10**9)}</EndToEndId><UETR>{u}</UETR></PmtId>
      <IntrBkSttlmAmt Ccy="{ccy}">{amt or amount(rng)}</IntrBkSttlmAmt>
      <IntrBkSttlmDt>2026-09-09</IntrBkSttlmDt>
      <Dbtr><FinInstnId><BICFI>{payer_bic}</BICFI></FinInstnId></Dbtr>
      <Cdtr><FinInstnId><BICFI>{payee_bic}</BICFI></FinInstnId></Cdtr>
    </CdtTrfTxInf>
  </FICdtTrf>
</Document>
"""


def valid_pacs002(rng, original_msg_id, items, msg_id=None):
    """items: [(uetr, status, reason_code_or_None, orgnl_tx_id_or_None)]"""
    body = ""
    for u, st, rsn, txid in items:
        body += "    <TxInfAndSts>\n"
        if txid:
            body += f"      <OrgnlTxId>{txid}</OrgnlTxId>\n"
        body += f"      <OrgnlUETR>{u}</OrgnlUETR>\n      <TxSts>{st}</TxSts>\n"
        if rsn:
            body += f"      <StsRsnInf><Rsn><Cd>{rsn}</Cd></Rsn></StsRsnInf>\n"
        body += "    </TxInfAndSts>\n"
    return f"""{DECL}<Document xmlns="{NS['pacs.002.001.10']}">
  <FIToFIPmtStsRpt>
    <GrpHdr>
      <MsgId>{msg_id or f"ST{rng.randrange(10**12)}"}</MsgId>
      <CreDtTm>2026-09-09T10:05:00Z</CreDtTm>
    </GrpHdr>
    <OrgnlGrpInfAndSts>
      <OrgnlMsgId>{original_msg_id}</OrgnlMsgId>
      <OrgnlMsgNmId>pacs.008.001.08</OrgnlMsgNmId>
    </OrgnlGrpInfAndSts>
{body}  </FIToFIPmtStsRpt>
</Document>
"""


def valid_pacs004(rng, items, msg_id=None):
    """items: [(return_id, original_uetr, amount_text, ccy)]"""
    body = ""
    for rid, u, amt, ccy in items:
        body += f"""    <TxInf>
      <RtrId>{rid}</RtrId>
      <OrgnlUETR>{u}</OrgnlUETR>
      <RtrdIntrBkSttlmAmt Ccy="{ccy}">{amt}</RtrdIntrBkSttlmAmt>
      <RtrRsnInf><Rsn><Cd>AC04</Cd></Rsn></RtrRsnInf>
    </TxInf>
"""
    return f"""{DECL}<Document xmlns="{NS['pacs.004.001.09']}">
  <PmtRtr>
    <GrpHdr>
      <MsgId>{msg_id or f"RT{rng.randrange(10**12)}"}</MsgId>
      <CreDtTm>2026-09-09T11:00:00Z</CreDtTm>
      <NbOfTxs>{len(items)}</NbOfTxs>
      <SttlmInf><SttlmMtd>CLRG</SttlmMtd></SttlmInf>
    </GrpHdr>
{body}  </PmtRtr>
</Document>
"""


def valid_camt053(rng, n_entries=2):
    entries = ""
    for i in range(n_entries):
        cd = rng.choice(["CRDT", "DBIT"])
        entries += f"""      <Ntry>
        <NtryRef>NTRY-{i}</NtryRef>
        <Amt Ccy="EGP">{amount(rng)}</Amt>
        <CdtDbtInd>{cd}</CdtDbtInd>
        <Sts><Cd>BOOK</Cd></Sts>
        <BookgDt><Dt>2026-09-0{1 + i % 9}</Dt></BookgDt>
        <ValDt><Dt>2026-09-0{1 + i % 9}</Dt></ValDt>
        <AcctSvcrRef>{rng.randrange(10**6)}</AcctSvcrRef>
        <BkTxCd><Prtry><Cd>PMNT</Cd></Prtry></BkTxCd>
        <NtryDtls><TxDtls><Refs><UETR>{uetr(rng)}</UETR></Refs></TxDtls></NtryDtls>
      </Ntry>
"""
    return f"""{DECL}<Document xmlns="{NS['camt.053.001.08']}">
  <BkToCstmrStmt>
    <GrpHdr><MsgId>STM{rng.randrange(10**12)}</MsgId><CreDtTm>2026-09-30T23:59:59Z</CreDtTm></GrpHdr>
    <Stmt>
      <Id>2026-09-{rng.randrange(1000)}</Id>
      <CreDtTm>2026-09-30T23:59:59Z</CreDtTm>
      <FrToDt><FrDtTm>2026-09-01T00:00:00Z</FrDtTm><ToDtTm>2026-09-30T23:59:59Z</ToDtTm></FrToDt>
      <Acct><Id><Othr><Id>SET-EGP-{rng.randrange(1000)}</Id></Othr></Id><Ccy>EGP</Ccy></Acct>
      <Bal><Tp><CdOrPrtry><Cd>OPBD</Cd></CdOrPrtry></Tp><Amt Ccy="EGP">0.00</Amt><CdtDbtInd>CRDT</CdtDbtInd><Dt><Dt>2026-09-01</Dt></Dt></Bal>
      <Bal><Tp><CdOrPrtry><Cd>CLBD</Cd></CdOrPrtry></Tp><Amt Ccy="EGP">{amount(rng)}</Amt><CdtDbtInd>CRDT</CdtDbtInd><Dt><Dt>2026-09-30</Dt></Dt></Bal>
{entries}    </Stmt>
  </BkToCstmrStmt>
</Document>
"""


def valid_camt054(rng):
    return f"""{DECL}<Document xmlns="{NS['camt.054.001.08']}">
  <BkToCstmrDbtCdtNtfctn>
    <GrpHdr><MsgId>NTF{rng.randrange(10**12)}</MsgId><CreDtTm>2026-09-09T12:00:00Z</CreDtTm></GrpHdr>
    <Ntfctn>
      <Id>NTF-{rng.randrange(10**6)}</Id>
      <CreDtTm>2026-09-09T12:00:00Z</CreDtTm>
      <Acct><Id><IBAN>EG380019000500000000263180002</IBAN></Id><Ccy>EGP</Ccy></Acct>
      <Ntry>
        <NtryRef>NTRY-1</NtryRef>
        <Amt Ccy="EGP">{amount(rng)}</Amt>
        <CdtDbtInd>CRDT</CdtDbtInd>
        <Sts><Cd>BOOK</Cd></Sts>
        <BookgDt><Dt>2026-09-09</Dt></BookgDt>
        <AcctSvcrRef>{rng.randrange(10**6)}</AcctSvcrRef>
        <BkTxCd><Prtry><Cd>PMNT</Cd></Prtry></BkTxCd>
      </Ntry>
    </Ntfctn>
  </BkToCstmrDbtCdtNtfctn>
</Document>
"""


def valid_head001(rng, from_bic, to_bic, msg_def="pacs.008.001.08"):
    return f"""<AppHdr xmlns="{NS['head.001.001.02']}">
  <Fr><FIId><FinInstnId><BICFI>{from_bic}</BICFI></FinInstnId></FIId></Fr>
  <To><FIId><FinInstnId><BICFI>{to_bic}</BICFI></FinInstnId></FIId></To>
  <BizMsgIdr>BIZ{rng.randrange(10**12)}</BizMsgIdr>
  <MsgDefIdr>{msg_def}</MsgDefIdr>
  <CreDt>2026-09-09T10:00:00Z</CreDt>
</AppHdr>
"""


# ─── mutations: each returns (label, xml) or None when the template has no such element ───

def _sub1(xml, pattern, repl):
    new = re.sub(pattern, repl, xml, count=1, flags=re.S)
    return None if new == xml else new


def mutations(xml):
    """Schema-breaking mutations of a valid instance, mechanically applied."""
    out = []
    # a required element removed: MsgId / CreDtTm / an amount / a BIC
    for el in ("MsgId", "CreDtTm", "IntrBkSttlmAmt", "BICFI", "TxSts", "NbOfTxs", "Id", "Amt"):
        m = _sub1(xml, rf"<{el}(\s[^>]*)?>.*?</{el}>", "")
        if m:
            out.append((f"required {el} removed", m))
            break
    # order: CreDtTm before MsgId
    m = _sub1(xml, r"(<MsgId>[^<]*</MsgId>)\s*(<CreDtTm>[^<]*</CreDtTm>)", r"\2\1")
    if m: out.append(("MsgId and CreDtTm swapped", m))
    # an element the model does not have
    m = _sub1(xml, r"(<CreDtTm>[^<]*</CreDtTm>)", r"\1<Bogus>1</Bogus>")
    if m: out.append(("unknown element", m))
    # an enumeration value
    for el, bad in (("ChrgBr", "SLEX"), ("CdtDbtInd", "CRED"), ("SttlmMtd", "CLRX")):
        m = _sub1(xml, rf"<{el}>[A-Z]+</{el}>", f"<{el}>{bad}</{el}>")
        if m: out.append((f"{el} outside its enumeration", m)); break
    # a pattern: a lower-case BIC, a bad UETR
    m = _sub1(xml, r"<BICFI>([A-Z0-9]+)</BICFI>", lambda g: f"<BICFI>{g.group(1).lower()}</BICFI>")
    if m: out.append(("BICFI breaks the pattern", m))
    m = _sub1(xml, r"<UETR>([0-9a-f-]+)</UETR>", r"<UETR>not-a-uetr</UETR>")
    if m: out.append(("UETR breaks the pattern", m))
    m = _sub1(xml, r'Ccy="([A-Z]{3})"', 'Ccy="EGPX"')
    if m: out.append(("currency code breaks the pattern", m))
    # a length: MsgId of 36 characters
    m = _sub1(xml, r"<MsgId>[^<]*</MsgId>", "<MsgId>" + "M" * 36 + "</MsgId>")
    if m: out.append(("MsgId over 35 characters", m))
    # a decimal with six fraction digits, a negative one
    m = _sub1(xml, r'(<(?:IntrBkSttlmAmt|RtrdIntrBkSttlmAmt|Amt) Ccy="[A-Z]{3}">)[0-9.]+', r"\g<1>12.123456")
    if m: out.append(("amount with six fraction digits", m))
    m = _sub1(xml, r'(<(?:IntrBkSttlmAmt|RtrdIntrBkSttlmAmt|Amt) Ccy="[A-Z]{3}">)[0-9.]+', r"\g<1>-5.00")
    if m: out.append(("negative amount", m))
    # a date, a dateTime
    m = _sub1(xml, r"<CreDtTm>[^<]*</CreDtTm>", "<CreDtTm>2026-09-09 10:00:00</CreDtTm>")
    if m: out.append(("CreDtTm not a dateTime", m))
    m = _sub1(xml, r"<(IntrBkSttlmDt|Dt)>2026-09-(\d\d)</\1>", r"<\1>2026-13-\2</\1>")
    if m: out.append(("a date with month 13", m))
    # a namespace one version off
    m = _sub1(xml, r"\.001\.(\d\d)\"", lambda g: f'.001.{int(g.group(1)) - 1:02d}"')
    if m: out.append(("namespace one version off", m))
    # one element too many: a second GrpHdr
    m = _sub1(xml, r"(<GrpHdr>.*?</GrpHdr>)", r"\1\1")
    if m: out.append(("two GrpHdr", m))
    # an attribute the type does not declare
    m = _sub1(xml, r"<MsgId>", '<MsgId lang="en">')
    if m: out.append(("undeclared attribute", m))
    # text where children are expected
    m = _sub1(xml, r"<GrpHdr>", "<GrpHdr>stray text")
    if m: out.append(("text inside a sequence", m))
    # an empty Max35Text (minLength 1)
    for el in ("MsgId", "BizMsgIdr", "OrgnlMsgId", "Id", "RtrId"):
        m = _sub1(xml, rf"<{el}>[^<]+</{el}>", f"<{el}></{el}>")
        if m: out.append((f"empty {el}", m)); break
    # a status code over four characters
    m = _sub1(xml, r"<TxSts>[A-Z]{4}</TxSts>", "<TxSts>ACSCX</TxSts>")
    if m: out.append(("TxSts over 4 characters", m))
    # a leaf duplicated past maxOccurs 1
    for el in ("OrgnlMsgId", "TxSts", "BizMsgIdr", "MsgDefIdr", "CreDt", "NtryRef", "RtrId", "IntrBkSttlmDt"):
        m = _sub1(xml, rf"(<{el}>[^<]*</{el}>)", r"")
        if m: out.append((f"two {el}", m)); break
    # the header's sender and receiver swapped in order (To before Fr)
    m = _sub1(xml, r"(<Fr>.*?</Fr>)\s*(<To>.*?</To>)", r"")
    if m: out.append(("To before Fr", m))
    m = _sub1(xml, r"<CreDt>[^<]*</CreDt>", "<CreDt>yesterday</CreDt>")
    if m: out.append(("CreDt not a dateTime", m))
    m = _sub1(xml, r"<MsgDefIdr>[^<]*</MsgDefIdr>", "<MsgDefIdr>" + "x" * 36 + "</MsgDefIdr>")
    if m: out.append(("MsgDefIdr over 35 characters", m))
    m = _sub1(xml, r"<(Fr|To)>", lambda g: f'<{g.group(1)} id="1">')
    if m: out.append(("undeclared attribute on the header", m))
    m = _sub1(xml, r"<Fr>.*?</Fr>", "")
    if m: out.append(("Fr removed", m))
    m = _sub1(xml, r"(<StsRsnInf><Rsn><Cd>)[A-Z0-9]+(</Cd>)", r"\g<1>TOOLONG")
    if m: out.append(("status reason code over 4 characters", m))
    m = _sub1(xml, r"<OrgnlMsgId>[^<]*</OrgnlMsgId>\s*", "")
    if m: out.append(("OrgnlMsgId removed", m))
    # the extended target list families' own leaves: a sequence type, a debit/credit code, a boolean, an AnyBIC, a number
    m = _sub1(xml, r"<SeqTp>[A-Z]{4}</SeqTp>", "<SeqTp>WEEK</SeqTp>")
    if m: out.append(("SeqTp outside its enumeration", m))
    m = _sub1(xml, r"<CdtDbt>[A-Z]{4}</CdtDbt>", "<CdtDbt>DEBT</CdtDbt>")
    if m: out.append(("CdtDbt outside its enumeration", m))
    m = _sub1(xml, r"<(Accptd|TrckgInd|PssblDplctFlg)>(true|false)</\1>", r"<\1>yes</\1>")
    if m: out.append(("boolean indicator not a boolean", m))
    m = _sub1(xml, r"<AnyBIC>([A-Z0-9]+)</AnyBIC>", r"<AnyBIC>bad-bic</AnyBIC>")
    if m: out.append(("AnyBIC breaks the pattern", m))
    m = _sub1(xml, r"<(NbOfMvmntRcrds|TtlNbOfDocs|NbOfDocs)>\d+</\1>", r"<\1>two</\1>")
    if m: out.append(("a number that is not a number", m))
    m = _sub1(xml, r"<StsCd>[A-Z]{4}</StsCd>", "<StsCd>ACCEPTED</StsCd>")
    if m: out.append(("StsCd over 4 characters", m))
    m = _sub1(xml, r"<Tp>ALLL</Tp>", "<Tp>ALLX</Tp>")
    if m: out.append(("query type outside its enumeration", m))
    # the business file header's own leaves
    m = _sub1(xml, r"<PyldIdr>[^<]*</PyldIdr>", "")
    if m: out.append(("PyldIdr removed", m))
    m = _sub1(xml, r"<CreDtAndTm>[^<]*</CreDtAndTm>", "<CreDtAndTm>2026-09-09</CreDtAndTm>")
    if m: out.append(("CreDtAndTm not a dateTime", m))
    m = _sub1(xml, r"<PyldTp>[^<]*</PyldTp>", "<PyldTp></PyldTp>")
    if m: out.append(("empty PyldTp", m))
    m = _sub1(xml, r"<SysUsr>[^<]*</SysUsr>", "<SysUsr>" + "u" * 141 + "</SysUsr>")
    if m: out.append(("SysUsr over 140 characters", m))
    return out


def xmllint(xsd_path, xml_text, workdir, name):
    """xmllint --schema: (valid : bool, message)."""
    path = f"{workdir}/{name}.xml"
    with open(path, "w") as f:
        f.write(xml_text)
    r = subprocess.run(["xmllint", "--noout", "--schema", xsd_path, path], capture_output=True, text=True)
    return r.returncode == 0, (r.stderr.strip().splitlines() or [""])[0][:200]
