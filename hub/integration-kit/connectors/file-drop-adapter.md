# SFTP/File-Drop Adapter Pattern

The canister does not need to know whether a file came from SFTP, MQ, object
storage, or a bank portal. The adapter must convert each file into a
`TransportEnvelope`.

Required adapter behavior:

- compute SHA-256 over the exact payload bytes
- assign a monotonic `sequence` per connector
- keep the source file id as `remoteId`
- generate a stable `traceId` for cross-system audit
- submit the connector envelope with the source payload
- store the canister `TransportRecord.id` beside the external file event
- move accepted files to an archive bucket/folder
- move dead-letter files to a repair queue with `issues[].ruleId`

Recommended folders:

- `incoming/`
- `processing/`
- `accepted/`
- `dead-letter/`
- `replay/`
- `archive/YYYY/MM/DD/`

Do not mutate a file in place after computing the payload hash. If a repaired
file is resubmitted, give it a new `remoteId` and sequence while preserving the
original `traceId` in adapter metadata.
