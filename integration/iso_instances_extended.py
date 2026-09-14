"""iso_instances_extended.py; schema-valid instances of the extended ISO 20022 target list families, for the
profile agreement check, the Prowide cross-parse and the canister batteries. Every template is checked
against the official XSD with `xmllint --schema` by the battery before it is used; the mutation machinery
of iso_instances.py applies to these as to the core messaging set families.
"""
from iso_instances import DECL, uetr, amount  # noqa: F401

NS7D = {f: f"urn:iso:std:iso:20022:tech:xsd:{f}" for f in [
    "pacs.003.001.08", "pacs.007.001.10", "pacs.010.001.04", "pacs.029.001.02",
    "pain.007.001.10", "pain.009.001.07", "pain.010.001.07", "pain.011.001.07", "pain.012.001.07",
    "camt.052.001.08", "camt.057.001.06", "camt.060.001.05", "camt.050.001.05", "camt.025.001.05",
    "camt.026.001.07", "camt.027.001.07", "camt.028.001.09", "camt.087.001.06",
    "admi.006.001.01", "admi.007.001.01", "admi.017.001.01", "head.002.001.01"]}
T = "2026-09-09T10:00:00Z"
D = "2026-09-09"


def _mid(rng, prefix="MSG"):
    return f"{prefix}{rng.randrange(10**12)}"


def valid_pacs003(rng, cdtr_bic, dbtr_bic, mandate_id, ccy="EGP", amt=None, u=None, msg_id=None, seq="RCUR", dbtr_iban="EG380019000500000000263180002", e2e=None):
    u = u or uetr(rng)
    amt = amt or amount(rng)
    return f"""{DECL}<Document xmlns="{NS7D['pacs.003.001.08']}">
  <FIToFICstmrDrctDbt>
    <GrpHdr>
      <MsgId>{msg_id or _mid(rng)}</MsgId>
      <CreDtTm>{T}</CreDtTm>
      <NbOfTxs>1</NbOfTxs>
      <SttlmInf><SttlmMtd>CLRG</SttlmMtd></SttlmInf>
    </GrpHdr>
    <DrctDbtTxInf>
      <PmtId><EndToEndId>{e2e or 'E2E-' + str(rng.randrange(10**9))}</EndToEndId><TxId>TX{rng.randrange(10**9)}</TxId><UETR>{u}</UETR></PmtId>
      <PmtTpInf><SvcLvl><Cd>SEPA</Cd></SvcLvl><LclInstrm><Cd>CORE</Cd></LclInstrm><SeqTp>{seq}</SeqTp></PmtTpInf>
      <IntrBkSttlmAmt Ccy="{ccy}">{amt}</IntrBkSttlmAmt>
      <IntrBkSttlmDt>{D}</IntrBkSttlmDt>
      <ChrgBr>SLEV</ChrgBr>
      <ReqdColltnDt>{D}</ReqdColltnDt>
      <DrctDbtTx><MndtRltdInf><MndtId>{mandate_id}</MndtId><DtOfSgntr>2026-01-15</DtOfSgntr></MndtRltdInf></DrctDbtTx>
      <Cdtr><Nm>Utility Company</Nm></Cdtr>
      <CdtrAcct><Id><Othr><Id>ACC{rng.randrange(10**8)}</Id></Othr></Id></CdtrAcct>
      <CdtrAgt><FinInstnId><BICFI>{cdtr_bic}</BICFI></FinInstnId></CdtrAgt>
      <Dbtr><Nm>Household {rng.randrange(1000)}</Nm></Dbtr>
      <DbtrAcct><Id><IBAN>{dbtr_iban}</IBAN></Id></DbtrAcct>
      <DbtrAgt><FinInstnId><BICFI>{dbtr_bic}</BICFI></FinInstnId></DbtrAgt>
      <RmtInf><Ustrd>electricity {rng.randrange(10**6)}</Ustrd></RmtInf>
    </DrctDbtTxInf>
  </FIToFICstmrDrctDbt>
</Document>
"""


def valid_pacs010(rng, cdtr_bic, dbtr_bic, ccy="EGP", amt=None, u=None, msg_id=None):
    u = u or uetr(rng)
    amt = amt or amount(rng)
    return f"""{DECL}<Document xmlns="{NS7D['pacs.010.001.04']}">
  <FIDrctDbt>
    <GrpHdr>
      <MsgId>{msg_id or _mid(rng)}</MsgId>
      <CreDtTm>{T}</CreDtTm>
      <NbOfTxs>1</NbOfTxs>
    </GrpHdr>
    <CdtInstr>
      <CdtId>CDT{rng.randrange(10**9)}</CdtId>
      <Cdtr><FinInstnId><BICFI>{cdtr_bic}</BICFI></FinInstnId></Cdtr>
      <DrctDbtTxInf>
        <PmtId><EndToEndId>E2E-{rng.randrange(10**9)}</EndToEndId><UETR>{u}</UETR></PmtId>
        <IntrBkSttlmAmt Ccy="{ccy}">{amt}</IntrBkSttlmAmt>
        <IntrBkSttlmDt>{D}</IntrBkSttlmDt>
        <Dbtr><FinInstnId><BICFI>{dbtr_bic}</BICFI></FinInstnId></Dbtr>
      </DrctDbtTxInf>
    </CdtInstr>
  </FIDrctDbt>
</Document>
"""


def valid_pacs007(rng, orig_uetr, amt, ccy="EGP", msg_id=None, reason="DUPL", rvsl_id=None):
    return f"""{DECL}<Document xmlns="{NS7D['pacs.007.001.10']}">
  <FIToFIPmtRvsl>
    <GrpHdr>
      <MsgId>{msg_id or _mid(rng)}</MsgId>
      <CreDtTm>{T}</CreDtTm>
      <NbOfTxs>1</NbOfTxs>
      <SttlmInf><SttlmMtd>CLRG</SttlmMtd></SttlmInf>
    </GrpHdr>
    <TxInf>
      <RvslId>{rvsl_id or 'RV' + str(rng.randrange(10**9))}</RvslId>
      <OrgnlUETR>{orig_uetr}</OrgnlUETR>
      <RvsdIntrBkSttlmAmt Ccy="{ccy}">{amt}</RvsdIntrBkSttlmAmt>
      <RvslRsnInf><Rsn><Cd>{reason}</Cd></Rsn></RvslRsnInf>
    </TxInf>
  </FIToFIPmtRvsl>
</Document>
"""


def valid_pain007(rng, orig_e2e, amt, ccy="EGP", msg_id=None, orig_msg_id="PAIN008-1", reason="AM05"):
    return f"""{DECL}<Document xmlns="{NS7D['pain.007.001.10']}">
  <CstmrPmtRvsl>
    <GrpHdr>
      <MsgId>{msg_id or _mid(rng)}</MsgId>
      <CreDtTm>{T}</CreDtTm>
      <NbOfTxs>1</NbOfTxs>
      <InitgPty><Nm>Utility Company</Nm></InitgPty>
    </GrpHdr>
    <OrgnlGrpInf><OrgnlMsgId>{orig_msg_id}</OrgnlMsgId><OrgnlMsgNmId>pain.008.001.08</OrgnlMsgNmId></OrgnlGrpInf>
    <OrgnlPmtInfAndRvsl>
      <OrgnlPmtInfId>PMTINF-1</OrgnlPmtInfId>
      <TxInf>
        <RvslId>RV{rng.randrange(10**9)}</RvslId>
        <OrgnlEndToEndId>{orig_e2e}</OrgnlEndToEndId>
        <RvsdInstdAmt Ccy="{ccy}">{amt}</RvsdInstdAmt>
        <RvslRsnInf><Rsn><Cd>{reason}</Cd></Rsn></RvslRsnInf>
      </TxInf>
    </OrgnlPmtInfAndRvsl>
  </CstmrPmtRvsl>
</Document>
"""


def valid_pacs029(rng, cycle, movements, msg_id=None, instr_id=None):
    """movements: [(bic, ccy, amount_text, 'DBIT'|'CRDT')]"""
    recs = ""
    for i, (bic, ccy, amt, side) in enumerate(movements, 1):
        recs += f"""      <MvmntRcrd>
        <Id>MV{i}</Id>
        <Amt><Amt Ccy="{ccy}">{amt}</Amt><CdtDbt>{side}</CdtDbt></Amt>
        <Ptcpt><Id><OrgId><AnyBIC>{bic}</AnyBIC></OrgId></Id></Ptcpt>
      </MvmntRcrd>
"""
    return f"""{DECL}<Document xmlns="{NS7D['pacs.029.001.02']}">
  <MulSttlmReq>
    <GrpHdr>
      <MsgId>{msg_id or _mid(rng)}</MsgId>
      <CreDtTm>{T}</CreDtTm>
      <NbOfSttlmReqs>1</NbOfSttlmReqs>
      <SttlmInf><SttlmMtd>CLRG</SttlmMtd></SttlmInf>
    </GrpHdr>
    <SttlmReq>
      <InstrId>{instr_id or 'INSTR' + str(rng.randrange(10**9))}</InstrId>
      <SttlmCycl>{cycle}</SttlmCycl>
      <NbOfMvmntRcrds>{len(movements)}</NbOfMvmntRcrds>
{recs}    </SttlmReq>
  </MulSttlmReq>
</Document>
"""


def valid_pain009(rng, mandate_id, cdtr_bic, dbtr_bic, dbtr_iban="EG380019000500000000263180002", max_amt="500.00", ccy="EGP", seq="RCUR", msg_id=None):
    return f"""{DECL}<Document xmlns="{NS7D['pain.009.001.07']}">
  <MndtInitnReq>
    <GrpHdr>
      <MsgId>{msg_id or _mid(rng)}</MsgId>
      <CreDtTm>{T}</CreDtTm>
      <InitgPty><Nm>Utility Company</Nm></InitgPty>
    </GrpHdr>
    <Mndt>
      <MndtId>{mandate_id}</MndtId>
      <MndtReqId>REQ{rng.randrange(10**9)}</MndtReqId>
      <Tp><SvcLvl><Cd>SEPA</Cd></SvcLvl><LclInstrm><Cd>CORE</Cd></LclInstrm></Tp>
      <Ocrncs><SeqTp>{seq}</SeqTp><Frqcy><Tp>MNTH</Tp></Frqcy><FrstColltnDt>2026-10-01</FrstColltnDt></Ocrncs>
      <TrckgInd>false</TrckgInd>
      <MaxAmt Ccy="{ccy}">{max_amt}</MaxAmt>
      <Cdtr><Nm>Utility Company</Nm></Cdtr>
      <CdtrAcct><Id><Othr><Id>ACC{rng.randrange(10**8)}</Id></Othr></Id></CdtrAcct>
      <CdtrAgt><FinInstnId><BICFI>{cdtr_bic}</BICFI></FinInstnId></CdtrAgt>
      <Dbtr><Nm>Household {rng.randrange(1000)}</Nm></Dbtr>
      <DbtrAcct><Id><IBAN>{dbtr_iban}</IBAN></Id></DbtrAcct>
      <DbtrAgt><FinInstnId><BICFI>{dbtr_bic}</BICFI></FinInstnId></DbtrAgt>
    </Mndt>
  </MndtInitnReq>
</Document>
"""


def valid_pain010(rng, mandate_id, max_amt="750.00", ccy="EGP", reason="MD16", msg_id=None):
    return f"""{DECL}<Document xmlns="{NS7D['pain.010.001.07']}">
  <MndtAmdmntReq>
    <GrpHdr>
      <MsgId>{msg_id or _mid(rng)}</MsgId>
      <CreDtTm>{T}</CreDtTm>
      <InitgPty><Nm>Utility Company</Nm></InitgPty>
    </GrpHdr>
    <UndrlygAmdmntDtls>
      <AmdmntRsn><Rsn><Cd>{reason}</Cd></Rsn></AmdmntRsn>
      <Mndt>
        <MndtId>{mandate_id}</MndtId>
        <TrckgInd>false</TrckgInd>
        <MaxAmt Ccy="{ccy}">{max_amt}</MaxAmt>
      </Mndt>
      <OrgnlMndt><OrgnlMndtId>{mandate_id}</OrgnlMndtId></OrgnlMndt>
    </UndrlygAmdmntDtls>
  </MndtAmdmntReq>
</Document>
"""


def valid_pain011(rng, mandate_id, reason="MD16", msg_id=None):
    return f"""{DECL}<Document xmlns="{NS7D['pain.011.001.07']}">
  <MndtCxlReq>
    <GrpHdr>
      <MsgId>{msg_id or _mid(rng)}</MsgId>
      <CreDtTm>{T}</CreDtTm>
      <InitgPty><Nm>Utility Company</Nm></InitgPty>
    </GrpHdr>
    <UndrlygCxlDtls>
      <CxlRsn><Rsn><Cd>{reason}</Cd></Rsn></CxlRsn>
      <OrgnlMndt><OrgnlMndtId>{mandate_id}</OrgnlMndtId></OrgnlMndt>
    </UndrlygCxlDtls>
  </MndtCxlReq>
</Document>
"""


def valid_pain012(rng, mandate_id, accepted=True, reason="MD01", msg_id=None):
    rj = "" if accepted else f"<RjctRsn><Cd>{reason}</Cd></RjctRsn>"
    return f"""{DECL}<Document xmlns="{NS7D['pain.012.001.07']}">
  <MndtAccptncRpt>
    <GrpHdr>
      <MsgId>{msg_id or _mid(rng)}</MsgId>
      <CreDtTm>{T}</CreDtTm>
      <InitgPty><Nm>Debtor Bank</Nm></InitgPty>
    </GrpHdr>
    <UndrlygAccptncDtls>
      <AccptncRslt><Accptd>{'true' if accepted else 'false'}</Accptd>{rj}</AccptncRslt>
      <OrgnlMndt><OrgnlMndtId>{mandate_id}</OrgnlMndtId></OrgnlMndt>
    </UndrlygAccptncDtls>
  </MndtAccptncRpt>
</Document>
"""


def valid_camt060(rng, owner_bic, account_iban=None, account_other=None, kind="camt.052.001.08", from_date=D, to_date=D, msg_id=None, req_id=None):
    acct = f"<Acct><Id><IBAN>{account_iban}</IBAN></Id></Acct>" if account_iban else (f"<Acct><Id><Othr><Id>{account_other}</Id></Othr></Id></Acct>" if account_other else "")
    return f"""{DECL}<Document xmlns="{NS7D['camt.060.001.05']}">
  <AcctRptgReq>
    <GrpHdr>
      <MsgId>{msg_id or _mid(rng)}</MsgId>
      <CreDtTm>{T}</CreDtTm>
    </GrpHdr>
    <RptgReq>
      <Id>{req_id or 'RQ' + str(rng.randrange(10**9))}</Id>
      <ReqdMsgNmId>{kind}</ReqdMsgNmId>
      {acct}
      <AcctOwnr><Agt><FinInstnId><BICFI>{owner_bic}</BICFI></FinInstnId></Agt></AcctOwnr>
      <RptgPrd><FrToDt><FrDt>{from_date}</FrDt><ToDt>{to_date}</ToDt></FrToDt><Tp>ALLL</Tp></RptgPrd>
    </RptgReq>
  </AcctRptgReq>
</Document>
"""


def valid_camt057(rng, account_other, items, msg_id=None, ntf_id=None):
    """items: [(item_id, uetr, amount_text, ccy, dbtr_bic)]"""
    body = ""
    for iid, u, amt, ccy, bic in items:
        body += f"""      <Itm>
        <Id>{iid}</Id>
        <EndToEndId>E2E-{iid}</EndToEndId>
        <UETR>{u}</UETR>
        <Amt Ccy="{ccy}">{amt}</Amt>
        <XpctdValDt>{D}</XpctdValDt>
        <DbtrAgt><FinInstnId><BICFI>{bic}</BICFI></FinInstnId></DbtrAgt>
      </Itm>
"""
    return f"""{DECL}<Document xmlns="{NS7D['camt.057.001.06']}">
  <NtfctnToRcv>
    <GrpHdr>
      <MsgId>{msg_id or _mid(rng)}</MsgId>
      <CreDtTm>{T}</CreDtTm>
    </GrpHdr>
    <Ntfctn>
      <Id>{ntf_id or 'NTF' + str(rng.randrange(10**9))}</Id>
      <Acct><Id><Othr><Id>{account_other}</Id></Othr></Id></Acct>
{body}    </Ntfctn>
  </NtfctnToRcv>
</Document>
"""


def valid_camt050(rng, amt, ccy="EGP", dbtr_bic=None, cdtr_bic=None, e2e=None, msg_id=None):
    dbtr = f"<Dbtr><FinInstnId><BICFI>{dbtr_bic}</BICFI></FinInstnId></Dbtr>" if dbtr_bic else ""
    cdtr = f"<Cdtr><FinInstnId><BICFI>{cdtr_bic}</BICFI></FinInstnId></Cdtr>" if cdtr_bic else ""
    return f"""{DECL}<Document xmlns="{NS7D['camt.050.001.05']}">
  <LqdtyCdtTrf>
    <MsgHdr><MsgId>{msg_id or _mid(rng)}</MsgId><CreDtTm>{T}</CreDtTm></MsgHdr>
    <LqdtyCdtTrf>
      <LqdtyTrfId><EndToEndId>{e2e or 'LQ' + str(rng.randrange(10**9))}</EndToEndId></LqdtyTrfId>
      {cdtr}
      <TrfdAmt><AmtWthCcy Ccy="{ccy}">{amt}</AmtWthCcy></TrfdAmt>
      {dbtr}
      <SttlmDt>{D}</SttlmDt>
    </LqdtyCdtTrf>
  </LqdtyCdtTrf>
</Document>
"""


def valid_investigation(rng, family, assigner_bic, assignee_bic, orig_uetr, amt="100.00", ccy="EGP", case_id=None, assignment_id=None):
    root = {"camt.026.001.07": "UblToApply", "camt.027.001.07": "ClmNonRct", "camt.028.001.09": "AddtlPmtInf", "camt.087.001.06": "ReqToModfyPmt"}[family]
    tail = {
        "camt.026.001.07": "<Justfn><MssngOrIncrrctInf><MssngInf><Cd>MS01</Cd></MssngInf></MssngOrIncrrctInf></Justfn>",
        "camt.027.001.07": "",
        "camt.028.001.09": "<Inf><InstrForNxtAgt><InstrInf>please apply</InstrInf></InstrForNxtAgt></Inf>",
        "camt.087.001.06": f"<Mod><IntrBkSttlmAmt Ccy=\"{ccy}\">{amt}</IntrBkSttlmAmt></Mod>",
    }[family]
    return f"""{DECL}<Document xmlns="{NS7D[family]}">
  <{root}>
    <Assgnmt>
      <Id>{assignment_id or 'ASG' + str(rng.randrange(10**9))}</Id>
      <Assgnr><Agt><FinInstnId><BICFI>{assigner_bic}</BICFI></FinInstnId></Agt></Assgnr>
      <Assgne><Agt><FinInstnId><BICFI>{assignee_bic}</BICFI></FinInstnId></Agt></Assgne>
      <CreDtTm>{T}</CreDtTm>
    </Assgnmt>
    <Case><Id>{case_id or 'CASE' + str(rng.randrange(10**9))}</Id><Cretr><Agt><FinInstnId><BICFI>{assigner_bic}</BICFI></FinInstnId></Agt></Cretr></Case>
    <Undrlyg><IntrBk>
      <OrgnlGrpInf><OrgnlMsgId>MSG-ORIG</OrgnlMsgId><OrgnlMsgNmId>pacs.008.001.08</OrgnlMsgNmId></OrgnlGrpInf>
      <OrgnlUETR>{orig_uetr}</OrgnlUETR>
      <OrgnlIntrBkSttlmAmt Ccy="{ccy}">{amt}</OrgnlIntrBkSttlmAmt>
      <OrgnlIntrBkSttlmDt>{D}</OrgnlIntrBkSttlmDt>
    </IntrBk></Undrlyg>
    {tail}
  </{root}>
</Document>
"""


def valid_admi006(rng, recipient_bic, sequence_number, orig_msg_name="pacs.002.001.10", msg_id=None):
    return f"""{DECL}<Document xmlns="{NS7D['admi.006.001.01']}">
  <RsndReq>
    <MsgHdr><MsgId>{msg_id or _mid(rng)}</MsgId><CreDtTm>{T}</CreDtTm></MsgHdr>
    <RsndSchCrit>
      <BizDt>{D}</BizDt>
      <SeqNb>{sequence_number}</SeqNb>
      <OrgnlMsgNmId>{orig_msg_name}</OrgnlMsgNmId>
      <Rcpt><Id><AnyBIC>{recipient_bic}</AnyBIC></Id></Rcpt>
    </RsndSchCrit>
  </RsndReq>
</Document>
"""


def valid_admi017(rng, request_type="EODP", requester_bic=None, msg_id=None, session=None):
    rq = f"<RqstrId><AnyBIC><AnyBIC>{requester_bic}</AnyBIC></AnyBIC></RqstrId>" if requester_bic else ""
    ss = f"<SttlmSsnIdr>{session}</SttlmSsnIdr>" if session else ""
    return f"""{DECL}<Document xmlns="{NS7D['admi.017.001.01']}">
  <PrcgReq>
    <MsgId>{msg_id or _mid(rng)}</MsgId>
    {ss}
    <Req><Tp>{request_type}</Tp>{rq}<AddtlReqInf>run end of day</AddtlReqInf></Req>
  </PrcgReq>
</Document>
"""


def valid_head002(rng, payload_xmls, payload_id=None, payload_type="pacs.008.001.08"):
    """payload_xmls: documents (or AppHdr elements) as text without the XML declaration"""
    pl = "".join(f"  <Pyld>{x.replace(DECL, '').strip()}</Pyld>\n" for x in payload_xmls)
    return f"""{DECL}<Xchg xmlns="{NS7D['head.002.001.01']}">
  <PyldDesc>
    <PyldData><PyldIdr>{payload_id or 'FILE' + str(rng.randrange(10**9))}</PyldIdr><CreDtAndTm>{T}</CreDtAndTm><PssblDplctFlg>false</PssblDplctFlg></PyldData>
    <ApplSpcfcs><SysUsr>ach-batch</SysUsr><TtlNbOfDocs>{len(payload_xmls)}</TtlNbOfDocs></ApplSpcfcs>
    <PyldTp>{payload_type}</PyldTp>
    <MnfstData><DocTp>{payload_type}</DocTp><NbOfDocs>{len(payload_xmls)}</NbOfDocs></MnfstData>
  </PyldDesc>
{pl}</Xchg>
"""


# the families the bank emits: the templates are what the battery parses back, not what it sends
def valid_camt052(rng, account_other="ACC1", ccy="EGP"):
    return f"""{DECL}<Document xmlns="{NS7D['camt.052.001.08']}">
  <BkToCstmrAcctRpt>
    <GrpHdr><MsgId>{_mid(rng)}</MsgId><CreDtTm>{T}</CreDtTm></GrpHdr>
    <Rpt>
      <Id>RPT{rng.randrange(10**9)}</Id>
      <CreDtTm>{T}</CreDtTm>
      <Acct><Id><Othr><Id>{account_other}</Id></Othr></Id><Ccy>{ccy}</Ccy></Acct>
      <Bal><Tp><CdOrPrtry><Cd>ITBD</Cd></CdOrPrtry></Tp><Amt Ccy="{ccy}">{amount(rng)}</Amt><CdtDbtInd>CRDT</CdtDbtInd><Dt><Dt>{D}</Dt></Dt></Bal>
      <Ntry><Amt Ccy="{ccy}">{amount(rng)}</Amt><CdtDbtInd>DBIT</CdtDbtInd><Sts><Cd>BOOK</Cd></Sts><BookgDt><Dt>{D}</Dt></BookgDt><BkTxCd><Prtry><Cd>PMNT</Cd></Prtry></BkTxCd></Ntry>
    </Rpt>
  </BkToCstmrAcctRpt>
</Document>
"""


def valid_camt025(rng, orig_msg_id="MSG1", status="ACPT"):
    return f"""{DECL}<Document xmlns="{NS7D['camt.025.001.05']}">
  <Rct>
    <MsgHdr><MsgId>{_mid(rng)}</MsgId><CreDtTm>{T}</CreDtTm></MsgHdr>
    <RctDtls><OrgnlMsgId><MsgId>{orig_msg_id}</MsgId><MsgNmId>camt.050.001.05</MsgNmId></OrgnlMsgId><ReqHdlg><StsCd>{status}</StsCd><Desc>received</Desc></ReqHdlg></RctDtls>
  </Rct>
</Document>
"""


def valid_admi007(rng, ref="MSG1", status="ACPT"):
    return f"""{DECL}<Document xmlns="{NS7D['admi.007.001.01']}">
  <RctAck>
    <MsgId><MsgId>{_mid(rng)}</MsgId><CreDtTm>{T}</CreDtTm></MsgId>
    <Rpt><RltdRef><Ref>{ref}</Ref></RltdRef><ReqHdlg><StsCd>{status}</StsCd><StsDtTm>{T}</StsDtTm><Desc>acknowledged</Desc></ReqHdlg></Rpt>
  </RctAck>
</Document>
"""
