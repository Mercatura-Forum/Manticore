# Fixture Bundle Hashes

`fixture-bundle.json` is the signed hash manifest for the integration kit
fixture corpus. It covers XML fixtures, legacy file fixtures, profile packs,
connector templates, expected results, cookbooks, and the external profile map.

Generate or refresh it with:

```sh
integration-kit/scripts/fixture-bundle.py manifest
```

Sign with an institution or release private key:

```sh
integration-kit/scripts/fixture-bundle.py sign \
  --private-key /secure/path/fixture-signing-key.pem
```

Verify a signature:

```sh
integration-kit/scripts/fixture-bundle.py verify \
  --public-key integration-kit/fixtures/dev-fixture-signing-public.pem
```

The repository includes a development public key and matching signature for the
current fixture bundle. Production users should replace it with their own key.

## Current state of the development signature

`fixture-bundle.json` was regenerated on 2026-09-12 after `xml/valid/direct-debit-pacs003-sdd.xml`
was corrected (its XML declaration moved to the start of the document; see
`expected/rule-ids.md`, `XML-DECL-POSITION`). `fixture-bundle.sig` still signs the previous
manifest and does not verify against the current one: the development private key is not in this
repository, so the holder of that key re-signs with `fixture-bundle.py sign`.
