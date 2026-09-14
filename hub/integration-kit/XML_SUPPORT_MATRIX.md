# XML Support Matrix

The canister carries two codecs. The **compact codec** (`motoko/ISO20022Xml.mo`) reads and writes the
twenty-two families below in a deterministic subset shape; it is what the payment flows run on. The
**schema-profile codec** (`motoko/iso/IsoBreadth.mo` over `motoko/iso/IsoSchema.mo` and the generated
`motoko/iso/IsoProfiles.mo`) validates a message against the official ISO 20022 XSD; all 43 families the
canister knows, as generated profiles; before reading it, and writes its twenty families back schema-valid.
The legacy MT bridge (`motoko/iso/MtBridge.mo`) and the CBPR+ / HVPS+ rule sets (`motoko/iso/RuleSets.mo`)
sit on those.

## The compact codec (22 families)

| Format | Route | Decode API | Validation/Application | Status |
| --- | --- | --- | --- | --- |
| `pain.001.xml` | `submitTransportEnvelope` | `decodePain001Xml` | `validatePain001Xml`, `submitPain001Xml` | implemented compact |
| `pain.008.xml` | `submitTransportEnvelope` | `decodeDirectDebitXml` | `validateDirectDebitXml` | implemented compact |
| `pacs.003.xml` | `submitTransportEnvelope` | `decodeDirectDebitXml` | `validateDirectDebitXml` | implemented compact |
| `pacs.008.xml` | `submitTransportEnvelope` | `decodePacs008Xml` | `validatePacs008Xml`, `auditPacs008Xml` | implemented compact |
| `pacs.009.xml` | `submitTransportEnvelope` | `decodePacs009Xml` | `validatePacs009Xml` | implemented compact |
| `cover.payment.xml` | `submitTransportEnvelope` | `decodeCoverPaymentXml` | `validateCoverPaymentXml` | implemented compact |
| `pain.002.xml` | `submitTransportEnvelope` | `decodeStatusReportXml` | `validateStatusReportXml` | implemented compact |
| `pacs.002.xml` | `submitTransportEnvelope` | `decodeStatusReportXml` | validates then applies payment state | implemented compact |
| `pacs.004.xml` | `submitTransportEnvelope` | `decodeStatusReportXml` | validates then applies return state | implemented compact |
| `camt.056.xml` | `submitTransportEnvelope` | `decodeInvestigationXml` | `validateInvestigationXml` | implemented compact |
| `camt.029.xml` | `submitTransportEnvelope` | `decodeInvestigationXml` | `validateInvestigationXml` | implemented compact |
| `pacs.028.xml` | `submitTransportEnvelope` | `decodeInvestigationXml` | `validateInvestigationXml` | implemented compact |
| `camt.110.xml` | `submitTransportEnvelope` | `decodeInvestigationXml` | `validateInvestigationXml` | implemented compact |
| `camt.111.xml` | `submitTransportEnvelope` | `decodeInvestigationXml` | `validateInvestigationXml` | implemented compact |
| `pain.013.xml` | `submitTransportEnvelope` | `decodeRequestToPayXml` | `validateRequestToPayXml` | implemented compact |
| `pain.014.xml` | `submitTransportEnvelope` | `decodeRequestToPayXml` | `validateRequestToPayXml` | implemented compact |
| `camt.055.xml` | `submitTransportEnvelope` | `decodeRequestToPayXml` | `validateRequestToPayXml` | implemented compact |
| `admi.002.xml` | `submitTransportEnvelope` | `decodeAdministrativeXml` | `validateAdministrativeXml` | implemented compact |
| `admi.004.xml` | `submitTransportEnvelope` | `decodeAdministrativeXml` | `validateAdministrativeXml` | implemented compact |
| `admi.007.xml` | `submitTransportEnvelope` | `decodeAdministrativeXml` | `validateAdministrativeXml` | implemented compact |
| `admi.011.xml` | `submitTransportEnvelope` | `decodeAdministrativeXml` | `validateAdministrativeXml` | implemented compact |
| `camt.053.xml` | `submitTransportEnvelope` | `decodeCamt053Xml` | statement-entry decode | implemented compact |
| `camt.054.xml` | `submitTransportEnvelope` | `decodeCamt054Xml` | notification-entry decode | implemented compact |

## The schema-profile codec (20 families added, 43 schema profiles)

Every message is parsed by the vendored parser (`motoko/iso/Xml.mo`), identified by its root namespace,
validated against the generated profile of its official XSD (rule ids `ISO-XSD-*`), and only then read into a
typed record (rule ids `ISO-BIZ-*`). Records are written back in the official shape. The route is
`submitTransportEnvelope(format = "<family>.xml")`; the queries are `validateIsoBreadth[WithProfile]`,
`decodeIsoBreadth[WithProfile]`, `encodeIsoBreadth`, `roundTripIsoBreadth`, `isoBreadthFamilies`,
`isoSchemaProfiles`, and the general `validateIsoDocument[WithProfile|WithRuleSet]` for any of the 43
profiles, with or without the head.001 AppHdr.

| Family | Version | Record | Written back | Status |
| --- | --- | --- | --- | --- |
| `pacs.007` | 001.10 | `#reversal` | `reversalXml` | official shape |
| `pacs.010` | 001.04 | `#directDebit` | `directDebitXml` | official shape |
| `pacs.029` | 001.02 | `#settlementRequest` | `settlementRequestXml` | official shape |
| `pain.007` | 001.10 | `#reversal` | `reversalXml` | official shape |
| `pain.009` | 001.07 | `#mandateInitiation` | `mandateInitiationXml` | official shape |
| `pain.010` | 001.07 | `#mandateAmendment` | `mandateAmendmentXml` | official shape |
| `pain.011` | 001.07 | `#mandateCancellation` | `mandateCancellationXml` | official shape |
| `pain.012` | 001.07 | `#mandateAcceptance` | `mandateAcceptanceXml` | official shape |
| `camt.052` | 001.08 | `#accountReport` | `accountReportXml` | official shape |
| `camt.057` | 001.06 | `#notificationToReceive` | `notificationToReceiveXml` | official shape |
| `camt.060` | 001.05 | `#reportingRequest` | `reportingRequestXml` | official shape |
| `camt.050` | 001.05 | `#liquidityTransfer` | `liquidityTransferXml` | official shape |
| `camt.025` | 001.05 | `#receipt` | `receiptXml` | official shape |
| `camt.026` | 001.07 | `#investigation` | `investigationXml` | official shape |
| `camt.027` | 001.07 | `#investigation` | `investigationXml` | official shape |
| `camt.028` | 001.09 | `#investigation` | `investigationXml` | official shape |
| `camt.087` | 001.06 | `#investigation` | `investigationXml` | official shape |
| `admi.006` | 001.01 | `#resendRequest` | `resendRequestXml` | official shape |
| `admi.017` | 001.01 | `#processingRequest` | `processingRequestXml` | official shape |
| `head.002` | 001.01 | `#fileHeader` (payloads each validated against their own schema) | `fileHeaderXml` | official shape |

Evidence (`integration-kit/scripts/`): `iso-breadth-fixtures.py` writes the corpus (24 valid, 25 invalid with
rule ids) and the mops test `motoko/test/IsoBreadth.test.mo`; `iso-breadth-roundtrip.py` reads every valid
fixture, writes it back, checks the written document with `xmllint --schema` against the official XSD, reads it
again equal, and cross-parses it with Prowide `pw-iso20022` (23 of 24; head.002 is an envelope Prowide has no
MX class for); `iso-breadth-mutations.py` judges 3,600 mutants of the valid fixtures by xmllint and by the
canister's profile; zero disagreements (`profile-runner/breadth-mutations-report.json`).

## The legacy MT bridge (13 types)

`motoko/iso/MtBridge.mo`; route `submitTransportEnvelope(format = "mt" | "mt101" | "mt104" | "mt202" |
"mt202cov" | "mt900" | "mt910" | "mt950" | "mt192" | "mt196" | "mt199")` (the older `mt103`, `mt940`, `mt942`
routes of `LegacyMT.mo` are unchanged); queries `decodeMt[WithProfile]`, `encodeMt`, `mtBridgeTypes`,
`mtBridgeMappings`. The field-to-element mapping tables are data in the canister and in
`integration-kit/legacy/mt-mappings.json` (written from the canister's table by the runner).

| MT | ISO record | Round trips proven |
| --- | --- | --- |
| MT101 | `pain.001` (one per sequence B) | MT → record → MT; record → XML → record; Prowide swift-core |
| MT103 | `pain.001` | same |
| MT104 | `pain.008` (one per sequence B) | same |
| MT202 | `pacs.009` | same |
| MT202 COV | `pacs.009` COV + underlying `pacs.008` (`CoverPayment`) | same |
| MT900 / MT910 | `camt.054` entry (debit / credit) | same |
| MT940 / MT950 | `camt.053` entries | same |
| MT942 | `camt.052` report (schema-profile codec; the written XML is xmllint-valid) | same |
| MT192 / MT196 / MT199 | `camt.056` / `camt.029` / `camt.110` investigation | same |

Evidence: `mt-bridge-fixtures.py` (26 FIN fixtures, `motoko/test/MtBridge.test.mo`), `mt-bridge-roundtrip.py`
(`profile-runner/mt-bridge-report.json`: 26/26 on every check, Prowide on the fixtures and on what the bridge
wrote, with field 20 / 21 / 32A / UETR agreeing).

## Market-practice rule sets (CBPR+, HVPS+)

`motoko/iso/RuleSets.mo`: rules as data over a closed check vocabulary, evaluated after the official schema
passed, under the `usageGuideline` tier with the rule's own id. The `CBPRPLUS-EDU` guideline profile is bound
to the `CBPRPLUS` set (`guidelineRuleSet`, `bindGuidelineRuleSet`); `isoRuleSets` and `isoRuleSetRules` print
the sets; `validateIsoDocumentWithRuleSet` applies one explicitly.

| Set | Families | Rules | Basis |
| --- | --- | --- | --- |
| `CBPRPLUS` | pacs.008, pacs.009, pacs.002, pacs.004, camt.053, camt.054, camt.056, camt.029 | 35 | Swift ISO 20022 programme pages, the CBPR+ User Handbook's published structure, PMPG papers (structured addresses, FIN X identifiers) |
| `HVPSPLUS` | pacs.008, pacs.009, pacs.002, camt.050, camt.052, camt.053 | 20 | HVPS+ practice as RTGS operators publish it (ECB T2, Bank of England CHAPS, Fed/TCH), Swift programme pages |

**Stated limitation.** The usage guidelines themselves; on SWIFT MyStandards, with their rule identifiers;
are access-controlled; this harness could not fetch them. The rule ids are the hub's; the reconciliation with
MyStandards identifiers has not been performed and each set says so in its `reconciliation` field. Evidence:
`usage-guideline-fixtures.py` (14 conforming, 54 violating fixtures, `motoko/test/RuleSets.test.mo`),
`usage-guideline-check.py` (prints the implemented counts before and after; every rule exercised by a violation
fixture; `integration-kit/profiles/CBPRPLUS-RULES.json`, `HVPSPLUS-RULES.json` written from the canister).

## What the compact codec still is

The compact codec (the 22 families of the first table) keeps its strict subset:

- known message roots and paths only
- deterministic serializer output
- DTD/entity/external identifier rejection
- bounded raw XML size through `UsageGuideline.maxMessageBytes`
- stable rule IDs for negative fixtures

Its fixtures are not valid under the official XSDs (21 of 25 fail `xsd-profile-runner.py`, as
`profile-runner/XSD_VALIDATION_CHECKPOINT.md` records); the same 22 families are validated in the official
shape by the schema-profile codec's `validateIsoDocument`, which carries all 43 generated profiles. Not yet
here: a canonical XML semantic hash, a namespace/version drift corpus, and official market-rule certification
evidence (which needs the MyStandards guidelines).
