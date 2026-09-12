# Cookbook: Accept File, Return Status, Export Notification

This is the operator-friendly happy path for a bank or middleware file bridge.

1. Adapter receives `pain.001.xml` or `mt103`.
2. Adapter computes SHA-256 over the exact file bytes.
3. Adapter submits `submitTransportEnvelope`.
4. Canister validates, creates a payment, and emits `pain.002`.
5. Operator dispatches `pacs.008` or queues `payment.bundle.xml` for outbound.
6. Downstream bank sends `pacs.002.xml`.
7. Adapter submits `pacs.002.xml` as a connector envelope.
8. Canister correlates by original message id and UETR.
9. Canister rejects duplicates and mismatches with stable rule IDs.
10. Operator exports `camt.054` for the payment and `camt.053` by account/date.

Operational checks:

- Use `traceId` to join external file logs with `TransportRecord`.
- Use `remoteId` and sequence for replay protection.
- Use `payloadHash` for byte-for-byte payload evidence.
- Use `listDeadLetters` as the repair queue.
- Use `paymentXmlBundle` for a full payment evidence pack.
