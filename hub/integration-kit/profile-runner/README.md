# External XSD/Profile Runner

The canister implements a deterministic compact XML profile. Full XML/profile
evidence is produced outside the canister with this runner.

Required inputs:

- official or licensed XSD files under a schema directory
- `profile-map.json`
- `source-manifest.json` for official-source provenance and operator actions
- the fixture corpus under `integration-kit/xml`

Fetch the public ISO base XSDs used by the current fixture map:

```sh
integration-kit/scripts/iso-xsd-fetch.py
```

This writes schemas to `official-schemas/iso-base/` and records checksums in
`iso-base-download-report.json`. The schema directory is intentionally ignored by
source control; the checksum report is the evidence artifact.

List every schema the current fixture map requires, with source/access metadata:

```sh
integration-kit/scripts/xsd-profile-runner.py --list-required-schemas
```

Run:

```sh
integration-kit/scripts/xsd-profile-runner.py \
  --schema-dir /path/to/iso20022/xsd \
  --require-all-schemas
```

Expected schema filenames are listed in `profile-map.json`, for example
`pain.001.001.09.xsd` and `pacs.008.001.08.xsd`.
The matching official-source map is in `source-manifest.json`. It records where
operators can obtain public, MyStandards, or participant-supplied artifacts, but
does not redistribute schemas or profile rule packs.

The runner writes `profile-report.json` with fixture SHA-256 hashes, schema
validation status, missing-schema status, source metadata, and custom-profile
notes. It uses `xmllint` when available; install libxml2 tooling in the
certification environment.

For release gates, add `--strict-source-manifest` so any schema lacking source
metadata fails the run:

```sh
integration-kit/scripts/xsd-profile-runner.py \
  --schema-dir /path/to/iso20022/xsd \
  --require-all-schemas \
  --strict-source-manifest
```

`cover.payment.xml` is a canister-specific bundle profile and is marked as a
custom profile. Its embedded direct `pacs.008` and cover `pacs.009` messages
should be extracted by a bank-specific differential runner when formal
certification evidence is required.

See `XSD_VALIDATION_CHECKPOINT.md` for the current real run. As of 2026-06-23,
the ISO base schemas are downloaded and wired, but most compact fixtures still
need full-ISO fixture hardening before `--require-all-schemas` can pass.
