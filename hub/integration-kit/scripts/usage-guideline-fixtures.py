#!/usr/bin/env python3
"""usage-guideline-fixtures.py — the fixture corpus of the CBPR+ and HVPS+ rule sets (`motoko/iso/RuleSets.mo`).

For each set: one conforming message per family it covers (AppHdr + Document, both valid under the official
XSDs — checked here with xmllint before writing), and one violating message per rule, each a conforming message
with one defect and the rule id the canister must answer with. Deterministic (seeded). Writes
`integration-kit/xml/guidelines/` and `integration-kit/xml/guidelines-manifest.json`.
"""
import argparse
import hashlib
import json
import os
import random
import shutil
import subprocess
import sys
import tempfile

DECL = '<?xml version="1.0" encoding="UTF-8"?>\n'
T = "2026-09-12T10:00:00Z"
D = "2026-09-12"
NBE, CIB, DEUT = "NBEGEGCXXXX", "CIBEEGCXXXX", "DEUTDEFFXXX"
IBAN = "EG380019000500000000263180002"
V = {"pacs.008": "pacs.008.001.08", "pacs.009": "pacs.009.001.08", "pacs.002": "pacs.002.001.10", "pacs.004": "pacs.004.001.09",
     "camt.053": "camt.053.001.08", "camt.054": "camt.054.001.08", "camt.056": "camt.056.001.08", "camt.029": "camt.029.001.09",
     "camt.050": "camt.050.001.05", "camt.052": "camt.052.001.08", "head.001": "head.001.001.02"}
NS = {k: f"urn:iso:std:iso:20022:tech:xsd:{v}" for k, v in V.items()}


def uetr(rng):
    h = "%032x" % rng.getrandbits(128)
    return f"{h[:8]}-{h[8:12]}-4{h[13:16]}-{'89ab'[rng.randrange(4)]}{h[17:20]}-{h[20:32]}"


def amount(rng, lo=1, hi=250000):
    return f"{rng.randrange(lo * 100, hi * 100) / 100:.2f}"


def mid(rng, prefix):
    return f"{prefix}{rng.randrange(10**9):09d}"


def hdr(fam, msg_id, rng, svc="swift.cbprplus.02"):
    return f"""<AppHdr xmlns="{NS['head.001']}">
  <Fr><FIId><FinInstnId><BICFI>{NBE}</BICFI></FinInstnId></FIId></Fr>
  <To><FIId><FinInstnId><BICFI>{DEUT}</BICFI></FinInstnId></FIId></To>
  <BizMsgIdr>{msg_id}</BizMsgIdr>
  <MsgDefIdr>{V[fam]}</MsgDefIdr>
  <BizSvc>{svc}</BizSvc>
  <CreDt>{T}</CreDt>
</AppHdr>
"""


def address(kind="hybrid"):
    if kind == "structured":
        return "<PstlAdr><StrtNm>Nile Corniche</StrtNm><BldgNb>1</BldgNb><PstCd>11511</PstCd><TwnNm>Cairo</TwnNm><Ctry>EG</Ctry></PstlAdr>"
    if kind == "hybrid":
        return "<PstlAdr><TwnNm>Cairo</TwnNm><Ctry>EG</Ctry><AdrLine>1 Nile Corniche</AdrLine><AdrLine>Garden City</AdrLine></PstlAdr>"
    if kind == "unstructured":
        return "<PstlAdr><AdrLine>1 Nile Corniche</AdrLine><AdrLine>Garden City</AdrLine><AdrLine>Cairo</AdrLine><AdrLine>Egypt</AdrLine></PstlAdr>"
    if kind == "hybrid-long":
        return "<PstlAdr><TwnNm>Cairo</TwnNm><Ctry>EG</Ctry><AdrLine>1 Nile Corniche</AdrLine><AdrLine>Garden City</AdrLine><AdrLine>Floor 3</AdrLine></PstlAdr>"
    return ""


def pacs008(rng, hvps=False, **kw):
    m = kw.get("msg_id", mid(rng, "P8"))
    sttlm = kw.get("sttlm", "<SttlmInf><SttlmMtd>CLRG</SttlmMtd><ClrSys><Cd>EGR</Cd></ClrSys></SttlmInf>" if hvps else "<SttlmInf><SttlmMtd>INDA</SttlmMtd></SttlmInf>")
    agents = kw.get("agents", f"<InstgAgt><FinInstnId><BICFI>{NBE}</BICFI></FinInstnId></InstgAgt><InstdAgt><FinInstnId><BICFI>{CIB}</BICFI></FinInstnId></InstdAgt>" if hvps else "")
    u = kw.get("uetr", f"<UETR>{uetr(rng)}</UETR>")
    body = f"""<Document xmlns="{NS['pacs.008']}">
  <FIToFICstmrCdtTrf>
    <GrpHdr>
      <MsgId>{m}</MsgId>
      <CreDtTm>{T}</CreDtTm>
      <NbOfTxs>{kw.get('nb', 1)}</NbOfTxs>
      {sttlm}
      {agents}
    </GrpHdr>
    <CdtTrfTxInf>
      <PmtId><InstrId>{kw.get('instr', 'INSTR-1')}</InstrId><EndToEndId>{kw.get('e2e', 'E2E-' + str(rng.randrange(10**9)))}</EndToEndId>{u}</PmtId>
      <IntrBkSttlmAmt Ccy="USD">{amount(rng)}</IntrBkSttlmAmt>
      {kw.get('sttlm_dt', f'<IntrBkSttlmDt>{D}</IntrBkSttlmDt>')}
      <ChrgBr>{kw.get('chrgbr', 'SHAR')}</ChrgBr>
      <Dbtr><Nm>Example Debtor SAE</Nm>{kw.get('dbtr_adr', address('hybrid'))}</Dbtr>
      <DbtrAcct><Id><IBAN>{IBAN}</IBAN></Id></DbtrAcct>
      <DbtrAgt>{kw.get('dbtr_agt', f'<FinInstnId><BICFI>{NBE}</BICFI></FinInstnId>')}</DbtrAgt>
      <CdtrAgt><FinInstnId><BICFI>{DEUT}</BICFI></FinInstnId></CdtrAgt>
      <Cdtr><Nm>Example Creditor GmbH</Nm>{kw.get('cdtr_adr', address('structured').replace('Nile Corniche', 'Market Platz').replace('11511', '10178').replace('Cairo', 'Berlin').replace('EG', 'DE'))}</Cdtr>
      <CdtrAcct><Id><IBAN>DE89370400440532013000</IBAN></Id></CdtrAcct>
    </CdtTrfTxInf>{kw.get('extra_tx', '')}
  </FIToFICstmrCdtTrf>
</Document>
"""
    return (hdr("pacs.008", m, rng) if kw.get("header", True) else "") + body


def pacs009(rng, hvps=False, **kw):
    m = kw.get("msg_id", mid(rng, "P9"))
    sttlm = "<SttlmInf><SttlmMtd>CLRG</SttlmMtd><ClrSys><Cd>EGR</Cd></ClrSys></SttlmInf>" if hvps else "<SttlmInf><SttlmMtd>INDA</SttlmMtd></SttlmInf>"
    agents = f"<InstgAgt><FinInstnId><BICFI>{NBE}</BICFI></FinInstnId></InstgAgt><InstdAgt><FinInstnId><BICFI>{CIB}</BICFI></FinInstnId></InstdAgt>" if hvps else ""
    body = f"""<Document xmlns="{NS['pacs.009']}">
  <FICdtTrf>
    <GrpHdr>
      <MsgId>{m}</MsgId>
      <CreDtTm>{T}</CreDtTm>
      <NbOfTxs>1</NbOfTxs>
      {sttlm}
      {agents}
    </GrpHdr>
    <CdtTrfTxInf>
      <PmtId><InstrId>INSTR-1</InstrId><EndToEndId>E2E-{rng.randrange(10**9)}</EndToEndId><UETR>{uetr(rng)}</UETR></PmtId>
      <IntrBkSttlmAmt Ccy="USD">{amount(rng, 1000, 5000000)}</IntrBkSttlmAmt>
      <IntrBkSttlmDt>{D}</IntrBkSttlmDt>
      <Dbtr>{kw.get('dbtr', f'<FinInstnId><BICFI>{NBE}</BICFI></FinInstnId>')}</Dbtr>
      <DbtrAgt><FinInstnId><BICFI>{NBE}</BICFI></FinInstnId></DbtrAgt>
      <CdtrAgt><FinInstnId><BICFI>{DEUT}</BICFI></FinInstnId></CdtrAgt>
      <Cdtr>{kw.get('cdtr', f'<FinInstnId><BICFI>{CIB}</BICFI></FinInstnId>')}</Cdtr>
    </CdtTrfTxInf>
  </FICdtTrf>
</Document>
"""
    return hdr("pacs.009", m, rng) + body


def pacs002(rng, **kw):
    m = mid(rng, "P2")
    body = f"""<Document xmlns="{NS['pacs.002']}">
  <FIToFIPmtStsRpt>
    <GrpHdr><MsgId>{m}</MsgId><CreDtTm>{T}</CreDtTm></GrpHdr>
    <OrgnlGrpInfAndSts><OrgnlMsgId>P8{rng.randrange(10**9):09d}</OrgnlMsgId><OrgnlMsgNmId>pacs.008.001.08</OrgnlMsgNmId>{kw.get('grpsts', '')}</OrgnlGrpInfAndSts>
    <TxInfAndSts><OrgnlEndToEndId>E2E-1</OrgnlEndToEndId>{kw.get('orgnl_uetr', f'<OrgnlUETR>{uetr(rng)}</OrgnlUETR>')}<TxSts>ACSC</TxSts></TxInfAndSts>{kw.get('extra', '')}
  </FIToFIPmtStsRpt>
</Document>
"""
    return hdr("pacs.002", m, rng) + body


def pacs004(rng, **kw):
    m = mid(rng, "P4")
    body = f"""<Document xmlns="{NS['pacs.004']}">
  <PmtRtr>
    <GrpHdr><MsgId>{m}</MsgId><CreDtTm>{T}</CreDtTm><NbOfTxs>{kw.get('nb', 1)}</NbOfTxs><SttlmInf><SttlmMtd>INDA</SttlmMtd></SttlmInf></GrpHdr>
    <TxInf>
      <RtrId>RTR{rng.randrange(10**9)}</RtrId>
      <OrgnlEndToEndId>E2E-1</OrgnlEndToEndId>
      {kw.get('orgnl_uetr', f'<OrgnlUETR>{uetr(rng)}</OrgnlUETR>')}
      <RtrdIntrBkSttlmAmt Ccy="USD">{amount(rng)}</RtrdIntrBkSttlmAmt>
      {kw.get('sttlm_dt', f'<IntrBkSttlmDt>{D}</IntrBkSttlmDt>')}
      {kw.get('reason', '<RtrRsnInf><Rsn><Cd>AC01</Cd></Rsn></RtrRsnInf>')}
    </TxInf>{kw.get('extra', '')}
  </PmtRtr>
</Document>
"""
    return hdr("pacs.004", m, rng) + body


def entry(rng, status="BOOK"):
    return f"""<Ntry><NtryRef>NTRY-{rng.randrange(10**6)}</NtryRef><Amt Ccy="USD">{amount(rng)}</Amt><CdtDbtInd>CRDT</CdtDbtInd><Sts><Cd>{status}</Cd></Sts><BookgDt><Dt>{D}</Dt></BookgDt><ValDt><Dt>{D}</Dt></ValDt><BkTxCd><Prtry><Cd>PMNT</Cd></Prtry></BkTxCd>
        <NtryDtls><TxDtls><Refs><EndToEndId>E2E-1</EndToEndId><UETR>{uetr(rng)}</UETR></Refs></TxDtls></NtryDtls></Ntry>"""


def camt053(rng, hvps=False, **kw):
    m = mid(rng, "C53")
    bals = kw.get("bals", f'<Bal><Tp><CdOrPrtry><Cd>OPBD</Cd></CdOrPrtry></Tp><Amt Ccy="USD">{amount(rng)}</Amt><CdtDbtInd>CRDT</CdtDbtInd><Dt><Dt>{D}</Dt></Dt></Bal><Bal><Tp><CdOrPrtry><Cd>CLBD</Cd></CdOrPrtry></Tp><Amt Ccy="USD">{amount(rng)}</Amt><CdtDbtInd>CRDT</CdtDbtInd><Dt><Dt>{D}</Dt></Dt></Bal>')
    stmt = f"""<Stmt><Id>STMT{rng.randrange(10**9)}</Id><CreDtTm>{T}</CreDtTm><Acct><Id><IBAN>{IBAN}</IBAN></Id><Ccy>USD</Ccy></Acct>
      {bals}
      {entry(rng, kw.get('status', 'BOOK'))}
    </Stmt>"""
    body = f"""<Document xmlns="{NS['camt.053']}">
  <BkToCstmrStmt>
    <GrpHdr><MsgId>{m}</MsgId><CreDtTm>{T}</CreDtTm></GrpHdr>
    {stmt}{stmt if kw.get('two') else ''}
  </BkToCstmrStmt>
</Document>
"""
    return hdr("camt.053", m, rng, "swift.cbprplus.02" if not hvps else "rtgs.hvpsplus.01") + body


def camt054(rng, **kw):
    m = mid(rng, "C54")
    ntf = f"""<Ntfctn><Id>NTF{rng.randrange(10**9)}</Id><CreDtTm>{T}</CreDtTm><Acct><Id><IBAN>{IBAN}</IBAN></Id></Acct>
      {entry(rng, kw.get('status', 'BOOK'))}
    </Ntfctn>"""
    body = f"""<Document xmlns="{NS['camt.054']}">
  <BkToCstmrDbtCdtNtfctn>
    <GrpHdr><MsgId>{m}</MsgId><CreDtTm>{T}</CreDtTm></GrpHdr>
    {ntf}{ntf if kw.get('two') else ''}
  </BkToCstmrDbtCdtNtfctn>
</Document>
"""
    return hdr("camt.054", m, rng) + body


def camt056(rng, **kw):
    m = mid(rng, "C56")
    tx = f"""<TxInf><CxlId>CXL{rng.randrange(10**9)}</CxlId><OrgnlGrpInf><OrgnlMsgId>P8{rng.randrange(10**9):09d}</OrgnlMsgId><OrgnlMsgNmId>pacs.008.001.08</OrgnlMsgNmId></OrgnlGrpInf><OrgnlEndToEndId>E2E-1</OrgnlEndToEndId>{kw.get('orgnl_uetr', f'<OrgnlUETR>{uetr(rng)}</OrgnlUETR>')}<OrgnlIntrBkSttlmAmt Ccy="USD">{amount(rng)}</OrgnlIntrBkSttlmAmt><OrgnlIntrBkSttlmDt>{D}</OrgnlIntrBkSttlmDt>{kw.get('reason', '<CxlRsnInf><Rsn><Cd>DUPL</Cd></Rsn></CxlRsnInf>')}</TxInf>"""
    body = f"""<Document xmlns="{NS['camt.056']}">
  <FIToFIPmtCxlReq>
    <Assgnmt><Id>{m}</Id><Assgnr><Agt><FinInstnId><BICFI>{NBE}</BICFI></FinInstnId></Agt></Assgnr><Assgne><Agt><FinInstnId><BICFI>{DEUT}</BICFI></FinInstnId></Agt></Assgne><CreDtTm>{T}</CreDtTm></Assgnmt>
    <Undrlyg>{tx}{tx if kw.get('two') else ''}</Undrlyg>
  </FIToFIPmtCxlReq>
</Document>
"""
    return hdr("camt.056", m, rng) + body


def camt029(rng, **kw):
    m = mid(rng, "C29")
    tx = f"""<TxInfAndSts><CxlStsId>CS{rng.randrange(10**9)}</CxlStsId><OrgnlGrpInf><OrgnlMsgId>C56{rng.randrange(10**9):09d}</OrgnlMsgId><OrgnlMsgNmId>camt.056.001.08</OrgnlMsgNmId></OrgnlGrpInf><OrgnlEndToEndId>E2E-1</OrgnlEndToEndId>{kw.get('orgnl_uetr', f'<OrgnlUETR>{uetr(rng)}</OrgnlUETR>')}{kw.get('sts', '<TxCxlSts>ACCR</TxCxlSts>')}</TxInfAndSts>"""
    body = f"""<Document xmlns="{NS['camt.029']}">
  <RsltnOfInvstgtn>
    <Assgnmt><Id>{m}</Id><Assgnr><Agt><FinInstnId><BICFI>{DEUT}</BICFI></FinInstnId></Agt></Assgnr><Assgne><Agt><FinInstnId><BICFI>{NBE}</BICFI></FinInstnId></Agt></Assgne><CreDtTm>{T}</CreDtTm></Assgnmt>
    <Sts><Conf>CNCL</Conf></Sts>
    <CxlDtls>{tx}{tx if kw.get('two') else ''}</CxlDtls>
  </RsltnOfInvstgtn>
</Document>
"""
    return hdr("camt.029", m, rng) + body


def camt050(rng, **kw):
    m = mid(rng, "LQ")
    body = f"""<Document xmlns="{NS['camt.050']}">
  <LqdtyCdtTrf>
    <MsgHdr><MsgId>{m}</MsgId><CreDtTm>{T}</CreDtTm></MsgHdr>
    <LqdtyCdtTrf>
      {kw.get('id', f'<LqdtyTrfId><EndToEndId>LQ{rng.randrange(10**9)}</EndToEndId></LqdtyTrfId>')}
      <Cdtr><FinInstnId><BICFI>{NBE}</BICFI></FinInstnId></Cdtr>
      {kw.get('cdtr_acct', '<CdtrAcct><Id><Othr><Id>RTGS-NBE</Id></Othr></Id></CdtrAcct>')}
      <TrfdAmt>{kw.get('amt', f'<AmtWthCcy Ccy="EGP">{amount(rng, 1000, 5000000)}</AmtWthCcy>')}</TrfdAmt>
      <Dbtr><FinInstnId><BICFI>{NBE}</BICFI></FinInstnId></Dbtr>
      <SttlmDt>{D}</SttlmDt>
    </LqdtyCdtTrf>
  </LqdtyCdtTrf>
</Document>
"""
    return hdr("camt.050", m, rng, "rtgs.hvpsplus.01") + body


def camt052(rng, **kw):
    m = mid(rng, "C52")
    rpt = f"""<Rpt><Id>RPT{rng.randrange(10**9)}</Id><CreDtTm>{T}</CreDtTm><Acct><Id><IBAN>{IBAN}</IBAN></Id><Ccy>EGP</Ccy></Acct>
      {kw.get('bal', f'<Bal><Tp><CdOrPrtry><Cd>ITBD</Cd></CdOrPrtry></Tp><Amt Ccy="EGP">{amount(rng)}</Amt><CdtDbtInd>CRDT</CdtDbtInd><Dt><Dt>{D}</Dt></Dt></Bal>')}
      {entry(rng).replace('Ccy="USD"', 'Ccy="EGP"')}
    </Rpt>"""
    body = f"""<Document xmlns="{NS['camt.052']}">
  <BkToCstmrAcctRpt>
    <GrpHdr><MsgId>{m}</MsgId><CreDtTm>{T}</CreDtTm></GrpHdr>
    {rpt}{rpt if kw.get('two') else ''}
  </BkToCstmrAcctRpt>
</Document>
"""
    return hdr("camt.052", m, rng, "rtgs.hvpsplus.01") + body


def conforming(rng):
    return {
        "CBPRPLUS": [("pacs.008", "cbpr-pacs008-conforming", pacs008(rng)), ("pacs.009", "cbpr-pacs009-conforming", pacs009(rng)), ("pacs.002", "cbpr-pacs002-conforming", pacs002(rng)), ("pacs.004", "cbpr-pacs004-conforming", pacs004(rng)),
                     ("camt.053", "cbpr-camt053-conforming", camt053(rng)), ("camt.054", "cbpr-camt054-conforming", camt054(rng)), ("camt.056", "cbpr-camt056-conforming", camt056(rng)), ("camt.029", "cbpr-camt029-conforming", camt029(rng))],
        "HVPSPLUS": [("pacs.008", "hvps-pacs008-conforming", pacs008(rng, hvps=True)), ("pacs.009", "hvps-pacs009-conforming", pacs009(rng, hvps=True)), ("pacs.002", "hvps-pacs002-conforming", pacs002(rng)),
                     ("camt.050", "hvps-camt050-conforming", camt050(rng)), ("camt.052", "hvps-camt052-conforming", camt052(rng)), ("camt.053", "hvps-camt053-conforming", camt053(rng, hvps=True))],
    }


def violations(rng):
    extra_tx = f"""
    <CdtTrfTxInf><PmtId><EndToEndId>E2E-2</EndToEndId><UETR>{uetr(rng)}</UETR></PmtId><IntrBkSttlmAmt Ccy="USD">10.00</IntrBkSttlmAmt><IntrBkSttlmDt>{D}</IntrBkSttlmDt><ChrgBr>SHAR</ChrgBr><Dbtr><Nm>B</Nm>{address('hybrid')}</Dbtr><DbtrAgt><FinInstnId><BICFI>{NBE}</BICFI></FinInstnId></DbtrAgt><CdtrAgt><FinInstnId><BICFI>{DEUT}</BICFI></FinInstnId></CdtrAgt><Cdtr><Nm>C</Nm>{address('structured')}</Cdtr></CdtTrfTxInf>"""
    return {
        "CBPRPLUS": [
            ("pacs.008", "cbpr-pacs008-no-header", "CBPR-BAH-REQUIRED", pacs008(rng, header=False)),
            ("pacs.008", "cbpr-pacs008-msgid-charset", "CBPR-MSGID-FINX", pacs008(rng, msg_id="P8_2026#1")),
            ("pacs.008", "cbpr-pacs008-two-transactions", ["CBPR-ONE-TX", "CBPR-NBOFTXS-ONE"], pacs008(rng, nb=2, extra_tx=extra_tx)),
            ("pacs.008", "cbpr-pacs008-nboftxs", "CBPR-NBOFTXS-ONE", pacs008(rng, nb=2)),
            ("pacs.008", "cbpr-pacs008-no-uetr", "CBPR-UETR-REQUIRED", pacs008(rng, uetr="")),
            ("pacs.008", "cbpr-pacs008-clrg", "CBPR-STTLM-MTD", pacs008(rng, sttlm="<SttlmInf><SttlmMtd>CLRG</SttlmMtd><ClrSys><Cd>EGR</Cd></ClrSys></SttlmInf>")),
            ("pacs.008", "cbpr-pacs008-no-settlement-date", "CBPR-STTLM-DT-REQUIRED", pacs008(rng, sttlm_dt="")),
            ("pacs.008", "cbpr-pacs008-slev", "CBPR-CHRGBR", pacs008(rng, chrgbr="SLEV")),
            ("pacs.008", "cbpr-pacs008-e2e-charset", "CBPR-E2E-FINX", pacs008(rng, e2e="E2E//1")),
            ("pacs.008", "cbpr-pacs008-instrid-charset", "CBPR-INSTRID-FINX", pacs008(rng, instr="/INSTR")),
            ("pacs.008", "cbpr-pacs008-debtor-agent-unidentified", "CBPR-DBTR-AGENT-ID", pacs008(rng, dbtr_agt="<FinInstnId><Nm>Some Bank</Nm></FinInstnId>")),
            ("pacs.008", "cbpr-pacs008-debtor-unstructured-address", "CBPR-DBTR-ADDRESS", pacs008(rng, dbtr_adr=address("unstructured"))),
            ("pacs.008", "cbpr-pacs008-creditor-hybrid-three-lines", "CBPR-CDTR-ADDRESS", pacs008(rng, cdtr_adr=address("hybrid-long"))),
            ("pacs.008", "cbpr-pacs008-creditor-agent-unidentified", "CBPR-CDTR-AGENT-ID", pacs008(rng).replace(f"<CdtrAgt><FinInstnId><BICFI>{DEUT}</BICFI></FinInstnId></CdtrAgt>", "<CdtrAgt><FinInstnId><Nm>Some Bank</Nm></FinInstnId></CdtrAgt>")),
            ("pacs.009", "cbpr-pacs009-debtor-unidentified", "CBPR-FI-DBTR-ID", pacs009(rng, dbtr="<FinInstnId><Nm>Some Bank</Nm></FinInstnId>")),
            ("pacs.009", "cbpr-pacs009-creditor-unidentified", "CBPR-FI-CDTR-ID", pacs009(rng, cdtr="<FinInstnId><Nm>Some Bank</Nm></FinInstnId>")),
            ("pacs.004", "cbpr-pacs004-two-transactions", "CBPR-RTR-ONE-TX", pacs004(rng, nb=2, extra=f"<TxInf><RtrId>RTR2</RtrId><OrgnlEndToEndId>E2E-2</OrgnlEndToEndId><OrgnlUETR>{uetr(rng)}</OrgnlUETR><RtrdIntrBkSttlmAmt Ccy=\"USD\">1.00</RtrdIntrBkSttlmAmt><IntrBkSttlmDt>{D}</IntrBkSttlmDt><RtrRsnInf><Rsn><Cd>AC01</Cd></Rsn></RtrRsnInf></TxInf>")),
            ("pacs.002", "cbpr-pacs002-two-transactions", "CBPR-STS-ONE-TX", pacs002(rng, extra=f"<TxInfAndSts><OrgnlEndToEndId>E2E-2</OrgnlEndToEndId><OrgnlUETR>{uetr(rng)}</OrgnlUETR><TxSts>RJCT</TxSts></TxInfAndSts>")),
            ("pacs.002", "cbpr-pacs002-no-original-uetr", "CBPR-STS-ORGNL-UETR", pacs002(rng, orgnl_uetr="")),
            ("pacs.002", "cbpr-pacs002-group-status", "CBPR-STS-NO-GROUP-STATUS", pacs002(rng, grpsts="<GrpSts>ACSC</GrpSts>")),
            ("pacs.004", "cbpr-pacs004-no-original-uetr", "CBPR-RTR-ORGNL-UETR", pacs004(rng, orgnl_uetr="")),
            ("pacs.004", "cbpr-pacs004-no-reason", "CBPR-RTR-REASON", pacs004(rng, reason="")),
            ("pacs.004", "cbpr-pacs004-no-settlement-date", "CBPR-RTR-STTLM-DT", pacs004(rng, sttlm_dt="")),
            ("camt.053", "cbpr-camt053-two-statements", "CBPR-STMT-ONE", camt053(rng, two=True)),
            ("camt.053", "cbpr-camt053-no-closing-balance", "CBPR-STMT-BALANCES", camt053(rng, bals=f'<Bal><Tp><CdOrPrtry><Cd>OPBD</Cd></CdOrPrtry></Tp><Amt Ccy="USD">1.00</Amt><CdtDbtInd>CRDT</CdtDbtInd><Dt><Dt>{D}</Dt></Dt></Bal>')),
            ("camt.053", "cbpr-camt053-pending-entry", "CBPR-STMT-BOOKED", camt053(rng, status="PDNG")),
            ("camt.054", "cbpr-camt054-two-notifications", "CBPR-NTFCTN-ONE", camt054(rng, two=True)),
            ("camt.054", "cbpr-camt054-pending-entry", "CBPR-NTFCTN-BOOKED", camt054(rng, status="PDNG")),
            ("camt.056", "cbpr-camt056-two-transactions", "CBPR-CXL-ONE", camt056(rng, two=True)),
            ("camt.056", "cbpr-camt056-no-original-uetr", "CBPR-CXL-ORGNL-UETR", camt056(rng, orgnl_uetr="")),
            ("camt.056", "cbpr-camt056-no-reason", "CBPR-CXL-REASON", camt056(rng, reason="")),
            ("camt.029", "cbpr-camt029-two-transactions", "CBPR-RSLTN-ONE", camt029(rng, two=True)),
            ("camt.029", "cbpr-camt029-no-original-uetr", "CBPR-RSLTN-ORGNL-UETR", camt029(rng, orgnl_uetr="")),
            ("camt.029", "cbpr-camt029-no-status", "CBPR-RSLTN-STATUS", camt029(rng, sts="")),
        ],
        "HVPSPLUS": [
            ("pacs.008", "hvps-pacs008-no-header", "HVPS-BAH-REQUIRED", pacs008(rng, hvps=True, header=False)),
            ("pacs.008", "hvps-pacs008-msgid-charset", "HVPS-MSGID-FINX", pacs008(rng, hvps=True, msg_id="P8_2026#1")),
            ("pacs.008", "hvps-pacs008-two-transactions", ["HVPS-ONE-TX", "HVPS-NBOFTXS-ONE"], pacs008(rng, hvps=True, nb=2, extra_tx=extra_tx)),
            ("pacs.008", "hvps-pacs008-nboftxs", "HVPS-NBOFTXS-ONE", pacs008(rng, hvps=True, nb=2)),
            ("pacs.008", "hvps-pacs008-no-uetr", "HVPS-UETR-REQUIRED", pacs008(rng, hvps=True, uetr="")),
            ("pacs.008", "hvps-pacs008-inda", "HVPS-STTLM-CLRG", pacs008(rng, hvps=True, sttlm="<SttlmInf><SttlmMtd>INDA</SttlmMtd><ClrSys><Cd>EGR</Cd></ClrSys></SttlmInf>")),
            ("pacs.008", "hvps-pacs008-no-clearing-system", "HVPS-CLRSYS-REQUIRED", pacs008(rng, hvps=True, sttlm="<SttlmInf><SttlmMtd>CLRG</SttlmMtd></SttlmInf>")),
            ("pacs.008", "hvps-pacs008-no-settlement-date", "HVPS-STTLM-DT-REQUIRED", pacs008(rng, hvps=True, sttlm_dt="")),
            ("pacs.008", "hvps-pacs008-no-instructing-agent", "HVPS-INSTG-AGT-REQUIRED", pacs008(rng, hvps=True, agents=f"<InstdAgt><FinInstnId><BICFI>{CIB}</BICFI></FinInstnId></InstdAgt>")),
            ("pacs.008", "hvps-pacs008-no-instructed-agent", "HVPS-INSTD-AGT-REQUIRED", pacs008(rng, hvps=True, agents=f"<InstgAgt><FinInstnId><BICFI>{NBE}</BICFI></FinInstnId></InstgAgt>")),
            ("pacs.008", "hvps-pacs008-e2e-charset", "HVPS-E2E-FINX", pacs008(rng, hvps=True, e2e="E2E//1")),
            ("pacs.002", "hvps-pacs002-two-transactions", "HVPS-STS-ONE-TX", pacs002(rng, extra=f"<TxInfAndSts><OrgnlEndToEndId>E2E-2</OrgnlEndToEndId><OrgnlUETR>{uetr(rng)}</OrgnlUETR><TxSts>RJCT</TxSts></TxInfAndSts>")),
            ("pacs.002", "hvps-pacs002-no-original-uetr", "HVPS-STS-ORGNL-UETR", pacs002(rng, orgnl_uetr="")),
            ("camt.050", "hvps-camt050-no-id", "HVPS-LQDTY-ID", camt050(rng, id="")),
            ("camt.050", "hvps-camt050-amount-without-currency", "HVPS-LQDTY-CCY", camt050(rng, amt="<AmtWthtCcy>1000.00</AmtWthtCcy>")),
            ("camt.050", "hvps-camt050-no-creditor-account", "HVPS-LQDTY-ACCOUNTS", camt050(rng, cdtr_acct="")),
            ("camt.052", "hvps-camt052-two-reports", "HVPS-RPT-ONE", camt052(rng, two=True)),
            ("camt.052", "hvps-camt052-no-balance", "HVPS-RPT-BALANCE", camt052(rng, bal="")),
            ("camt.053", "hvps-camt053-two-statements", "HVPS-STMT-ONE", camt053(rng, hvps=True, two=True)),
            ("camt.053", "hvps-camt053-no-opening-balance", "HVPS-STMT-BALANCES", camt053(rng, hvps=True, bals=f'<Bal><Tp><CdOrPrtry><Cd>CLBD</Cd></CdOrPrtry></Tp><Amt Ccy="USD">1.00</Amt><CdtDbtInd>CRDT</CdtDbtInd><Dt><Dt>{D}</Dt></Dt></Bal>')),
        ],
    }


def moc_text(t):
    return '"' + t.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'


TEST_HEAD = r'''// RuleSets.test.mo — GENERATED by integration-kit/scripts/usage-guideline-fixtures.py from the guideline fixture
// corpus (integration-kit/xml/guidelines-manifest.json). Do not edit: regenerate. Every conforming message passes
// its schema and its rule set; every violation is refused with exactly its rule ids. The runner
// (integration-kit/scripts/usage-guideline-check.py) prints the implemented-rule counts and checks xmllint.
import Array "mo:core/Array";
import List "mo:core/List";
import Text "mo:core/Text";
import Xml "../iso/Xml";
import IsoSchema "../iso/IsoSchema";
import RS "../iso/RuleSets";

func short(f : Text) : Text { let p = Text.split(f, #char '.'); let a = p.next(); let b = p.next(); switch (a, b) { case (?x, ?y) x # "." # y; case (_) f } };

/// The distinct rule ids the set raises against a schema-valid message, in order of first appearance.
func judge(setId : Text, xml : Text) : [Text] {
  let ?rs = RS.byId(setId) else { assert false; return [] };
  let #ok(roots) = Xml.parseMessage(Text.encodeUtf8(xml)) else { assert false; return [] };
  let hasHeader = roots.size() == 2;
  let doc = roots[roots.size() - 1];
  if (hasHeader) { let ?hs = IsoSchema.schemaFor(roots[0].namespace) else { assert false; return [] }; assert (IsoSchema.validate(hs, roots[0]).size() == 0) };
  let ?sc = IsoSchema.schemaFor(doc.namespace) else { assert false; return [] };
  assert (IsoSchema.validate(sc, doc).size() == 0);
  let root = if (doc.children.size() == 1) doc.children[0] else doc;
  let ids = List.empty<Text>();
  for (i in RS.evaluate(rs, short(sc.family), root, hasHeader).vals()) { if (not List.contains(ids, Text.equal, i.rule)) List.add(ids, i.rule) };
  List.toArray(ids)
};
func same(a : [Text], b : [Text]) : Bool { Array.sort(a, Text.compare) == Array.sort(b, Text.compare) };

// two sets, every rule with its basis, every family counted
assert (RS.all().size() == 2);
for (rs in RS.all().vals()) { assert (rs.rules.size() > 0); for (r in rs.rules.vals()) { assert (r.basis != "" and r.families.size() > 0) }; assert (RS.implemented(rs).size() > 0); assert (Text.contains(rs.reconciliation, #text "NOT RECONCILED")) };
'''


def xmllint_parts(schema_dir, fam, text, work, name):
    """xmllint on the AppHdr (head.001) and the Document separately; 'schema-valid' when both pass."""
    parts = []
    if "<AppHdr" in text:
        parts.append(("head.001", text[text.index("<AppHdr"):text.index("</AppHdr>") + len("</AppHdr>")]))
    parts.append((fam, text[text.index("<Document"):]))
    for f, frag in parts:
        p = os.path.join(work, f"{name}-{f}.xml")
        open(p, "w").write(DECL + frag)
        r = subprocess.run(["xmllint", "--noout", "--schema", os.path.join(schema_dir, V[f] + ".xsd"), p], capture_output=True, text=True)
        if r.returncode != 0:
            return "schema-invalid: " + (r.stdout + r.stderr).strip()[:300]
    return "schema-valid"


def write_test(path, manifest):
    out = [TEST_HEAD]
    for f in manifest["conforming"]:
        out.append(f"// {f['id']}\nassert (judge({moc_text(f['ruleSet'])}, {moc_text(open(f['path']).read())}).size() == 0);")
    for f in manifest["violating"]:
        rules = ", ".join(moc_text(r) for r in f["rules"])
        out.append(f"// {f['id']}\nassert (same(judge({moc_text(f['ruleSet'])}, {moc_text(open(f['path']).read())}), [{rules}]));")
    out.append(f"\n// {len(manifest['conforming'])} conforming messages pass; {len(manifest['violating'])} violations refused with exactly their rule ids.")
    open(path, "w").write("\n".join(out) + "\n")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--schemas", default="integration-kit/profile-runner/official-schemas/iso-base")
    ap.add_argument("--out", default="integration-kit/xml/guidelines")
    ap.add_argument("--seed", type=int, default=20260912)
    ap.add_argument("--test-out", default="motoko/test/RuleSets.test.mo")
    a = ap.parse_args()
    rng = random.Random(a.seed)
    work = tempfile.mkdtemp(prefix="ug-")
    manifest = {"version": "thebes-usage-guideline-fixtures-v1", "seed": a.seed, "conforming": [], "violating": []}
    bad = 0
    try:
        for rs, items in conforming(rng).items():
            for fam, name, text in items:
                text = DECL + text
                lint = xmllint_parts(a.schemas, fam, text, work, name)
                if lint != "schema-valid":
                    bad += 1; print(f"CONFORMING FIXTURE FAILS XSD: {name} {lint}", file=sys.stderr)
                path = os.path.join(a.out, name + ".xml"); open(path, "w").write(text)
                manifest["conforming"].append({"id": name, "path": path, "ruleSet": rs, "messageKind": fam, "xmllint": lint, "sha256": hashlib.sha256(text.encode()).hexdigest()})
        for rs, items in violations(rng).items():
            for fam, name, rule, text in items:
                text = DECL + text
                lint = xmllint_parts(a.schemas, fam, text, work, name)
                # every violation is schema-valid: the rule set, not the XSD, refuses it
                if lint != "schema-valid":
                    bad += 1; print(f"VIOLATION NOT SCHEMA-VALID: {name} {lint}", file=sys.stderr)
                path = os.path.join(a.out, name + ".xml"); open(path, "w").write(text)
                manifest["violating"].append({"id": name, "path": path, "ruleSet": rs, "messageKind": fam, "rules": rule if isinstance(rule, list) else [rule], "xmllint": lint, "sha256": hashlib.sha256(text.encode()).hexdigest()})
    finally:
        shutil.rmtree(work, ignore_errors=True)
    json.dump(manifest, open("integration-kit/xml/guidelines-manifest.json", "w"), indent=2)
    write_test(a.test_out, manifest)
    print(f"{len(manifest['conforming'])} conforming, {len(manifest['violating'])} violating fixtures; {bad} schema disagreements")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
