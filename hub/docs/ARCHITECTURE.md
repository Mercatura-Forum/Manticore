# Architecture Notes

This canister is an Egypt-focused ISO 20022 hub template, not an official rail
rulebook. The default guideline is useful for Egyptian bank integration demos:
EGP, Egyptian IBAN shape, BIC country code `EG`, UETR, BAH, fixed minor-unit
amounts, and configurable code sets.

## Implemented Phases

1. `pain.001.intake`: validates customer credit-transfer initiation.
2. `pacs.008.transform`: maps a valid initiation into FI-to-FI credit transfer.
3. `pain.002.customer-status`: reports accepted technical validation or reject.
4. `pacs.008.dispatched`: operator transition for accepted transfers.
5. `pacs.002.bank-status`: records settlement, pending, or rejection status.
6. `pacs.004.return`: records a returned payment path.
7. `camt.reporting`: exposes statement and notification views.
8. `audit.evidence`: verifies hash chain, Merkle proof root, and MMR checkpoint.
9. `cross-border.cover`: validates `pacs.009` core/COV and direct/cover linkage.
10. `exceptions.investigations`: validates `camt.056`, `camt.029`, and
    `pacs.028`-style investigation records.
11. `compliance.screening`: emits deterministic AML/CFT/payment-transparency
    findings from a configurable profile.
12. `connector.envelope`: verifies connector sequence, checksum, idempotency,
    allowed format/endpoint, signature presence, and routes supported payloads.
13. `connector.outbound`: stores XML outbox batches, leases them to connector
    owners, verifies ACK/NACK receipts, and preserves retry/dead-letter state.
14. `legacy.mt103`: maps a supported MT103 subset into the same `pain.001`
    intake path for legacy bank interoperability fixtures.
15. `connector.auth`: supports Thebes caller ownership checks, Memphis session
    principal checks, and external verifier-canister attestations for detached
    signature schemes.
16. `phase.oracles`: exposes a machine-readable phase registry and live
    readiness verifier reports for implemented phases.
17. `ordered.secondary-indexes`: maintains deterministic status, account,
    creditor-agent, and connector/status indexes for bounded range and prefix
    reads.
18. `stable.index.checkpoints`: commits the ordered secondary indexes into
    Region-backed stable-memory snapshots with SHA-256 commit hashes and live
    verifier checks.
19. `iso.schema-profile`: validates an official-shape message against the
    generated profile of its ISO 20022 XSD (43 families, `motoko/iso/`), reads
    twenty families into typed records and writes them back schema-valid; the
    connector routes `<family>.xml` for those twenty.
20. `legacy.mt-bridge`: thirteen FIN types (MT101, MT103, MT104, MT202,
    MT202 COV, MT900, MT910, MT940, MT942, MT950, MT192, MT196, MT199) into the
    hub's records and back, mapping tables as data; connector routes `mt` and
    the typed `mt<nnn>` formats.
21. `iso.rule-sets`: CBPR+ and HVPS+ as data-driven rule sets over a closed
    check vocabulary, evaluated after the schema, bound to guideline profiles.

## Current Limits

- The compact codec imports and exports strict XML subsets for `pain.001`,
  direct debit, `pacs.008`, `pacs.009`, cover payments, status reports,
  investigations/case-management, request-to-pay, administrative, and
  `camt.053`/`camt.054` reporting; the payment flows run on it, and its shape is
  not the official one. The schema-profile codec validates official-shape
  messages of 43 families against their XSDs and reads twenty of them; the
  compact families are validated in the official shape through
  `validateIsoDocument`, not yet processed in it.
- Ordered secondary indexes remove the important query scans for status,
  account/date, creditor-agent, and outbox status reads. The canister also
  commits those sorted keyspaces into Region-backed stable-memory checkpoints
  with stable read methods and verifier metadata. Large bank workloads should
  still move from full-index snapshots to mutable stable BTree nodes.
- The MMR stores compact peaks for checkpoint roots. Historical MMR proof
  generation needs retained leaf/internal-node history or a stable log.
- Bloom filters are optimization telemetry only. Exact maps decide duplicates.
- Status and return reports use compact typed records. Inbound `pacs.002` and
  `pacs.004` can mutate payment state after original message id/UETR
  correlation, duplicate rejection, and lifecycle checks.
- Compliance screening is deterministic and auditable, but not a replacement
  for licensed sanctions/PEP/adverse-media data or institution policy.
- The MT bridge covers thirteen types with the options its mapping tables
  name (`integration-kit/legacy/mt-mappings.json`); other options are refused
  with a stable rule id. It is not full SWIFT MT option coverage.
- The CBPR+ and HVPS+ rule sets are the hub's reading of the public
  descriptions of those guidelines; the MyStandards usage guidelines with their
  rule identifiers are access-controlled and were not reconciled.
- Outbound batches now have an ordered connector/status/time index and a Region
  checkpoint. High-volume production queues still need incremental stable node
  updates instead of full snapshot commits.
- MAYO quorum signatures secure chain consensus/finality. Connector payload
  signatures are separate evidence and are checked through Thebes caller auth,
  Memphis session auth, or an external verifier canister.

## BTree Roadmap

Production indexing should evolve the current ordered-key contract and Region
checkpoint format into stable ordered structures:

- `UETR -> paymentId` and `messageId -> paymentId` exact indexes.
- `(account, bookedAt, paymentId)` statement ranges for `camt.053`.
- `(status, updatedAt, paymentId)` operator queues.
- `(agentBic, createdAt, paymentId)` bank integration views.
- `(connectorId, status, updatedAt, batchId)` outbound delivery queues.

A mutable Region-backed BTree or StableLog plus the existing ordered
secondary-index keys would reduce GC pressure and avoid full snapshot writes
while preserving deterministic pagination and bounded range reads by
account/date/status across upgrades.

## Hashing And Evidence Roadmap

The current audit layer uses the vendored in-place SHA-256 implementation,
hash-chained audit records, a full Merkle root/proof over audit leaves, and an
MMR root over append-only checkpoints. The C6 certified disclosure layer commits
the current audit/MMR snapshot and refreshed ICRC-ME balance snapshots through
IC `certified_data`.

C7 adds operator-supplied participant directory records and workflow states for
direct-debit, request-to-pay, administrative, and case-management threads. Each
workflow event appends a generic audit record before updating the message-id and
UETR indexes.

C8 exposes the PFMI self-assessment as queryable data and verifies that every
principle is classified, code-enforceable rows name a verifier, and
institutional/external rows name their residual evidence gate.

Next hardening steps:

- Store audit leaves in stable memory, not only heap maps.
- Store MMR node history for native MMR inclusion proofs.
- Extend the C6 verifier helper with deployment-network signature validation:
  IC root-key/BLS for ICP replay and Thebes network root/quorum proof for
  Thebes production.
- Import a signed official participant directory and replay C7 workflow files
  through deployed connectors.
- Publish the operator PFMI disclosure pack and legal finality memorandum.
- Add raw XML canonicalization hash for semantic XML equivalence, beyond the
  current raw payload hash.

## Verifier Contract

Every phase should return a stable `ruleId`, JSON-like path, severity, and
message. New bank-specific rules should be added through `UsageGuideline`
configuration first, then backed by focused tests.

`oraclePhaseRegistry`, `verifyOraclePhases`, and `verifyOracleReadiness` are the
top-level review entrypoints. They let an operator or reviewer inspect the
source-of-truth oracle for each phase and run the current live verifier set
without mutating canister state.
