# PFMI Self-Assessment

C8 exposes the same matrix through `pfmiSelfAssessment()` and verifies it with
`verifyPfmiSelfAssessment()`. The canister only claims code-enforceable controls
where a live oracle can check them; legal, governance, collateral, business-risk,
custody, and link-risk evidence remain operator/institutional gates.

Status vocabulary:

- `built`: implemented in this hub.
- `native-plus-built`: partly inherited from IC finalization/replication and
  partly implemented here.
- `hybrid`: code checks exist, but an institutional policy remains necessary.
- `institutional` or `external`: not a canister fact.
- `not-applicable`: outside this payment-hub scope.

| # | Principle | Applicability | Status | Code Verifier |
| --- | --- | --- | --- | --- |
| 1 | Legal basis | applicable | institutional | none; legal finality opinion and rulebook required |
| 2 | Governance | applicable | institutional | none; governance evidence required |
| 3 | Comprehensive risk management | applicable | hybrid | `verifyOracleReadiness`, `verifyPfmiSelfAssessment` |
| 4 | Credit risk | applicable | hybrid | `checkSettlementLiquidity`, `settlementLiquidityPosition` |
| 5 | Collateral | applicable | institutional | none; collateral policy external |
| 6 | Margin | not-applicable | not-applicable | not a CCP |
| 7 | Liquidity risk | applicable | built | `checkSettlementLiquidity`, `listSettlementQueue` |
| 8 | Settlement finality | applicable | native-plus-built | `verifyPaymentPhases`, audit evidence |
| 9 | Money settlements | applicable | built | `setSettlementLedger`, `runEndOfDay`, C6 disclosure |
| 10 | Physical deliveries | not-applicable | not-applicable | no physical delivery leg |
| 11 | CSDs | not-applicable | not-applicable | not a CSD |
| 12 | Exchange-of-value systems | not-applicable | not-applicable | no DvP/PvP engine |
| 13 | Participant default rules | applicable | hybrid | liquidity limits plus C7 workflow/directory checks |
| 14 | Segregation and portability | not-applicable | not-applicable | not a CCP |
| 15 | General business risk | applicable | institutional | none; finance/wind-down evidence required |
| 16 | Custody and investment risks | applicable | external | depends on settlement asset and treasury policy |
| 17 | Operational risk | applicable | native-plus-built | `verifyOracleReadiness`, connector auth, index health |
| 18 | Access requirements | applicable | built | `verifyParticipantWorkflowCorrelation` |
| 19 | Tiered participation | applicable | built | C7 access-tier and parent-BIC checks |
| 20 | FMI links | applicable | external | connector and settlement-link agreements external |
| 21 | Efficiency and effectiveness | applicable | built | operating-day and profile controls |
| 22 | Communication standards | applicable | built | XML/profile oracle and fixture registry |
| 23 | Disclosure | applicable | built | C6 certified disclosure plus this self-assessment |
| 24 | Market data by trade repositories | not-applicable | not-applicable | not a trade repository |

`verifyPfmiSelfAssessment()` requires all 24 rows, non-empty status/locus fields,
verifier surfaces for code-enforceable rows, explicit residual gaps for
non-code applicable rows, and a passing C7 workflow oracle.

## Remaining Hardening

- Operator-signed PFMI disclosure pack.
- Legal finality memorandum and participant rulebook.
- Official CBE/EBC participant directory and rule packs.
- Licensed sanctions/PEP feed and production PKI/HSM verifier.
- Deployment-network signature verification for the C6 helper, using IC
  root-key/BLS only for ICP replay and a Thebes network proof for Thebes
  production.
