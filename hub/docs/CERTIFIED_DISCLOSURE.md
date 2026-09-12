# Certified Disclosure

The hub exposes a compact IC `certified_data` root for public disclosure. The
root commits to two things:

- the current audit tip: hash chain, Merkle root, MMR root, count, and guideline
  id
- refreshed ICRC-ME participant balance snapshots, ordered by BIC and folded
  into a Merkle root

The canister does not certify arbitrary live ledger query responses. Balance
values become certifiable only after an operator refreshes a snapshot in an
update call.

## Operator Flow

1. Configure the settlement ledger with `setSettlementLedger`.
2. Configure participants with `setSettlementParticipantAccount`.
3. Call `refreshCertifiedSettlementBalances()`.
4. Read `certifiedAuditDisclosure()` and `certifiedParticipantBalance(bicfi)`.
5. Run `integration-kit/scripts/certified-disclosure-verify.py` against the
   deployed canister to recompute the root from the returned fields and check
   the certificate hash-tree leaf.

## Query Surfaces

- `certifiedDisclosureCertificate()` returns the current certified root and IC
  certificate.
- `certifiedAuditDisclosure()` returns the current audit snapshot, root, and IC
  certificate.
- `certifiedParticipantBalance(bicfi)` returns one balance snapshot, root, and
  IC certificate.
- `listCertifiedParticipantBalances(offset, limit)` returns the deterministic
  balance snapshot order used for the balance Merkle root.
- `verifyCertifiedDisclosure()` checks the canister's current committed hashes.

## External Verifier Helper

`integration-kit/scripts/certified-disclosure-verify.py` is the packaged C6
client-side verifier for the disclosure commitment:

```sh
integration-kit/scripts/certified-disclosure-verify.py --canister iso20022
integration-kit/scripts/certified-disclosure-verify.py \
  --manifest thebes.toml \
  --network wan \
  --canister iso20022
```

The helper drives the deployed hub through the Thebes CLI
(`thebes-deploy --json query`) — no external client library. It fetches the
JSON twins of the disclosure methods (`certifiedAuditDisclosureJson()`,
`certifiedDisclosureCertificateJson()`, paginated
`listCertifiedParticipantBalancesJson`, and `verifyCertifiedDisclosureJson()`),
which return the same fields as their typed counterparts encoded as a JSON
string (blobs as byte arrays, optionals as `[]`/`[value]`, integers as decimal
strings). It independently recomputes:

- the audit snapshot hash
- every participant balance snapshot hash
- the ordered participant-balance Merkle root
- the final `certified-disclosure-v1` root hash
- when an IC-format certificate is present, the revealed certificate hash-tree
  leaf at `/canister/<canister-id>/certified_data`

The certificate-tree check applies to IC-format certificates and requires Python
`cbor2`; use `--skip-certificate-tree` to skip it (and
`--allow-missing-certificate` when the deployment returns no certificate on a
plain query, as the Thebes substrate does). The helper intentionally reports
`networkCertificateSignatureVerified=false`: the remaining trust check is
deployment-specific. For IC-compatible ICP deployments that means IC
root-key/BLS certificate-signature validation; for Thebes production it means a
Thebes network root or quorum-proof verifier.

The Motoko side now contains both `motoko/Mayo2ShakeVerifier.mo` for the local
SHAKE variant and `motoko/Mayo2PqVerifier.mo` for the production-shape
`pq-mayo` verifier. The `pq-mayo` path implements 186-byte signatures,
4,912-byte compact public keys, AES-128-CTR P1/P2 expansion, entry-major
`m`-vectors, and the `pq-mayo` target hash convention. It is not yet wired to
this C6 helper because Thebes production QC verification still needs the captured
QC/keyset/quorum/state-root layer, plus measured caching for expanded validator
keys. Until that lands, the external helper must keep reporting
`networkCertificateSignatureVerified=false`.

The current Rust oracle commands are:

```sh
cargo run --manifest-path tools/mayo2-oracle/Cargo.toml -- check-shake-fixture
cargo run --manifest-path tools/mayo2-oracle/Cargo.toml -- check-pq-synthetic-fixture
cargo run --manifest-path tools/mayo2-oracle/Cargo.toml -- check-pq-mayo-fixture
```

## C6 Playground Evidence

On June 24, 2026, hub `xpjyl-daaaa-aaaab-qadcq-cai` was upgraded with C6 and
wired to C6 ledger `mytki-xqaaa-aaaab-qabrq-cai`.

`refreshCertifiedSettlementBalances()` captured:

- `EGBKEGCX`: `8,750,000` EGP minor units
- `EXBKEGCX`: `2,500,000` EGP minor units

The committed root had `balanceCount=2`, a non-null IC certificate, and
`verifyCertifiedDisclosure()` returned `ok=true`. Final post-upgrade refresh
evidence:

- `balanceRoot`: `6dbe526a2fd919264e8ca0e44ffb7d981d6881ca869ce8b3f29a347ac5d7a890`
- `rootHash`: `7ceb30372cd501027f9575cc9c837cb5919cd50e9c0179768cee01940e050d44`

## Limitations

This is disclosure evidence, not legal finality by itself. Production use still
needs deployment-network signature validation and a decision on whether the
settlement ledger should expose ledger-native certified balance witnesses.
