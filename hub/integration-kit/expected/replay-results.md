# Expected Replay Results

| Step | Input | Format | Expected result |
| --- | --- | --- | --- |
| 1 | `xml/valid/pain001-eg-domestic.xml` | `pain.001.xml` | accepted payment, `pain.002` generated |
| 2 | `dispatchPacs008(paymentId)` | update call | payment moves to `dispatched` |
| 3 | `xml/valid/status-pacs002-settled.xml` | `pacs.002.xml` | connector accepted, payment moves to `settled` |
| 4 | replay same `status-pacs002-settled.xml` with new remote id | `pacs.002.xml` | dead-letter with `STATUS-PACS002-DUPLICATE` |
| 5 | `xml/invalid/status-uetr-mismatch.xml` | `pacs.002.xml` | dead-letter with `STATUS-UETR-MISMATCH` |
| 6 | `xml/valid/status-pacs004-returned.xml` after settlement | `pacs.004.xml` | connector accepted, payment moves to `returned` |
| 7 | `legacy/mt103-basic.txt` | `mt103` | accepted payment through MT103 bridge |
| 8 | `xml/invalid/xml-doctype-entity.xml` | any XML decoder | rejected with `XML-UNSAFE-DECL` |

After every accepted payment-changing step, verify:

- `verifyPaymentPhases(paymentId)` is healthy for the expected lifecycle phase.
- `secondaryIndexHealth()` reports heap and Region checkpoint invariants.
- `auditTip()` advances after audited message intake.
- `listDeadLetters(0, 20)` includes failed replay attempts with rule IDs.
