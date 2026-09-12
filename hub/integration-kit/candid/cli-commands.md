# thebes-deploy Call Snippets

Drive the deployed hub with the Thebes CLI. Global flags (`--manifest`,
`--network`, `--identity`) precede the verb; `query` runs read-only methods and
`call` submits update calls. Replace `iso20022` with the deployed canister id or
the alias in `thebes.toml`.

Discovery and readiness (queries):

```sh
thebes-deploy --manifest thebes.toml query iso20022 supportedStandards
thebes-deploy --manifest thebes.toml query iso20022 capabilities
thebes-deploy --manifest thebes.toml query iso20022 checkpointMap
thebes-deploy --manifest thebes.toml query iso20022 integrationProfilePacks
thebes-deploy --manifest thebes.toml query iso20022 xmlProfileFixtureRegistry
thebes-deploy --manifest thebes.toml query iso20022 verifyOracleReadiness
thebes-deploy --manifest thebes.toml query iso20022 verifyParticipantWorkflowCorrelation
thebes-deploy --manifest thebes.toml query iso20022 pfmiSelfAssessment
thebes-deploy --manifest thebes.toml query iso20022 verifyPfmiSelfAssessment
```

Register a file connector (update calls):

```sh
thebes-deploy --manifest thebes.toml call iso20022 registerConnector \
  --arg "$(cat integration-kit/connectors/connector-registration.did)"
thebes-deploy --manifest thebes.toml call iso20022 useThebesCallerAuth --arg '("bank-eg-001")'
```

Decode or validate a local XML fixture (queries):

```sh
thebes-deploy --manifest thebes.toml query iso20022 decodePain001Xml --arg '(blob "<payload bytes>")'
thebes-deploy --manifest thebes.toml query iso20022 validatePain001Xml --arg '(blob "<payload bytes>")'
thebes-deploy --manifest thebes.toml query iso20022 validateDirectDebitXml --arg '(blob "<pain.008/pacs.003 bytes>")'
thebes-deploy --manifest thebes.toml query iso20022 validateRequestToPayXml --arg '(blob "<pain.013/pain.014/camt.055 bytes>")'
thebes-deploy --manifest thebes.toml query iso20022 validateAdministrativeXml --arg '(blob "<admi.002/admi.004/admi.007/admi.011 bytes>")'
```

Lifecycle replay (calls, then queries):

```sh
thebes-deploy --manifest thebes.toml call iso20022 submitPain001Xml --arg '(blob "<pain001 bytes>")'
thebes-deploy --manifest thebes.toml call iso20022 dispatchPacs008 --arg '(0 : nat)'
thebes-deploy --manifest thebes.toml call iso20022 submitTransportEnvelope --arg '(record { ... pacs.002.xml envelope ... })'
thebes-deploy --manifest thebes.toml query iso20022 paymentXmlBundle --arg '(0 : nat)'
thebes-deploy --manifest thebes.toml query iso20022 secondaryIndexHealth
```

C7/C8 evidence:

```sh
thebes-deploy --manifest thebes.toml call iso20022 seedDemoParticipantDirectory
thebes-deploy --manifest thebes.toml call iso20022 correlateDemoDirectDebitReturnWorkflow
thebes-deploy --manifest thebes.toml call iso20022 correlateDemoRequestToPayWorkflow
thebes-deploy --manifest thebes.toml query iso20022 listWorkflowStates --arg '(0 : nat, 20 : nat)'
thebes-deploy --manifest thebes.toml query iso20022 verifyParticipantWorkflowCorrelation
thebes-deploy --manifest thebes.toml query iso20022 verifyPfmiSelfAssessment
```

C6 certified-disclosure verifier:

```sh
integration-kit/scripts/certified-disclosure-verify.py --canister iso20022
integration-kit/scripts/certified-disclosure-verify.py \
  --manifest thebes.toml \
  --network wan \
  --canister iso20022
```

For connector envelopes, compute `payloadHash` from the exact payload bytes:

```sh
integration-kit/scripts/payload-hash.sh integration-kit/xml/valid/pain001-eg-domestic.xml
```

Executable replay harness:

```sh
integration-kit/scripts/deployed-replay.py --canister iso20022 --dry-run
integration-kit/scripts/deployed-replay.py --canister iso20022
integration-kit/scripts/deployed-replay.py --canister iso20022 --skip-c7-c8
integration-kit/scripts/deployed-replay.py --canister iso20022 --include-dispatch
```

Set `--network <name>` and `--identity <id>` when the target deployment requires
a non-default network or a specific signing identity; `--manifest <path>` points
at a `thebes.toml` outside the working directory.

Deploy and smoke-test:

```sh
thebes-deploy --manifest thebes.toml deploy iso20022
thebes-deploy --manifest thebes.toml call iso20022 claimOwner
integration-kit/scripts/deployed-replay.py --canister iso20022
```

Resume after a partial live run:

```sh
integration-kit/scripts/deployed-replay.py \
  --canister iso20022 \
  --payment-id 0 \
  --skip-dispatch
```
