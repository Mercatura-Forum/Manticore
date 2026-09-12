# Architecture

Attribution: Thebes Core Team.

## 1. Two logs, one rule

Manticore is two append-only, hash-chained block logs and the folds over them.

The **journal** (`vendor/thebes-ledger-core/src/journal/`) is the double-entry
primitive: accounts, postings, balances, periods and the calendar, with a
Merkle mountain range over its blocks and a certified tip a third party can
verify. It holds the money. It has one credit rule, and every layer above it is
held to that rule rather than re-implementing it: a reservation past a net debit
cap, a posting on a closed period, a foreign-currency leg that breaks the
per-currency invariant: each is refused by the journal, whatever the code above
it asked.

The **bank log** (`src/bank/`) records everything that is not a posting: the
roles and their permissions, every proposal and every approval, the parties and
their documents, the products and their versions, the close, the batch runs, the
reports, the messages. Its state is a fold over its own blocks: any validator, or
any auditor with the blocks, recomputes the bank exactly. Nothing lives only on
the heap; what a query answers is what the fold holds.

The two logs meet at one seam. A bank block that moves money names the journal
entry it moved, and the journal entry names the bank block that authorised it,
so a posting is never without its authority and an authority is never without
its posting.

## 2. Maker-checker over canonical bytes

Every money-moving operation is a **command** with a canonical binary encoding.
A maker proposes it: the proposal block records the command and the SHA-256 of
its canonical bytes. A checker approves the **hash**, not the command as
displayed; at execution the fold re-encodes the command and refuses to post if
the hash differs (`#CommandHashMismatch`). Nothing between proposal and approval
can change what is approved.

There is no bootstrap exception and no superuser: the first role and the first
checker are created under the same rule as every later one. Emergency access
is a recorded override with a mandatory review, not a bypass. A refusal (a
missing permission, a hash mismatch, an expired proposal) is itself recorded,
so the absence of an action is as auditable as the action.

The permission catalogue is derived from the command set at build time and
checked by a build gate (`tools/permission_audit.py`), with a negative control
that proves the gate can fail.

## 3. Where state lives

Three kinds of state, three homes:

- **Blocks** in the log: the durable record, hash-chained, with the MMR.
- **Fixed-width rows** in stable memory (`RegionIndex`, a B-tree over stable
  regions with per-index widths, a cursor-resumable range and a page free list):
  proposals, parties, accounts, the posting indexes. A row is what the fold
  keeps so a query is bounded; the block it points to is the truth.
- **Nothing** on the heap that the fold could not rebuild.

Every read that grows with the book is cursor-paged and bounded. There is no
unbounded scan behind any query.

## 4. The product engine

A product is a **poster**, not a second ledger: it computes what to post and
the journal posts it. Interest is a fold over the journal's balances with a
declared day-count convention and a declared compounding boundary; 30/360 can
accrue daily because the daily fraction is derived, not assumed. Products are
versions: an amendment registers the next version and the previous one is
retained, so an account's terms are always the ones it was opened under. Tills
never absorb a difference; a charge that rounds to zero is not a posting.

## 5. Value dating, foreign currency, the close

There is exactly one place a value date moves, and a back-value correction is
computed from the journal, never estimated. A period cannot close over an
incomplete day. Foreign currency lives inside the journal's per-currency
invariant, with position pairs and a recorded rate source. The close is a state
machine whose every transition is a block, and the back-value window is policy
recorded as data.

## 6. The end-of-day batch

The batch is a plan of work, not one computation: bounded steps, each a block,
resumable after any interruption, with two kinds of idempotence (a step that is
re-run and a step that is re-derived). Inputs cannot move under a run. A failing
item neither stops the queue nor vanishes. The statement cut at the end of the
day is a record, and every later statement is built from that record rather than
re-derived.

## 7. Reporting

A report is a certified object: its definition, its inputs and its result are
recorded, and its hash is in the certified tree. The reporting engine is closed
data (a fixed set of dimensions, three filter operators, a fixed set of
measures) with no expression surface, so a report cannot compute what the
engine was not built to compute. Two statements assert an accounting identity
rather than presenting one; a return reports what it cannot map rather than
bucketing it.

## 8. Payments

**Settlement** on the journal: schemes, participants, net debit caps as the
journal's own limit, two-phase transfers, windows and netting, with a
settlement judged against the computed nets.

**ISO 20022** on the journal: 29 message families read and written against
their official schemas, with CBPR+ and HVPS+ rule sets as declared data
evaluated after the schema; every received message is a block; refusals leave
the journal untouched.

**FSPIOP** (Mojaloop) interoperability: the participant directory, quotes and
transfers end to end, with the journal's refusal returned as the protocol's
error to the payer.

**The MT bridge**: thirteen FIN message types mapped to and from the same
records through mapping tables held as data.

## 9. Packing, the archive roll and archive contracts

A closed month's postings are re-encoded and moved out of the live contract in
bounded steps, each a block; the reads that span the boundary are stated as the
gates need them. The Merkle mountain range is pruned below the archive boundary
and proofs are assembled across it, so a posting that left the live contract is
still provable against the same tip. Archive contracts are created, installed
and adopted in resumable steps: the parent records each step before it acts, so
a crash between steps never leaves a contract the parent does not know about.

## 10. Monitoring

Aggregates are computations the contract makes over its own blocks; rules are
closed, declared data; an alert is a recorded finding with a recorded review.

## 11. How it is proven

- **The Motoko battery** (`test/`): every module, under WASI and, where no
  Region memory is needed, in the interpreter too, with byte-identical output
  required from both. A test must print what it examined; a count of zero fails.
  The ISO 20022 tests carry valid and invalid instances of every family against
  the official schemas; the settlement and FSPIOP tests walk every transfer and
  window state; the product tests reproduce published interest vectors.
- **The permission audit** (`tools/permission_audit.py`): every public update
  method of the built interface is guarded by a catalogued permission, with a
  negative control that proves the gate can fail.
- **Independent verifiers** (`integration/verify_bank.py`, `verify_entry.py`):
  a bank's blocks and a journal's entries re-verified from the bytes, outside the
  contract, against the certified tip.
