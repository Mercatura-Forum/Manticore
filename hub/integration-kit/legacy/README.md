# Legacy-System Integration Notes

Native canister routes today:

- `mt103`: parsed by `decodeMt103` or submitted through
  `submitTransportEnvelope(format = "mt103")`.
- `mt940`: parsed by `decodeMt940` or submitted through
  `submitTransportEnvelope(format = "mt940")`.
- `mt942`: parsed by `decodeMt942` or submitted through
  `submitTransportEnvelope(format = "mt942")`.
- `csv.payments`: parsed by `decodeCsvPayments` or submitted through
  `submitTransportEnvelope(format = "csv.payments")`.
- `fixed.payments`: parsed by `decodeFixedWidthPayments` or submitted through
  `submitTransportEnvelope(format = "fixed.payments")`.

Documented adapter patterns:

- Bank-specific CSV/fixed-width variants: normalize to the education layout or
  add a signed profile pack before submission.
- SFTP/file-drop: treat every file as a connector envelope with monotonic
  sequence, `remoteId`, `traceId`, payload hash, and ACK/NACK receipt.

## MT103 Coverage

The parser already handles the tag grammar generically and maps the supported
payment subset into `pain.001`:

| MT field | Current behavior |
| --- | --- |
| `20` | message id |
| `32A` | value date, currency, amount |
| `50A/F/K` | debtor party/account lines when present |
| `52A` | debtor agent BIC |
| `52D` | parsed as a field, but requires a BIC-bearing line to become routable |
| `53A/B/D`, `54A/B/D`, `56A/D` | parsed as fields and preserved as remittance evidence when a value is present |
| `57A` | creditor agent BIC |
| `57D` | parsed as a field, but requires a BIC-bearing line to become routable |
| `59/F` | creditor party/account lines when present |
| `70` | remittance text |
| `71A` | charge bearer mapping: OUR/BEN/SHA to DEBT/CRED/SHAR note |
| `72` | preserved as sender-to-receiver remittance evidence |

## The MT bridge (13 types)

`motoko/iso/MtBridge.mo` reads and writes full FIN messages (blocks 1–4) for
MT101, MT103, MT104, MT202, MT202 COV, MT900, MT910, MT940, MT942, MT950,
MT192, MT196 and MT199. Each type's field-to-element table is data in the
canister (`mtBridgeMappings`) and in `mt-mappings.json` here, written by
`scripts/mt-bridge-roundtrip.py` from the canister's table so the two cannot
drift (`--check-mappings` fails the run if they do). What an MT type does not
carry and a record requires is a documented convention in the table's `note`
column; never a guess in code.

Fixtures: `mt/*.fin` (two per type, `mt-manifest.json`). Proven by the runner
for every fixture: MT → record → MT → record equal; record → XML → record equal
(the compact codec, or the schema-profile codec for camt.052 with xmllint on the
written document); Prowide swift-core parses both the fixture and what the
bridge wrote as the same type with the same field 20 / 21 / 32A / UETR.

Routes: `submitTransportEnvelope(format = "mt")` reads the type from block 2;
`"mt202"`, `"mt202cov"`, … assert it (`MT-TYPE-MISMATCH` when block 2 says
otherwise). The `mt103`, `mt940` and `mt942` routes above are unchanged.
