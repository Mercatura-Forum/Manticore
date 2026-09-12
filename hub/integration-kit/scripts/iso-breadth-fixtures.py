#!/usr/bin/env python3
"""iso-breadth-fixtures.py — the fixture corpus of the twenty families the schema-profile codec added
(`motoko/iso/IsoBreadth.mo`).

Deterministic: the same seed writes the same files. Every valid fixture is checked here with
`xmllint --schema` against the official XSD before it is written; every invalid fixture is one valid
fixture with one defect and the rule id the canister must answer with. The manifest
(`integration-kit/xml/breadth-manifest.json`) is what the runner and the Motoko test read.

    integration-kit/scripts/iso-breadth-fixtures.py [--schemas DIR] [--out integration-kit/xml]
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
BANK = "NBEGEGCXXXX"      # National Bank of Egypt
CIB = "CIBEEGCXXXX"       # Commercial International Bank
OPERATOR = "EGCBEGCAXXX"  # the scheme operator
IBAN = "EG380019000500000000263180002"

FAMILIES = {
    "pacs.007": "pacs.007.001.10", "pacs.010": "pacs.010.001.04", "pacs.029": "pacs.029.001.02",
    "pain.007": "pain.007.001.10", "pain.009": "pain.009.001.07", "pain.010": "pain.010.001.07", "pain.011": "pain.011.001.07", "pain.012": "pain.012.001.07",
    "camt.052": "camt.052.001.08", "camt.057": "camt.057.001.06", "camt.060": "camt.060.001.05", "camt.050": "camt.050.001.05", "camt.025": "camt.025.001.05",
    "camt.026": "camt.026.001.07", "camt.027": "camt.027.001.07", "camt.028": "camt.028.001.09", "camt.087": "camt.087.001.06",
    "admi.006": "admi.006.001.01", "admi.017": "admi.017.001.01", "head.002": "head.002.001.01",
    # payloads of the business file
    "pacs.008": "pacs.008.001.08", "pacs.003": "pacs.003.001.08",
}
NS = {k: f"urn:iso:std:iso:20022:tech:xsd:{v}" for k, v in FAMILIES.items()}


def uetr(rng):
    h = "%032x" % rng.getrandbits(128)
    return f"{h[:8]}-{h[8:12]}-4{h[13:16]}-{'89ab'[rng.randrange(4)]}{h[17:20]}-{h[20:32]}"


def amount(rng, lo=1, hi=250000):
    return f"{rng.randrange(lo * 100, hi * 100) / 100:.2f}"


def mid(rng, prefix):
    return f"{prefix}{rng.randrange(10**9):09d}"


# ─── the valid shapes ───

def pacs007(rng, **kw):
    return f"""{DECL}<Document xmlns="{NS['pacs.007']}">
  <FIToFIPmtRvsl>
    <GrpHdr>
      <MsgId>{kw.get('msg_id', mid(rng, 'RVSL'))}</MsgId>
      <CreDtTm>{T}</CreDtTm>
      <NbOfTxs>{kw.get('nb', 1)}</NbOfTxs>
      <SttlmInf><SttlmMtd>CLRG</SttlmMtd></SttlmInf>
    </GrpHdr>
    <OrgnlGrpInf><OrgnlMsgId>PACS008-{rng.randrange(10**6)}</OrgnlMsgId><OrgnlMsgNmId>pacs.008.001.08</OrgnlMsgNmId></OrgnlGrpInf>
    <TxInf>
      <RvslId>RV{rng.randrange(10**9)}</RvslId>
      <OrgnlEndToEndId>E2E-{rng.randrange(10**9)}</OrgnlEndToEndId>
      <OrgnlUETR>{uetr(rng)}</OrgnlUETR>
      <RvsdIntrBkSttlmAmt Ccy="{kw.get('ccy', 'EGP')}">{kw.get('amt', amount(rng))}</RvsdIntrBkSttlmAmt>
      <RvslRsnInf><Rsn><Cd>{kw.get('reason', 'DUPL')}</Cd></Rsn></RvslRsnInf>
    </TxInf>
  </FIToFIPmtRvsl>
</Document>
"""


def pacs010(rng, **kw):
    agent = kw.get('dbtr', f"<FinInstnId><BICFI>{CIB}</BICFI><Nm>Commercial International Bank</Nm></FinInstnId>")
    return f"""{DECL}<Document xmlns="{NS['pacs.010']}">
  <FIDrctDbt>
    <GrpHdr>
      <MsgId>{mid(rng, 'FIDD')}</MsgId>
      <CreDtTm>{T}</CreDtTm>
      <NbOfTxs>2</NbOfTxs>
    </GrpHdr>
    <CdtInstr>
      <CdtId>CDT{rng.randrange(10**9)}</CdtId>
      <Cdtr><FinInstnId><BICFI>{BANK}</BICFI><Nm>National Bank of Egypt</Nm></FinInstnId></Cdtr>
      <DrctDbtTxInf>
        <PmtId><InstrId>INSTR-1</InstrId><EndToEndId>E2E-{rng.randrange(10**9)}</EndToEndId>{kw.get('uetr1', f'<UETR>{uetr(rng)}</UETR>')}</PmtId>
        <IntrBkSttlmAmt Ccy="EGP">{amount(rng)}</IntrBkSttlmAmt>
        <IntrBkSttlmDt>{D}</IntrBkSttlmDt>
        <Dbtr>{agent}</Dbtr>
        <DbtrAcct><Id><Othr><Id>SETTLE-CIB</Id></Othr></Id></DbtrAcct>
      </DrctDbtTxInf>
      <DrctDbtTxInf>
        <PmtId><EndToEndId>E2E-{rng.randrange(10**9)}</EndToEndId><UETR>{uetr(rng)}</UETR></PmtId>
        <IntrBkSttlmAmt Ccy="EGP">{amount(rng)}</IntrBkSttlmAmt>
        <IntrBkSttlmDt>{D}</IntrBkSttlmDt>
        <Dbtr><FinInstnId><BICFI>{OPERATOR}</BICFI></FinInstnId></Dbtr>
      </DrctDbtTxInf>
    </CdtInstr>
  </FIDrctDbt>
</Document>
"""


def pacs029(rng, **kw):
    a = amount(rng)
    moves = kw.get('moves', [(BANK, a, 'DBIT'), (CIB, a, 'CRDT')])
    recs = "".join(f"""      <MvmntRcrd>
        <Id>MV{i}</Id>
        <Amt><Amt Ccy="EGP">{amt}</Amt><CdtDbt>{side}</CdtDbt></Amt>
        <Ptcpt><Id><OrgId><AnyBIC>{bic}</AnyBIC></OrgId></Id></Ptcpt>
      </MvmntRcrd>
""" for i, (bic, amt, side) in enumerate(moves, 1))
    return f"""{DECL}<Document xmlns="{NS['pacs.029']}">
  <MulSttlmReq>
    <GrpHdr>
      <MsgId>{mid(rng, 'MSR')}</MsgId>
      <CreDtTm>{T}</CreDtTm>
      <NbOfSttlmReqs>1</NbOfSttlmReqs>
      <SttlmInf><SttlmMtd>CLRG</SttlmMtd></SttlmInf>
    </GrpHdr>
    <SttlmReq>
      <InstrId>INSTR{rng.randrange(10**9)}</InstrId>
      <SttlmCycl>{D}-C1</SttlmCycl>
      <NbOfMvmntRcrds>{kw.get('declared', len(moves))}</NbOfMvmntRcrds>
{recs}    </SttlmReq>
  </MulSttlmReq>
</Document>
"""


def pain007(rng, **kw):
    return f"""{DECL}<Document xmlns="{NS['pain.007']}">
  <CstmrPmtRvsl>
    <GrpHdr>
      <MsgId>{mid(rng, 'CRVSL')}</MsgId>
      <CreDtTm>{T}</CreDtTm>
      <NbOfTxs>1</NbOfTxs>
      <InitgPty><Nm>Cairo Water Utility</Nm></InitgPty>
    </GrpHdr>
    <OrgnlGrpInf><OrgnlMsgId>PAIN008-{rng.randrange(10**6)}</OrgnlMsgId><OrgnlMsgNmId>pain.008.001.08</OrgnlMsgNmId></OrgnlGrpInf>
    <OrgnlPmtInfAndRvsl>
      <OrgnlPmtInfId>PMTINF-1</OrgnlPmtInfId>
      <TxInf>
        <RvslId>RV{rng.randrange(10**9)}</RvslId>
        <OrgnlEndToEndId>E2E-{rng.randrange(10**9)}</OrgnlEndToEndId>
        <RvsdInstdAmt Ccy="EGP">{kw.get('amt', amount(rng))}</RvsdInstdAmt>
        <RvslRsnInf><Rsn><Cd>AM05</Cd></Rsn></RvslRsnInf>
      </TxInf>
    </OrgnlPmtInfAndRvsl>
  </CstmrPmtRvsl>
</Document>
"""


def pain009(rng, **kw):
    return f"""{DECL}<Document xmlns="{NS['pain.009']}">
  <MndtInitnReq>
    <GrpHdr>
      <MsgId>{mid(rng, 'MNDT')}</MsgId>
      <CreDtTm>{T}</CreDtTm>
      <InitgPty><Nm>Cairo Water Utility</Nm></InitgPty>
    </GrpHdr>
    <Mndt>
      <MndtId>{kw.get('mandate_id', 'MANDATE-' + str(rng.randrange(10**6)))}</MndtId>
      <MndtReqId>REQ{rng.randrange(10**9)}</MndtReqId>
      <Tp><SvcLvl><Cd>SEPA</Cd></SvcLvl><LclInstrm><Cd>CORE</Cd></LclInstrm></Tp>
      <Ocrncs><SeqTp>{kw.get('seq', 'RCUR')}</SeqTp><Frqcy><Tp>MNTH</Tp></Frqcy><FrstColltnDt>2026-10-01</FrstColltnDt></Ocrncs>
      <TrckgInd>false</TrckgInd>
      <MaxAmt Ccy="EGP">{kw.get('max_amt', '500.00')}</MaxAmt>
      <Cdtr><Nm>Cairo Water Utility</Nm></Cdtr>
      <CdtrAcct><Id><Othr><Id>ACC{rng.randrange(10**8)}</Id></Othr></Id></CdtrAcct>
      <CdtrAgt><FinInstnId><BICFI>{BANK}</BICFI></FinInstnId></CdtrAgt>
      <Dbtr><Nm>Household {rng.randrange(1000)}</Nm></Dbtr>
      <DbtrAcct><Id><IBAN>{IBAN}</IBAN></Id></DbtrAcct>
      <DbtrAgt>{kw.get('dbtr_agt', f'<FinInstnId><BICFI>{CIB}</BICFI></FinInstnId>')}</DbtrAgt>
    </Mndt>
  </MndtInitnReq>
</Document>
"""


def pain010(rng, **kw):
    m = 'MANDATE-' + str(rng.randrange(10**6))
    return f"""{DECL}<Document xmlns="{NS['pain.010']}">
  <MndtAmdmntReq>
    <GrpHdr>
      <MsgId>{mid(rng, 'MAMD')}</MsgId>
      <CreDtTm>{T}</CreDtTm>
      <InitgPty><Nm>Cairo Water Utility</Nm></InitgPty>
    </GrpHdr>
    <UndrlygAmdmntDtls>
      <AmdmntRsn><Rsn><Cd>MD16</Cd></Rsn></AmdmntRsn>
      <Mndt>
        <MndtId>{m}</MndtId>
        <TrckgInd>false</TrckgInd>
        <MaxAmt Ccy="EGP">750.00</MaxAmt>
      </Mndt>
      <OrgnlMndt><OrgnlMndtId>{m}</OrgnlMndtId></OrgnlMndt>
    </UndrlygAmdmntDtls>
  </MndtAmdmntReq>
</Document>
"""


def pain011(rng, **kw):
    return f"""{DECL}<Document xmlns="{NS['pain.011']}">
  <MndtCxlReq>
    <GrpHdr>
      <MsgId>{mid(rng, 'MCXL')}</MsgId>
      <CreDtTm>{T}</CreDtTm>
      <InitgPty><Nm>Cairo Water Utility</Nm></InitgPty>
    </GrpHdr>
    <UndrlygCxlDtls>
      <CxlRsn><Rsn><Cd>MD16</Cd></Rsn></CxlRsn>
      <OrgnlMndt><OrgnlMndtId>MANDATE-{rng.randrange(10**6)}</OrgnlMndtId></OrgnlMndt>
    </UndrlygCxlDtls>
  </MndtCxlReq>
</Document>
"""


def pain012(rng, **kw):
    accepted = kw.get('accepted', True)
    rj = "" if accepted else "<RjctRsn><Cd>MD01</Cd></RjctRsn>"
    return f"""{DECL}<Document xmlns="{NS['pain.012']}">
  <MndtAccptncRpt>
    <GrpHdr>
      <MsgId>{mid(rng, 'MACC')}</MsgId>
      <CreDtTm>{T}</CreDtTm>
      <InitgPty><Nm>Commercial International Bank</Nm></InitgPty>
    </GrpHdr>
    <UndrlygAccptncDtls>
      <OrgnlMsgInf><MsgId>MNDT{rng.randrange(10**9):09d}</MsgId><MsgNmId>pain.009.001.07</MsgNmId></OrgnlMsgInf>
      <AccptncRslt><Accptd>{'true' if accepted else 'false'}</Accptd>{rj}</AccptncRslt>
      <OrgnlMndt><OrgnlMndtId>MANDATE-{rng.randrange(10**6)}</OrgnlMndtId></OrgnlMndt>
    </UndrlygAccptncDtls>
  </MndtAccptncRpt>
</Document>
"""


def camt060(rng, **kw):
    return f"""{DECL}<Document xmlns="{NS['camt.060']}">
  <AcctRptgReq>
    <GrpHdr>
      <MsgId>{mid(rng, 'ARR')}</MsgId>
      <CreDtTm>{T}</CreDtTm>
    </GrpHdr>
    <RptgReq>
      <Id>RQ{rng.randrange(10**9)}</Id>
      <ReqdMsgNmId>{kw.get('kind', 'camt.052.001.08')}</ReqdMsgNmId>
      <Acct><Id><IBAN>{IBAN}</IBAN></Id></Acct>
      <AcctOwnr><Agt><FinInstnId><BICFI>{CIB}</BICFI></FinInstnId></Agt></AcctOwnr>
      <RptgPrd><FrToDt><FrDt>{D}</FrDt><ToDt>{D}</ToDt></FrToDt><Tp>ALLL</Tp></RptgPrd>
    </RptgReq>
  </AcctRptgReq>
</Document>
"""


def camt057(rng, **kw):
    items = "".join(f"""      <Itm>
        <Id>ITM{i}</Id>
        <EndToEndId>E2E-{rng.randrange(10**9)}</EndToEndId>
        <UETR>{uetr(rng)}</UETR>
        <Amt Ccy="{kw.get('ccy', 'EGP')}">{amount(rng)}</Amt>
        <XpctdValDt>{D}</XpctdValDt>
        <DbtrAgt><FinInstnId><BICFI>{CIB}</BICFI></FinInstnId></DbtrAgt>
      </Itm>
""" for i in range(1, 3))
    return f"""{DECL}<Document xmlns="{NS['camt.057']}">
  <NtfctnToRcv>
    <GrpHdr>
      <MsgId>{mid(rng, 'NTR')}</MsgId>
      <CreDtTm>{T}</CreDtTm>
    </GrpHdr>
    <Ntfctn>
      <Id>NTF{rng.randrange(10**9)}</Id>
      <Acct><Id><Othr><Id>ACC{rng.randrange(10**8)}</Id></Othr></Id></Acct>
{items}    </Ntfctn>
  </NtfctnToRcv>
</Document>
"""


def camt050(rng, **kw):
    return f"""{DECL}<Document xmlns="{NS['camt.050']}">
  <LqdtyCdtTrf>
    <MsgHdr><MsgId>{mid(rng, 'LQT')}</MsgId><CreDtTm>{T}</CreDtTm></MsgHdr>
    <LqdtyCdtTrf>
      <LqdtyTrfId><EndToEndId>LQ{rng.randrange(10**9)}</EndToEndId></LqdtyTrfId>
      <Cdtr><FinInstnId><BICFI>{BANK}</BICFI></FinInstnId></Cdtr>
      <CdtrAcct><Id><Othr><Id>RTGS-NBE</Id></Othr></Id></CdtrAcct>
      <TrfdAmt>{kw.get('amt', f'<AmtWthCcy Ccy="EGP">{amount(rng, 1000, 5000000)}</AmtWthCcy>')}</TrfdAmt>
      <Dbtr><FinInstnId><BICFI>{BANK}</BICFI></FinInstnId></Dbtr>
      <DbtrAcct><Id><Othr><Id>ACH-NBE</Id></Othr></Id></DbtrAcct>
      <SttlmDt>{D}</SttlmDt>
    </LqdtyCdtTrf>
  </LqdtyCdtTrf>
</Document>
"""


def camt025(rng, **kw):
    return f"""{DECL}<Document xmlns="{NS['camt.025']}">
  <Rct>
    <MsgHdr><MsgId>{mid(rng, 'RCT')}</MsgId><CreDtTm>{T}</CreDtTm></MsgHdr>
    <RctDtls>
      <OrgnlMsgId><MsgId>LQT{rng.randrange(10**9):09d}</MsgId><MsgNmId>camt.050.001.05</MsgNmId></OrgnlMsgId>
      <ReqHdlg><StsCd>{kw.get('status', 'ACPT')}</StsCd><Desc>liquidity transfer settled</Desc></ReqHdlg>
    </RctDtls>
  </Rct>
</Document>
"""


def investigation(rng, family, **kw):
    root = {"camt.026": "UblToApply", "camt.027": "ClmNonRct", "camt.028": "AddtlPmtInf", "camt.087": "ReqToModfyPmt"}[family]
    tail = {
        "camt.026": "    <Justfn><MssngOrIncrrctInf><MssngInf><Cd>MS01</Cd></MssngInf><MssngInf><Cd>MS03</Cd></MssngInf></MssngOrIncrrctInf></Justfn>\n",
        "camt.027": "",
        "camt.028": "    <Inf><InstrForNxtAgt><InstrInf>apply to invoice 4471</InstrInf></InstrForNxtAgt></Inf>\n",
        "camt.087": f"    <Mod>\n      <IntrBkSttlmAmt Ccy=\"EGP\">{amount(rng)}</IntrBkSttlmAmt>\n    </Mod>\n",
    }[family]
    return f"""{DECL}<Document xmlns="{NS[family]}">
  <{root}>
    <Assgnmt>
      <Id>ASG{rng.randrange(10**9)}</Id>
      <Assgnr><Agt><FinInstnId><BICFI>{kw.get('assigner', CIB)}</BICFI></FinInstnId></Agt></Assgnr>
      <Assgne><Agt><FinInstnId><BICFI>{BANK}</BICFI></FinInstnId></Agt></Assgne>
      <CreDtTm>{T}</CreDtTm>
    </Assgnmt>
    <Case><Id>CASE{rng.randrange(10**9)}</Id><Cretr><Agt><FinInstnId><BICFI>{kw.get('assigner', CIB)}</BICFI></FinInstnId></Agt></Cretr></Case>
    <Undrlyg>
      <IntrBk>
        <OrgnlGrpInf><OrgnlMsgId>PACS008-{rng.randrange(10**6)}</OrgnlMsgId><OrgnlMsgNmId>pacs.008.001.08</OrgnlMsgNmId></OrgnlGrpInf>
        <OrgnlEndToEndId>E2E-{rng.randrange(10**9)}</OrgnlEndToEndId>
        <OrgnlUETR>{uetr(rng)}</OrgnlUETR>
        <OrgnlIntrBkSttlmAmt Ccy="EGP">{amount(rng)}</OrgnlIntrBkSttlmAmt>
        <OrgnlIntrBkSttlmDt>{D}</OrgnlIntrBkSttlmDt>
      </IntrBk>
    </Undrlyg>
{tail}  </{root}>
</Document>
"""


def admi006(rng, **kw):
    return f"""{DECL}<Document xmlns="{NS['admi.006']}">
  <RsndReq>
    <MsgHdr><MsgId>{mid(rng, 'RSND')}</MsgId><CreDtTm>{T}</CreDtTm></MsgHdr>
    <RsndSchCrit>
      <BizDt>{D}</BizDt>
      <SeqNb>{rng.randrange(1, 5000)}</SeqNb>
      <OrgnlMsgNmId>pacs.002.001.10</OrgnlMsgNmId>
      <Rcpt><Id><AnyBIC>{kw.get('rcpt', CIB)}</AnyBIC></Id></Rcpt>
    </RsndSchCrit>
  </RsndReq>
</Document>
"""


def admi017(rng, **kw):
    return f"""{DECL}<Document xmlns="{NS['admi.017']}">
  <PrcgReq>
    <MsgId>{mid(rng, 'PRCG')}</MsgId>
    <SttlmSsnIdr>{kw.get('session', 'S001')}</SttlmSsnIdr>
    <Req><Tp>EODP</Tp><RqstrId><AnyBIC><AnyBIC>{OPERATOR}</AnyBIC></AnyBIC></RqstrId><AddtlReqInf>run end of day</AddtlReqInf></Req>
  </PrcgReq>
</Document>
"""


def camt052(rng, **kw):
    return f"""{DECL}<Document xmlns="{NS['camt.052']}">
  <BkToCstmrAcctRpt>
    <GrpHdr>
      <MsgId>{mid(rng, 'ARPT')}</MsgId>
      <CreDtTm>{T}</CreDtTm>
      <OrgnlBizQry><MsgId>ARR{rng.randrange(10**9):09d}</MsgId><MsgNmId>camt.060.001.05</MsgNmId></OrgnlBizQry>
    </GrpHdr>
    <Rpt>
      <Id>RPT{rng.randrange(10**9)}</Id>
      <CreDtTm>{T}</CreDtTm>
      <FrToDt><FrDtTm>{D}T00:00:00Z</FrDtTm><ToDtTm>{D}T10:00:00Z</ToDtTm></FrToDt>
      <Acct><Id><IBAN>{IBAN}</IBAN></Id><Ccy>EGP</Ccy></Acct>
      <Bal><Tp><CdOrPrtry><Cd>OPBD</Cd></CdOrPrtry></Tp><Amt Ccy="EGP">{amount(rng)}</Amt><CdtDbtInd>CRDT</CdtDbtInd><Dt><Dt>{D}</Dt></Dt></Bal>
      <Bal><Tp><CdOrPrtry><Cd>ITBD</Cd></CdOrPrtry></Tp><Amt Ccy="EGP">{amount(rng)}</Amt><CdtDbtInd>{kw.get('bal_side', 'CRDT')}</CdtDbtInd><Dt><Dt>{D}</Dt></Dt></Bal>
      <Ntry>
        <NtryRef>NTRY-1</NtryRef>
        <Amt Ccy="EGP">{amount(rng)}</Amt>
        <CdtDbtInd>DBIT</CdtDbtInd>
        <Sts><Cd>BOOK</Cd></Sts>
        <BookgDt><Dt>{D}</Dt></BookgDt>
        <ValDt><Dt>{D}</Dt></ValDt>
        <AcctSvcrRef>4471</AcctSvcrRef>
        <BkTxCd><Prtry><Cd>PMNT</Cd></Prtry></BkTxCd>
        <NtryDtls><TxDtls>
          <Refs>
            <AcctSvcrRef>4471</AcctSvcrRef>
            <EndToEndId>E2E-{rng.randrange(10**9)}</EndToEndId>
            <UETR>{uetr(rng)}</UETR>
          </Refs>
          <RltdPties><Cdtr><Pty><Nm>Cairo Water Utility</Nm></Pty></Cdtr></RltdPties>
          <RmtInf>
            <Ustrd>water bill 2026-08</Ustrd>
          </RmtInf>
        </TxDtls></NtryDtls>
      </Ntry>
      <Ntry>
        <NtryRef>NTRY-2</NtryRef>
        <Amt Ccy="EGP">{amount(rng)}</Amt>
        <CdtDbtInd>CRDT</CdtDbtInd>
        <Sts><Cd>BOOK</Cd></Sts>
        <BookgDt><Dt>{D}</Dt></BookgDt>
        <ValDt><Dt>{D}</Dt></ValDt>
        <AcctSvcrRef>4472</AcctSvcrRef>
        <BkTxCd><Prtry><Cd>PMNT</Cd></Prtry></BkTxCd>
        <NtryDtls><TxDtls>
          <Refs>
            <AcctSvcrRef>4472</AcctSvcrRef>
            <UETR>{uetr(rng)}</UETR>
          </Refs>
          <RltdPties><Dbtr><Pty><Nm>Salary Payroll Ltd</Nm></Pty></Dbtr></RltdPties>
        </TxDtls></NtryDtls>
      </Ntry>
    </Rpt>
  </BkToCstmrAcctRpt>
</Document>
"""


def pacs008_payload(rng):
    return f"""<Document xmlns="{NS['pacs.008']}">
  <FIToFICstmrCdtTrf>
    <GrpHdr>
      <MsgId>{mid(rng, 'P8')}</MsgId>
      <CreDtTm>{T}</CreDtTm>
      <NbOfTxs>1</NbOfTxs>
      <SttlmInf><SttlmMtd>CLRG</SttlmMtd></SttlmInf>
    </GrpHdr>
    <CdtTrfTxInf>
      <PmtId><EndToEndId>E2E-{rng.randrange(10**9)}</EndToEndId><UETR>{uetr(rng)}</UETR></PmtId>
      <IntrBkSttlmAmt Ccy="EGP">{amount(rng)}</IntrBkSttlmAmt>
      <ChrgBr>SLEV</ChrgBr>
      <Dbtr><Nm>Salary Payroll Ltd</Nm></Dbtr>
      <DbtrAgt><FinInstnId><BICFI>{CIB}</BICFI></FinInstnId></DbtrAgt>
      <CdtrAgt><FinInstnId><BICFI>{BANK}</BICFI></FinInstnId></CdtrAgt>
      <Cdtr><Nm>Household {rng.randrange(1000)}</Nm></Cdtr>
      <CdtrAcct><Id><IBAN>{IBAN}</IBAN></Id></CdtrAcct>
    </CdtTrfTxInf>
  </FIToFICstmrCdtTrf>
</Document>"""


def head002(rng, **kw):
    payloads = kw.get('payloads', [pacs008_payload(rng), pacs008_payload(rng)])
    pl = "".join(f"  <Pyld>{x}</Pyld>\n" for x in payloads)
    return f"""{DECL}<Xchg xmlns="{NS['head.002']}">
  <PyldDesc>
    <PyldData><PyldIdr>FILE{rng.randrange(10**9)}</PyldIdr><CreDtAndTm>{T}</CreDtAndTm><PssblDplctFlg>false</PssblDplctFlg></PyldData>
    <ApplSpcfcs><SysUsr>ach-batch</SysUsr><TtlNbOfDocs>{kw.get('declared', len(payloads))}</TtlNbOfDocs></ApplSpcfcs>
    <PyldTp>pacs.008.001.08</PyldTp>
    <MnfstData><DocTp>pacs.008.001.08</DocTp><NbOfDocs>{len(payloads)}</NbOfDocs></MnfstData>
  </PyldDesc>
{pl}</Xchg>
"""


VALID = {
    "pacs.007": lambda rng: [("reversal-pacs007-duplicate", pacs007(rng))],
    "pacs.010": lambda rng: [("fi-direct-debit-pacs010-two-debtors", pacs010(rng))],
    "pacs.029": lambda rng: [("settlement-request-pacs029-cycle", pacs029(rng))],
    "pain.007": lambda rng: [("reversal-pain007-customer", pain007(rng))],
    "pain.009": lambda rng: [("mandate-pain009-initiation", pain009(rng)), ("mandate-pain009-one-off", pain009(rng, seq="OOFF"))],
    "pain.010": lambda rng: [("mandate-pain010-amendment", pain010(rng))],
    "pain.011": lambda rng: [("mandate-pain011-cancellation", pain011(rng))],
    "pain.012": lambda rng: [("mandate-pain012-accepted", pain012(rng)), ("mandate-pain012-rejected", pain012(rng, accepted=False))],
    "camt.052": lambda rng: [("report-camt052-intraday", camt052(rng))],
    "camt.057": lambda rng: [("notification-camt057-two-items", camt057(rng))],
    "camt.060": lambda rng: [("reporting-request-camt060-intraday", camt060(rng)), ("reporting-request-camt060-statement", camt060(rng, kind="camt.053.001.08"))],
    "camt.050": lambda rng: [("liquidity-camt050-transfer", camt050(rng))],
    "camt.025": lambda rng: [("receipt-camt025-accepted", camt025(rng)), ("receipt-camt025-rejected", camt025(rng, status="RJCT"))],
    "camt.026": lambda rng: [("investigation-camt026-unable-to-apply", investigation(rng, "camt.026"))],
    "camt.027": lambda rng: [("investigation-camt027-claim-non-receipt", investigation(rng, "camt.027"))],
    "camt.028": lambda rng: [("investigation-camt028-additional-information", investigation(rng, "camt.028"))],
    "camt.087": lambda rng: [("investigation-camt087-request-to-modify", investigation(rng, "camt.087"))],
    "admi.006": lambda rng: [("admin-admi006-resend", admi006(rng))],
    "admi.017": lambda rng: [("admin-admi017-end-of-day", admi017(rng))],
    "head.002": lambda rng: [("file-head002-two-pacs008", head002(rng))],
}

# (name, family, xml, tier, rule, comment) — each is one valid shape with one defect
def INVALID(rng):
    out = []
    def add(name, fam, xml, tier, rule, why, xmllint_expect=None):
        # xmllint's verdict on the whole file: a schema-tier defect is one xmllint also refuses, a business-tier
        # defect is schema-valid — except where the canister is stricter than libxml2 by design (`xmllint_expect`)
        out.append((name, fam, xml, tier, rule, why, xmllint_expect or ("schema-invalid" if tier == "schema" else "schema-valid")))
    add("reversal-pacs007-missing-msgid", "pacs.007", pacs007(rng).replace(f"<MsgId>", "<MsgIdX>").replace("</MsgId>", "</MsgIdX>", 1), "schema", "ISO-XSD-UNEXPECTED", "GrpHdr/MsgId renamed: the content model does not allow MsgIdX")
    add("reversal-pacs007-count-mismatch", "pacs.007", pacs007(rng, nb=2), "business", "ISO-BIZ-COUNT", "NbOfTxs says 2, one TxInf")
    add("reversal-pacs007-zero-amount", "pacs.007", pacs007(rng, amt="0.00"), "business", "ISO-BIZ-AMOUNT", "a reversal of nothing")
    add("reversal-pacs007-unregistered-currency", "pacs.007", pacs007(rng, ccy="XAU"), "business", "ISO-BIZ-CURRENCY", "XAU is not a currency of the guideline")
    add("reversal-pacs007-reason-too-long", "pacs.007", pacs007(rng, reason="DUPLICATE"), "schema", "ISO-XSD-LENGTH", "ExternalReversalReason1Code is Max4Text")
    add("fi-direct-debit-pacs010-no-uetr", "pacs.010", pacs010(rng, uetr1=""), "business", "ISO-BIZ-UETR-REQUIRED", "every transaction carries its UETR on this rail")
    add("fi-direct-debit-pacs010-debtor-without-bic", "pacs.010", pacs010(rng, dbtr="<FinInstnId><ClrSysMmbId><MmbId>0019</MmbId></ClrSysMmbId></FinInstnId>"), "business", "ISO-BIZ-AGENT-BIC", "the debtor institution is not identified by a BICFI")
    add("settlement-request-pacs029-one-movement", "pacs.029", pacs029(rng, moves=[(BANK, "100.00", "DBIT")], declared=1), "schema", "ISO-XSD-MISSING", "the schema asks two movements or more")
    add("settlement-request-pacs029-movement-count", "pacs.029", pacs029(rng, declared=3), "business", "ISO-BIZ-COUNT", "NbOfMvmntRcrds says 3, two records")
    add("reversal-pain007-fraction-digits", "pain.007", pain007(rng, amt="10.123"), "business", "ISO-BIZ-AMOUNT", "three fraction digits in a two-digit currency")
    add("mandate-pain009-bad-sequence", "pain.009", pain009(rng, seq="WEEKLY"), "schema", "ISO-XSD-ENUM", "SequenceType2Code is FRST | RCUR | FNAL | OOFF | RPRE")
    add("mandate-pain009-debtor-agent-without-bic", "pain.009", pain009(rng, dbtr_agt="<FinInstnId><Nm>Some Bank</Nm></FinInstnId>"), "business", "ISO-BIZ-AGENT-BIC", "the debtor agent is not identified by a BICFI")
    add("mandate-pain009-id-too-long", "pain.009", pain009(rng, mandate_id="M" * 36), "schema", "ISO-XSD-LENGTH", "Max35Text")
    add("mandate-pain012-accepted-not-boolean", "pain.012", pain012(rng).replace("<Accptd>true</Accptd>", "<Accptd>yes</Accptd>"), "schema", "ISO-XSD-BOOLEAN", "YesNoIndicator")
    add("report-camt052-bad-side", "camt.052", camt052(rng, bal_side="CRED"), "schema", "ISO-XSD-ENUM", "CreditDebitCode is CRDT | DBIT")
    add("notification-camt057-unregistered-currency", "camt.057", camt057(rng, ccy="ZZZ"), "business", "ISO-BIZ-CURRENCY", "ZZZ is not a currency of the guideline")
    add("reporting-request-camt060-no-owner", "camt.060", camt060(rng).replace(f"<AcctOwnr><Agt><FinInstnId><BICFI>{CIB}</BICFI></FinInstnId></Agt></AcctOwnr>", ""), "schema", "ISO-XSD-MISSING", "AcctOwnr is required")
    add("liquidity-camt050-amount-without-currency", "camt.050", camt050(rng, amt="<AmtWthtCcy>1000.00</AmtWthtCcy>"), "business", "ISO-BIZ-CURRENCY", "the transferred amount names its currency on this rail")
    add("receipt-camt025-status-too-long", "camt.025", camt025(rng, status="ACCEPTED"), "schema", "ISO-XSD-LENGTH", "Max4AlphaNumericText")
    add("investigation-camt026-bad-bic", "camt.026", investigation(rng, "camt.026", assigner="CIBEEG"), "schema", "ISO-XSD-PATTERN", "BICFIDec2014Identifier")
    add("investigation-camt087-wrong-namespace", "camt.087", investigation(rng, "camt.087").replace(NS["camt.087"], "urn:iso:std:iso:20022:tech:xsd:camt.087.001.99"), "schema", "ISO-XSD-ROOT", "a version this component does not carry")
    add("admin-admi006-no-recipient", "admi.006", admi006(rng).replace(f"<Rcpt><Id><AnyBIC>{CIB}</AnyBIC></Id></Rcpt>", ""), "schema", "ISO-XSD-MISSING", "Rcpt is required")
    add("admin-admi017-session-too-long", "admi.017", admi017(rng, session="SESSION1"), "schema", "ISO-XSD-PATTERN", "Exact4AlphaNumericText is the pattern [a-zA-Z0-9]{4}")
    add("file-head002-payload-invalid", "head.002", head002(rng, payloads=[pacs008_payload(rng).replace("<ChrgBr>SLEV</ChrgBr>", "")]), "schema", "ISO-XSD-MISSING", "the payload is validated against its own schema: pacs.008 requires ChrgBr (head.002's Pyld is a lax xs:any, so xmllint on the file alone passes; the runner validates each payload against its own XSD)", "schema-valid")
    add("file-head002-doctype", "head.002", head002(rng).replace(DECL, DECL + "<!DOCTYPE Xchg [<!ENTITY x \"y\">]>\n"), "schema", "XML-UNSAFE-DECL", "a DTD is refused before parsing (libxml2 accepts an internal subset; the canister does not)", "schema-valid")
    return out


def xmllint(schema_dir, fam, xml):
    if shutil.which("xmllint") is None:
        return "tool-missing", ""
    xsd = os.path.join(schema_dir, FAMILIES[fam] + ".xsd")
    with tempfile.NamedTemporaryFile("w", suffix=".xml", delete=False) as f:
        f.write(xml)
        path = f.name
    try:
        r = subprocess.run(["xmllint", "--noout", "--schema", xsd, path], capture_output=True, text=True)
        return ("schema-valid" if r.returncode == 0 else "schema-invalid"), (r.stdout + r.stderr).strip()
    finally:
        os.unlink(path)


def moc_text(t):
    return '"' + t.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'


TEST_HEAD = r'''// IsoBreadth.test.mo — GENERATED by integration-kit/scripts/iso-breadth-fixtures.py from the fixture corpus
// (integration-kit/xml/breadth-manifest.json). Do not edit: regenerate. The off-canister half of the
// evidence — xmllint against the official XSD on every written document and the Prowide cross-parse — is
// integration-kit/scripts/iso-breadth-roundtrip.py; this test is the on-canister half, runnable anywhere.
import Text "mo:core/Text";
import Result "mo:core/Result";
import B "../iso/IsoBreadth";

func minorUnitsOf(c : Text) : ?Nat8 { switch (c) { case ("EGP" or "USD" or "EUR" or "GBP") ?2; case (_) null } };
let options = B.defaultEmitOptions("2026-09-12");

func valid(family : Text, xml : Text) {
  let d = B.decode(Text.encodeUtf8(xml), minorUnitsOf);
  assert (d.family == family);
  assert (d.schemaIssues.size() == 0);
  assert (Result.isOk(d.message));
  switch (B.roundTrip(Text.encodeUtf8(xml), minorUnitsOf, options)) {
    case (#ok(written)) {
      // the written document is read again by the schema tier and the business tier
      let again = B.decode(Text.encodeUtf8(written), minorUnitsOf);
      assert (again.family == family and again.schemaIssues.size() == 0 and Result.isOk(again.message));
    };
    case (#err(_)) { assert false };
  };
};

func refused(tier : Text, rule : Text, xml : Text) {
  let d = B.decode(Text.encodeUtf8(xml), minorUnitsOf);
  if (tier == "schema") {
    assert (d.schemaIssues.size() > 0);
    assert (d.schemaIssues[0].rule == rule);
  } else {
    assert (d.schemaIssues.size() == 0);
    switch (d.message) {
      case (#ok(_)) { assert false };
      case (#err(issues)) { assert (issues.size() > 0); assert (issues[0].rule == rule) };
    };
  };
  // nothing refused is ever written back
  assert (Result.isErr(B.roundTrip(Text.encodeUtf8(xml), minorUnitsOf, options)));
};
'''


def write_test(path, manifest, families):
    """The mops test: every fixture of the corpus embedded, the valid ones read and round-tripped with an equal
    second reading, the invalid ones refused with the expected rule id in the expected tier."""
    out = [TEST_HEAD]
    for f in manifest["valid"]:
        out.append(f"// {f['id']}\nvalid({moc_text(families[f['messageKind']])}, {moc_text(open(f['path']).read())});")
    for f in manifest["invalid"]:
        out.append(f"// {f['id']} — {f['why']}\nrefused({moc_text(f['tier'])}, {moc_text(f['rule'])}, {moc_text(open(f['path']).read())});")
    out.append(f"\n// {len(manifest['valid'])} valid fixtures across {len(families) - 2} families read, written and read again; {len(manifest['invalid'])} refused with their rule ids.")
    open(path, "w").write("\n".join(out) + "\n")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--schemas", default="integration-kit/profile-runner/official-schemas/iso-base")
    ap.add_argument("--out", default="integration-kit/xml")
    ap.add_argument("--seed", type=int, default=20260912)
    ap.add_argument("--test-out", default="motoko/test/IsoBreadth.test.mo", help="the mops test generated from the corpus")
    a = ap.parse_args()
    rng = random.Random(a.seed)
    manifest = {"version": "thebes-iso20022-breadth-fixtures-v1", "seed": a.seed, "families": FAMILIES, "valid": [], "invalid": []}
    failures = 0
    for fam, gen in VALID.items():
        for name, xml in gen(rng):
            status, detail = xmllint(a.schemas, fam, xml)
            if status == "schema-invalid":
                failures += 1
                print(f"VALID FIXTURE FAILS XSD: {name}\n{detail}", file=sys.stderr)
            path = os.path.join(a.out, "valid", name + ".xml")
            open(path, "w").write(xml)
            manifest["valid"].append({"id": f"valid/{name}.xml", "path": path, "messageKind": fam, "schemaFile": FAMILIES[fam] + ".xsd", "xmllint": status, "sha256": hashlib.sha256(xml.encode()).hexdigest()})
    for name, fam, xml, tier, rule, why, expect in INVALID(rng):
        status, _ = xmllint(a.schemas, fam, xml)
        if status != expect and status != "tool-missing":
            failures += 1
            print(f"INVALID FIXTURE TIER DISAGREES: {name} expected {expect}, xmllint {status}", file=sys.stderr)
        path = os.path.join(a.out, "invalid", name + ".xml")
        open(path, "w").write(xml)
        manifest["invalid"].append({"id": f"invalid/{name}.xml", "path": path, "messageKind": fam, "schemaFile": FAMILIES[fam] + ".xsd", "tier": tier, "rule": rule, "why": why, "xmllint": status, "xmllintExpected": expect, "sha256": hashlib.sha256(xml.encode()).hexdigest()})
    json.dump(manifest, open(os.path.join(a.out, "breadth-manifest.json"), "w"), indent=2)
    write_test(a.test_out, manifest, FAMILIES)
    print(f"{len(manifest['valid'])} valid, {len(manifest['invalid'])} invalid fixtures; {failures} disagreements with xmllint")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
