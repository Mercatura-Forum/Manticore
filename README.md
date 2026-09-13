# Manticore: Thebes Core Banking and Payments

**Manticore is a core banking and payments system that runs as a smart contract
on the Thebes substrate.** Every state the bank holds is a fold over an
append-only, hash-chained block log; every money-moving operation is a
maker-checker act over canonical bytes; every report is a certified object a
third party can verify against the chain's own commitment. Deposits, lending,
value dating, foreign currency, end-of-day batch, regulatory reporting, and
payments over ISO 20022 and Mojaloop. Written in Motoko. Apache 2.0.

- **A provable double-entry journal.** Postings are blocks; balances, interest
  and reports are folds over them; a journal entry re-verifies from its bytes
  outside the contract.
- **Four eyes on every money-moving act.** Roles and permissions derived from
  the command catalogue, a checker on every proposal, and an audit of the
  catalogue that fails the build when a method is missing from it.
- **Products as data.** Deposit and lending products as versions; interest as a
  fold with declared day-count and compounding conventions; fees, limits and
  overdraft as recorded terms.
- **Payments in the official shapes.** An ISO 20022 hub built from the official
  schemas (43 message families), CBPR+ and HVPS+ rule sets as data, thirteen
  SWIFT FIN message types bridged, Mojaloop FSPIOP settlement.
- **Bounded, paged, upgrade-safe.** Posting indexes in stable memory over a
  B-tree, cursor-paged reads, closed months packed and archived, in-place
  upgrades that keep state.

| | |
|---|---|
| Journal | append-only, hash-chained block log; Merkle mountain range with a certified root |
| Controls | maker-checker, entitlements, permission audit with a negative control |
| Payments | ISO 20022 (43 families, official XSDs), SWIFT MT bridge, Mojaloop FSPIOP, post-quantum connector signatures (ML-DSA-44, MAYO-2) |
| Status | verified in the Motoko battery and integration runs; not deployed to a production chain; not independently audited |

Manticore is written in Motoko for the Thebes substrate. Its ISO 20022 layer is
built from the official schemas; its settlement and FSPIOP layers follow the
Mojaloop vocabulary; its products, batch and maker-checker follow the conventions
of established core-banking systems, each stated where it is used.

**Type-safe, memory-safe, no silent errors.** Motoko is a strongly and
statically typed language of the ML family, the family whose members run the
trading and risk systems of some of the world's largest financial institutions.
It has option types in place of nulls, arbitrary-precision and overflow-checked
arithmetic that traps rather than wraps, garbage-collected memory with no
pointers to corrupt, and atomic message execution: a trap rolls the whole
message back. Manticore is written to that discipline throughout. Every refusal
is a typed `Result` value with its reason (a missing permission, a hash
mismatch, a closed period, an unmapped account), never a default silently
applied; a computation that cannot be made exact is refused, not rounded into
agreement; a query that would be unbounded is refused with its bound, not
truncated.

## Why it runs on Thebes

A core-banking system holds the record of who owns what. Running it as a smart
contract on the Thebes substrate changes what that record is:

- **Redundant by construction.** The contract does not run on a server; it runs
  on every validator of the network, and its state is what a Byzantine
  fault-tolerant quorum of them agrees on. There is no primary to fail over
  from and no replica to fall behind: every validator holds the same journal,
  the same bank log and the same balances, and a validator that is lost is
  replaced by the others without a restore.

- **Tamper-proof execution.** A posting, an approval or a report exists only if
  the validators executed the same command on the same state and reached the
  same result. No administrator, no operator of a single machine and no
  validator on its own can alter a balance, back-date an entry or remove a
  block: the block logs are append-only and hash-chained, and the state every
  validator holds is itself hashed and compared at every height.

- **Verification and proofs.** Every block of the journal and of the bank log is
  a leaf of a Merkle mountain range whose root is certified by the network.
  Anyone holding a block and its inclusion proof, whether an auditor, a
  regulator, a counterparty or a customer, verifies it against the certified root without
  trusting the bank, the operator or any one validator (`integration/verify_bank.py`,
  `verify_entry.py`). A report is not a claim; it is a certified object whose
  inputs and result are provable.

- **A consortium, not a vendor.** The validators of a Thebes network can be run
  by the institutions themselves, the participating banks, the scheme
  operator, the regulator and an auditor, as a consortium subnet. Settlement
  between members then runs on infrastructure they jointly operate and jointly
  verify, with every member able to prove the state to itself, rather than on a
  system one of them owns and the rest must trust.

- **Upgrades that keep the record.** The contract is upgraded in place, its
  stable memory carried across, and the batteries prove the state survives.
  The history is never migrated, exported or re-keyed: the chain it was written
  on is the chain it stays on.

## What is here

| Layer | What it does |
|---|---|
| **Entitlements and maker-checker** | Roles and permissions derived from the command catalogue; four-eyes on every money-moving operation; the checker approves the canonical bytes, so nothing can change between proposal and approval; refusals are recorded, never silent. |
| **Party, CIF and KYC** | Parties, identifiers, documents, screening decisions, lifecycle and due diligence, collateral and guarantees, extension schemas; onboarding as one dual act. |
| **Product engine** | Deposit and lending products as versions; interest as a fold over the journal with declared day-count and compounding conventions; fees, limits and overdraft under the journal's own credit rule. |
| **Value dating, foreign currency and the close** | One place a value date moves; back-value corrections computed, never estimated; foreign currency inside the per-currency invariant; the period close as a recorded state machine. |
| **End-of-day batch** | A plan of work in bounded steps, resumable after any interruption, with inputs frozen under a run and the statement cut recorded rather than re-derived. |
| **Regulatory reporting and GL export** | Reports as certified objects; a closed reporting engine with no expression surface; returns that report what they cannot map; the general-ledger export that joins the two products. |
| **Payments** | Settlement schemes, participants, windows and netting on the journal; ISO 20022 messaging (29 message families against their official schemas, CBPR+ and HVPS+ rule sets); FSPIOP v1.1 interoperability. |
| **Posting indexes and bounded queries** | Four posting indexes in stable memory over a B-tree with cursor-paged, bounded reads. |
| **Closed-month packing, the archive roll and archive contracts** | Closed periods re-encoded and moved out of the live contract; the Merkle mountain range pruned below the archive boundary with proofs assembled across it; archive contracts created and adopted in resumable steps. |
| **Monitoring** | Aggregates the contract computes and a closed, declared rule set; alerts as recorded findings with a review. |

## The ISO 20022 hub

`hub/` is the open-banking ISO 20022 hub the payments layer talks to: a
validation and audit canister that reads and writes 43 message families in
their official shape (profiles generated from the official XSDs), applies the
CBPR+ and HVPS+ market-practice rule sets as data, bridges thirteen SWIFT FIN
(MT) message types to and from the same records, verifies connector signatures
(including the post-quantum ML-DSA-44 and MAYO-2 schemes), and keeps an
append-only audit accumulator with Merkle proofs. It has its own README,
architecture note, test battery and integration kit (fixtures, schema profiles,
guideline instances, the MT corpus).

## Layout

```
src/bank/        the domain layer
src/archive/     archive contracts and the roll
src/pq/          post-quantum connector signature schemes (ML-DSA-44, MAYO-2)
test/            the Motoko battery; test/run.sh runs it under WASI and, where a
                 test needs no Region memory, in the interpreter as well
integration/     the independent verifiers (a bank-log entry and a journal entry
                 re-verified from the bytes, outside the contract) and the ISO 20022
                 instance generators
tools/           build-time gates (the permission audit and its negative control),
                 schema and profile generators, post-quantum references
vendor/          thebes-ledger-core: the double-entry journal and the ledger
                 family this layer builds on (see NOTICE)
hub/             the ISO 20022 hub (its own README, docs, tests and kit)
docs/            the architecture overview
```

## Building and testing

Requirements: `moc` 1.4.1 and `mops` (`mops install` fetches `core` and `sha2`),
`wasmtime` for the WASI battery, Python 3 for the verifiers and generators.

```
mops install
./test/run.sh                              # the Motoko battery and the permission audit
./tools/permission_audit_negative.sh       # the audit's own negative control
```

`tools/packages.sh` emits the `moc` package flags: the mops dependencies plus the
`journal` and `ledger` packages from `vendor/`.

The contract is built with legacy (classical) persistence so that an in-place
upgrade keeps its state.

## Design

`docs/ARCHITECTURE.md` describes the block-log-and-fold model, the maker-checker
rule, where each kind of state lives, and how the layers are proven.

## Licence

Apache License 2.0 (see `LICENSE`). The vendored ledger family under
`vendor/thebes-ledger-core/src/ledger/` is MIT-licensed third-party code; its
notice is reproduced in `NOTICE`.

Attribution: Thebes Core Team.
