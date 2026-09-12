# Stable Rule IDs For Integration Tests

| Fixture or replay | Expected rule id |
| --- | --- |
| `xml/invalid/xml-doctype-entity.xml` | `XML-UNSAFE-DECL` |
| an XML declaration anywhere but the start of the document (after an element, whitespace or a comment) | `XML-DECL-POSITION` |
| a second XML declaration | `XML-DECL-DUPLICATE` |
| a byte-order mark inside the document | `XML-BOM-POSITION` |
| `xml/invalid/status-uetr-mismatch.xml` after original payment exists | `STATUS-UETR-MISMATCH` |
| replay `xml/valid/status-pacs002-settled.xml` after it was applied once | `STATUS-PACS002-DUPLICATE` |
| submit `pacs.004.xml` before payment is settled/dispatched | `STATUS-PACS004-LIFECYCLE` |
| connector sequence jump | `TRANSPORT-SEQUENCE-GAP` |
| connector old sequence | `TRANSPORT-DUPLICATE-SEQUENCE` |
| repeated connector `remoteId` | `TRANSPORT-DUPLICATE-REMOTE-ID` |
| wrong `payloadHash` | `TRANSPORT-CHECKSUM-MISMATCH` |
| unsupported connector format | `TRANSPORT-UNSUPPORTED-FORMAT` |
| allowed but unrouted format | `TRANSPORT-ROUTE-MISSING` |
| direct debit message kind outside `pain.008`/`pacs.003` | `DD-KIND` |
| direct debit missing collection date | `DD-COLLECTION-DATE-REQUIRED` |
| direct debit invalid sequence type | `DD-SEQUENCE-TYPE` |
| `pacs.003` missing settlement instruction | `DD-STTLM-REQUIRED` |
| `pacs.003` missing UETR when guideline requires it | `DD-UETR-REQUIRED` |
| administrative message kind outside supported `admi` family | `ADMI-KIND` |
| `admi.002` status other than `RJCT` | `ADMI002-STATUS` |
| `admi.007` or `admi.011` status other than `ACK` | `ADMI-ACK-STATUS` |
| `admi.004` status outside `INFO`/`ACK` | `ADMI004-STATUS` |
| `pain.013` carrying an original request id | `RTP-ORIGINAL-UNEXPECTED` |
| `pain.013` carrying a response status | `RTP-STATUS-UNEXPECTED` |
| `pain.014` or `camt.055` missing original request id | `RTP-ORIGINAL-REQUIRED` |
| `pain.014` or `camt.055` missing status | `RTP-STATUS-REQUIRED` |
| `pain.014` status outside ACTC/RJCT/PDNG | `RTP-STATUS` |
| `camt.055` status other than CANC | `RTP-CANCEL-STATUS` |
| MT103 missing `32A` | `MT103-32A-REQUIRED` |
| MT103 bad amount | `MT103-32A-AMOUNT` |

## The schema-profile codec, the MT bridge, the rule sets

| Fixture or situation | Expected rule id |
| --- | --- |
| `xml/invalid/*` of `xml/breadth-manifest.json` (tier `schema`) | `ISO-XSD-ROOT`, `ISO-XSD-UNEXPECTED`, `ISO-XSD-MISSING`, `ISO-XSD-LENGTH`, `ISO-XSD-PATTERN`, `ISO-XSD-ENUM`, `ISO-XSD-BOOLEAN`, `XML-UNSAFE-DECL` — the manifest names each fixture's |
| the same manifest, tier `business` | `ISO-BIZ-COUNT`, `ISO-BIZ-AMOUNT`, `ISO-BIZ-CURRENCY`, `ISO-BIZ-UETR-REQUIRED`, `ISO-BIZ-AGENT-BIC`, `ISO-BIZ-REQUIRED` |
| a record a writer cannot place in its family's shape (`encodeIsoBreadth`) | `ISO-BIZ-REQUIRED`, `ISO-BIZ-CURRENCY`, `ISO-BIZ-FAMILY` |
| a written document that does not read back equal (`roundTripIsoBreadth`) | `ROUNDTRIP-EQUALITY`, `ROUNDTRIP-<rule>` |
| an MT message without block 2 and without a hint | `MT-TYPE` |
| an MT type outside the bridge's thirteen | `MT-UNSUPPORTED` |
| a FIN whose block 2 contradicts the route's format | `MT-TYPE-MISMATCH` |
| a bridge field missing or malformed | `MT<type>-<field>-REQUIRED`, `-DATE`, `-CURRENCY`, `-AMOUNT`, `-BIC`, `-FORMAT` (e.g. `MT104-21C-REQUIRED`, `MT202-58A-REQUIRED`, `MT942-13D-FORMAT`) |
| `xml/guidelines/*` of `xml/guidelines-manifest.json` | the CBPR+ / HVPS+ rule ids the manifest names (`CBPR-…`, `HVPS-…`), under the `usageGuideline` tier |
| a rule set id the canister does not carry | `RULESET-UNKNOWN` |

