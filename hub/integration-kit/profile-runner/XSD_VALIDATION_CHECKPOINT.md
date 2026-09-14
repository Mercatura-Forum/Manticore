# XSD Validation Checkpoint

Date: 2026-06-23 UTC

This checkpoint records the first real external XSD run using public ISO 20022
base schemas downloaded from the ISO catalogue/archive.

## Inputs

- Schema cache:
  `integration-kit/profile-runner/official-schemas/iso-base/`
- Schema download report:
  `integration-kit/profile-runner/iso-base-download-report.json`
- XSD/profile runner report:
  `integration-kit/profile-runner/profile-report.json`
- Fixture map:
  `integration-kit/profile-runner/profile-map.json`

The schema cache is intentionally ignored by source control. The download report
records URLs, byte counts, and SHA-256 hashes for replay evidence.

## Result

- Required ISO base schema files: `22`
- Downloaded ISO base schema files: `22`
- Missing source metadata: `0`
- Schema-backed fixture results: `23`
- XSD-valid fixture results: `2`
- XSD-invalid fixture results: `21`
- Custom/non-XSD profile results: `2`

The two XSD-valid fixtures are:

- `valid/status-pacs002-settled.xml`
- `invalid/status-uetr-mismatch.xml`

The second one is intentionally XSD-valid but business-invalid because the UETR
does not match the stored payment.

## Interpretation

The external standard gate has moved forward: the repo now has a reproducible
path to fetch ISO base schemas and run real XSD checks. The current compact
fixtures are still canister-oriented examples, not full ISO-conformant market
fixtures.

Most invalid results are expected compact-profile gaps:

- compact postal-address ordering versus ISO schema order
- compact payment type fields that need nested ISO choice elements
- BAH plus Document fixtures that need profile envelope handling
- simplified investigation, request-to-pay, cash-management, and administrative
  roots compared with their ISO schema roots
- missing mandatory group header and status/case assignment elements in compact
  examples

## Commands

Fetch public ISO base XSDs:

```sh
integration-kit/scripts/iso-xsd-fetch.py
```

Run XSD validation:

```sh
integration-kit/scripts/xsd-profile-runner.py \
  --schema-dir integration-kit/profile-runner/official-schemas/iso-base \
  --require-all-schemas \
  --strict-source-manifest \
  --out integration-kit/profile-runner/profile-report.json
```

Run deployed-canister replay harness:

```sh
integration-kit/scripts/deployed-replay.py \
  --canister iso20022
```

Use `--dry-run` first to inspect the exact `thebes-deploy call`/`query` commands
without submitting updates.

## Addendum; 2026-09-12

The schema directory now holds `43` ISO base schema files (the original 22 plus
`head.001.001.02` and the twenty families of the schema-profile codec). The runner
now judges each fixture against the map's expectation (`asExpected`): a negative
fixture is meant to be schema-invalid, a business-invalid one schema-valid, and a
business file rooted at `Xchg` is validated whole.

- Fixtures in the map: `142` (`25` of the original corpus, `49` of the
  schema-profile codec, `68` of the CBPR+ / HVPS+ rule sets).
- As expected: `121`. The `21` that are not are the compact-codec fixtures of
  the original corpus, unchanged since the first run above.
- The schema-profile codec's own evidence; every written document valid under
  xmllint, 3,600 mutants with zero disagreements between xmllint and the
  canister's profile, Prowide cross-parses; is in `breadth-report.json`,
  `breadth-mutations-report.json`; the MT bridge's in `mt-bridge-report.json`;
  the rule sets' in `usage-guideline-report.json`.
