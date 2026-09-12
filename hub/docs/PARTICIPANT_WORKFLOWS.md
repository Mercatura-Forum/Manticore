# Participant Directory And Workflow Correlation

C7 adds a compact participant directory and auditable workflow state for message
families that were previously validated but not linked across messages.

## Directory

`upsertParticipantDirectoryEntry(input)` stores operator-supplied participant
records:

- `bicfi`: ISO 9362 BICFI.
- `lei`: optional ISO 17442 LEI.
- `accessTier`: `direct`, `indirect`, or `addressable`.
- `parentBicfi`: required for `indirect` and `addressable` records.
- `reachable` / `active`: operator routing controls.
- `supportedMessageFamilies`: compact reachability declaration.

`seedDemoParticipantDirectory()` installs the C7 demo participants used by the
oracle checks. `listParticipantDirectory()` recomputes
`settlementAccountConfigured` from the ICRC-ME settlement-account map at read
time.

## Workflow State

Valid workflow messages append a generic audit record to the existing audit
hash chain/MMR and update a `WorkflowState`:

- `correlateDirectDebitWorkflow`: `pain.008` mandate/customer collection and
  `pacs.003` interbank collection are keyed by `mandateId`.
- `correlateRequestToPayWorkflow`: `pain.013`, `pain.014`, and `camt.055` are
  keyed by the original request id.
- `correlateInvestigationWorkflow`: `camt.110`/`camt.111` and related
  investigation messages are linked by original message id or UETR.
- `correlateAdministrativeWorkflow`: `admi.002`/`004`/`007`/`011` attach to an
  existing workflow by related message id or related UETR when possible.

Connector intake now calls the same helpers for valid direct-debit,
request-to-pay, investigation/case-management, and administrative envelopes.

## Evidence

`verifyParticipantWorkflowCorrelation()` checks:

- participant BIC/LEI/access-tier validation,
- rejection of unsupported access tiers,
- direct-debit mandate -> `pacs.003` collection -> `admi.002` reject
  correlation into one workflow,
- request-to-pay `pain.013` -> `pain.014` response correlation,
- `camt.110` -> `camt.111` case-management correlation,
- message-id and UETR index back-pointers for persisted workflows.

Demo replay helpers:

- `correlateDemoDirectDebitReturnWorkflow()`
- `correlateDemoRequestToPayWorkflow()`

## Production Boundary

The directory is operator-supplied. Production deployments still need signed
scheme/CBE/EBC directory imports, mandate expiry and revocation rules,
rail-specific ACK/NACK timers, and deployed connector replay evidence.
