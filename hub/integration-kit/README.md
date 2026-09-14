# ISO 20022 Integration Kit

This kit is the hands-on entry point for banks, fintechs, middleware teams, and
legacy-file integrators.

The canister carries the compact codec for the message families of the first
table in `XML_SUPPORT_MATRIX.md`, and the schema-profile codec; the official
ISO 20022 XSDs as generated profiles (43 families), twenty of them read into
typed records and written back schema-valid; together with the MT bridge
(13 FIN types) and the CBPR+ / HVPS+ rule sets. Every claim in the matrix has
its runner in `scripts/` and its report in `profile-runner/`.

## Contents

- `xml/valid`: XML files that decode; the compact-profile fixtures, and the
  official-shape fixtures of the schema-profile codec (`breadth-manifest.json`
  names them with their xmllint verdicts).
- `xml/invalid`: XML and replay fixtures expected to dead-letter or fail with
  stable rule IDs (the schema-profile ones carry their tier and rule id in the
  manifest).
- `xml/guidelines`: CBPR+ and HVPS+ conforming messages with their AppHdr, and
  one violation per rule (`guidelines-manifest.json`).
- `connectors`: Candid envelope templates, registration snippets, batch manifest
  format, and file-drop adapter notes.
- `legacy`: MT103, MT940/MT942, CSV, and fixed-width examples; `legacy/mt/` the
  FIN fixtures of the thirteen bridge types and `legacy/mt-mappings.json` the
  field-to-element tables as the canister carries them.
- `profiles`: named profile-pack metadata for local, legacy, SEPA, Fedwire,
  FedNow, and CPMI research overlays.
- `candid`: copyable `thebes-deploy` call/query snippets and the `.did` interface.
- `expected`: expected statuses and rule IDs for replay checks.
- `cookbooks`: operator flows such as file intake, status return, outbound
  leasing, and dead-letter repair.
- `profile-runner`: external XSD/profile runner map for full XML evidence.
- `fixtures`: signed fixture-bundle hash manifest and verification key.

## Current Truth

Implemented compact XML routes:

- `pain.001.xml`
- `pain.008.xml`
- `pacs.003.xml`
- `pacs.008.xml`
- `pacs.009.xml`
- `cover.payment.xml`
- `pain.002.xml`
- `pacs.002.xml`
- `pacs.004.xml`
- `camt.056.xml`
- `camt.029.xml`
- `pacs.028.xml`
- `camt.110.xml`
- `camt.111.xml`
- `pain.013.xml`
- `pain.014.xml`
- `camt.055.xml`
- `admi.002.xml`
- `admi.004.xml`
- `admi.007.xml`
- `admi.011.xml`
- `camt.053.xml`
- `camt.054.xml`

Implemented schema-profile routes (official shape, validated against the XSD
before reading): `pacs.007.xml`, `pacs.010.xml`, `pacs.029.xml`, `pain.007.xml`,
`pain.009.xml`, `pain.010.xml`, `pain.011.xml`, `pain.012.xml`, `camt.052.xml`,
`camt.057.xml`, `camt.060.xml`, `camt.050.xml`, `camt.025.xml`, `camt.026.xml`,
`camt.027.xml`, `camt.028.xml`, `camt.087.xml`, `admi.006.xml`, `admi.017.xml`,
`head.002.xml`.

Implemented legacy routes:

- `mt103`, `mt940`, `mt942` (the compact legacy parsers)
- `mt`, `mt101`, `mt104`, `mt202`, `mt202cov`, `mt900`, `mt910`, `mt950`,
  `mt192`, `mt196`, `mt199` (the MT bridge; `mt` reads the type from block 2)
- `csv.payments`
- `fixed.payments`

Documented adapter patterns, not native canister parsers yet:

- SFTP/file-drop batch transport
- bank-specific CSV/fixed-width variants beyond the education layout
- SWIFT MT options beyond those in `legacy/mt-mappings.json` (the bridge refuses
  an unsupported type or field with a stable rule id rather than guessing)
- rail-specific acknowledgement SLA/state beyond compact `admi` validation and
  C7 workflow correlation

## Minimal Replay Order

1. Register a connector that allows the target format.
2. Submit `xml/valid/pain001-eg-domestic.xml` as `pain.001.xml`.
3. Dispatch the stored payment with `dispatchPacs008(paymentId)`.
4. Submit `xml/valid/status-pacs002-settled.xml` as `pacs.002.xml`.
5. Submit `xml/invalid/status-uetr-mismatch.xml` as `pacs.002.xml` and confirm
   `STATUS-UETR-MISMATCH`.
6. Submit the same valid `pacs.002.xml` again and confirm
   `STATUS-PACS002-DUPLICATE`.
7. Query `paymentXmlBundle(paymentId)`, `camt054Notification(paymentId)`,
   `auditProof(auditId)`, and `secondaryIndexHealth()`.

Use `expected/replay-results.md` as the operator checklist.

## External Profile Evidence

Fetch public ISO base XSDs:

```sh
integration-kit/scripts/iso-xsd-fetch.py
```

List the required official schema files and their public/account-gated source
packs:

```sh
integration-kit/scripts/xsd-profile-runner.py --list-required-schemas
```

Run XSD/profile checks with supplied official schemas:

```sh
integration-kit/scripts/xsd-profile-runner.py \
  --schema-dir /path/to/iso20022/xsd \
  --require-all-schemas \
  --strict-source-manifest
```

`profile-runner/source-manifest.json` records official-source provenance and
operator actions. It is metadata only; the repo still expects the certification
environment to supply ISO, Swift/MyStandards, EPC, Federal Reserve, CBE/EBC, or
bank-specific artifacts.

Current checkpoint: the public ISO base XSDs (43 files) are downloaded locally
and the runner judges every fixture of `profile-runner/profile-map.json` against
its expectation. The report is `profile-runner/profile-report.json`: the 117
official-shape fixtures (schema-profile codec, CBPR+, HVPS+) all agree with
their expectation; the 21 compact-codec fixtures of the original corpus are
still not valid under the official XSDs, as the checkpoint records; the same
families are validated in the official shape through `validateIsoDocument`.

The schema-profile codec, the MT bridge and the rule sets have their own
runners, each exiting non-zero on the first disagreement:

```sh
integration-kit/scripts/iso-breadth-fixtures.py      # the corpus + motoko/test/IsoBreadth.test.mo
integration-kit/scripts/iso-breadth-roundtrip.py     # read → write → xmllint → read again → Prowide
integration-kit/scripts/iso-breadth-mutations.py     # 3,600 mutants: xmllint vs the canister's profile
integration-kit/scripts/mt-bridge-fixtures.py        # 26 FIN fixtures + motoko/test/MtBridge.test.mo
integration-kit/scripts/mt-bridge-roundtrip.py       # MT ↔ record ↔ XML, Prowide swift-core, mapping tables
integration-kit/scripts/usage-guideline-fixtures.py  # CBPR+/HVPS+ corpus + motoko/test/RuleSets.test.mo
integration-kit/scripts/usage-guideline-check.py     # implemented counts, every rule exercised, rule tables
integration-kit/scripts/iso-profile-gen.py           # regenerates motoko/iso/IsoProfiles.mo from the XSDs
```

The Prowide jars (`pw-iso20022` and `pw-swift-core`, SRU2025) are read from
`PROWIDE_JARS` (default `$ORACLES/iso20022`); without them the
round-trip runners report the Prowide checks as not run and exit non-zero.

## Deployed Canister Replay

Run the actor-level replay harness against a deployed canister or local alias:

```sh
integration-kit/scripts/deployed-replay.py --canister iso20022 --dry-run
integration-kit/scripts/deployed-replay.py --canister iso20022
```

Deploy and smoke-test against the cluster:

```sh
thebes-deploy --manifest thebes.toml deploy iso20022
thebes-deploy --manifest thebes.toml call iso20022 claimOwner
integration-kit/scripts/deployed-replay.py --canister iso20022
```

If a live replay stops after creating a payment, resume without submitting a
duplicate `pain.001`:

```sh
integration-kit/scripts/deployed-replay.py \
  --canister iso20022 \
  --payment-id 0 \
  --skip-dispatch
```

The harness calls discovery/readiness queries, validates XML fixture blobs
through canister query methods, registers the file connector, submits a real
`pain.001` fixture, dispatches the generated `pacs.008`, submits valid and
mismatched `pacs.002` connector envelopes, then queries payment phases, XML
bundle evidence, audit tip, secondary-index health, and dead letters.

The runtime canister has one active guideline at a time. Public SEPA/CBPR+/Fedwire
education fixtures may return expected country/settlement-method errors when the
default Egypt guideline is active; treat that as profile-selection evidence, not
as a deployment failure.

## C6 Certified Disclosure

Verify the certified disclosure commitment from outside the canister:

```sh
integration-kit/scripts/certified-disclosure-verify.py --canister iso20022
```

The helper drives the deployed hub through `thebes-deploy --json query`, reading
the disclosure methods' JSON twins (`certifiedAuditDisclosureJson` et al.). It
recomputes the audit snapshot hash, balance snapshot hashes, balance Merkle root,
and final disclosure root, and; when a certificate is present;
checks the certificate hash-tree leaf for `certified_data`. The remaining
signature check is deployment-specific: the network root key.

Refresh and verify fixture bundle hashes:

```sh
integration-kit/scripts/fixture-bundle.py manifest
integration-kit/scripts/fixture-bundle.py verify \
  --public-key integration-kit/fixtures/dev-fixture-signing-public.pem
```
