# Open Banking Standard ISO 20022 on Thebes

**An educational reference for imagining financial systems on-chain; and what
their foundational standards look like when you express them in a typed language
that is safe.**

ISO 20022 is the grammar the world's payment systems are converging on; the
language banks, market infrastructures, and central banks use to say *move this
money, this way, with these guarantees*. This repository asks a single question
and answers it in working code: **if you rebuilt that grammar on a chain, in a
typed and memory-safe language, what would it look like; and what would it let
you prove that a server never could?**

It is meant to be read, run, and learned from. You can deploy it, send a payment
through it, watch every message leave evidence, and then recompute that evidence
yourself. Nothing here asks for your trust; everything here invites your
inspection.

---

## What this is, and what it is for

This is a teaching artifact, shaped like production. It does not try to be all of
ISO 20022 and it claims no official market designation. It is an open-source
template that implements the message set a real integrator actually has to reason
about, end to end, so that someone imagining on-chain finance has something
concrete to study instead of a diagram:

`pain.001`, `pain.002`, `pain.008`, `pain.013`, `pain.014`, `head.001`,
`pacs.003`, `pacs.008`, `pacs.009`, `pacs.002`, `pacs.004`, `camt.055`, the
`admi` acknowledgements and rejects, and the `camt.053` / `camt.054` reporting
views; with a bidirectional connector that bridges the legacy `mt103` world.

The default usage guideline is Egypt-focused by design: EGP enabled, Egyptian
IBAN shape, Egyptian BIC country codes, BAH and UETR rules, fixed minor-unit
amounts, SWIFT-X text, one transaction per `pacs.008`. The lesson is in the
choice itself: compliance means nothing in the abstract; it means something only
against a declared message set and a declared guideline. So the guideline here is
**data you can read and replace**, not an assumption buried in code; change the
rules, and the hub enforces the rules you changed.

---

## The idea worth taking away

Financial messaging has always had an honesty gap. A bank receives an
instruction, validates it, transforms it, settles it, and writes all of this to a
log. The log is the truth; and the log lives on the operator's own
infrastructure, under the operator's own control. When a payment is disputed, an
auditor does not inspect the event as it happened; the auditor inspects the
operator's reconstruction of it, months later, from records the operator could in
principle have rewritten. ISO 20022 standardized the *message*. It did not change
who owns the *evidence*.

Putting the hub on Thebes changes who owns the evidence. The point is not that it
is "on a chain"; the point is what the chain lets the hub prove about itself.
Four properties follow directly from the architecture, and each one is something
you can demonstrate, not just read about.

**Auditable; every message leaves evidence, valid or not.** The hub appends an
audit record for every message it processes and stores the full structured
validation report beside it, *including the messages it rejected*. You can prove
not only what was accepted, but exactly what was refused and on which rule. The
audit trail is a first-class output the system is built to produce, not a log you
are asked to believe.

**Immutable; append-only by construction, not by policy.** Audit records are
SHA-256 hash-chained: each record commits to the one before it, so the tip
commits to the whole history. Records are folded into a Merkle root with a proof
API and accumulated into an MMR checkpoint root. You cannot quietly change an
entry in the middle; doing so breaks every hash that follows, and the break is
detectable by anyone holding a later root.

**Tamper-proof; the record is part of the chain's signed state.** The
hash-chained audit and the certified-disclosure root are committed into Thebes
state, finalized by BFT consensus and certified by the validator set. No
operator, and no single node, can alter a finalized record or forge a disclosure
root without subverting consensus itself. The same cryptography that secures the
chain secures the record.

**No disaster recovery, because there is nothing to recover.** The hub runs
across a Byzantine-fault-tolerant validator set. Correctness holds as long as a
quorum is honest; liveness holds as long as a quorum is alive. There is no
disaster-recovery runbook because there is no single copy to lose; every node
finalizes the same state, so a lost node is a *replaced* node, not a *restored*
backup. There is no maintenance window in the sense a single-server gateway has
one; the hub keeps validating and finalizing while the network is live.

---

## Why a typed, safe language is the heart of it

The reason this example is written in Motoko, and not in whatever was fastest, is
the same reason the rest of it exists: on the path that moves money, a whole class
of failure should be impossible *before* the code is ever deployed, not caught
*after* it reaches production.

A typed, memory-safe language removes those failures by construction; no untyped
message field, no out-of-bounds read, no use-after-free, no silent coercion where
a malformed amount quietly becomes a valid-looking one. The `moc` compiler proves
these properties at build time. Execution compiles to compact, deterministic
WebAssembly, which is exactly what consensus requires and what keeps memory and
timing behaviour predictable across every node. State persists across upgrades
through orthogonal persistence, so the audit history is not an external database
that can drift from the code that wrote it; the code and the evidence it
produces live in the same place, under the same guarantees.

For someone imagining a financial system on-chain, this is the lesson with the
longest reach: the standard tells you *what* a correct message is, and a typed
language lets the machine *refuse* an incorrect one before it can do harm.

---

## See it for yourself, in sixty seconds

```sh
# 1. Verify the whole thing on your machine; types, validators, audit chain, crypto.
cd motoko
mops install
mops test

# 2. Put it on the chain.
thebes-deploy identity new me
thebes-deploy deploy iso20022

# 3. Recompute the audit root yourself; from raw fields, with no node to trust.
python3 integration-kit/scripts/certified-disclosure-verify.py
```

> **Deploying your own copy?** The committed `cid` pins the **live catalog
> deployment** (only its controller can upgrade it). Before your first deploy,
> set `cid = "auto"` in `thebes.toml`: the deploy allocates a fresh canister
> you control and writes its id back into the manifest.

That third step is the whole argument made tangible. The hub hands you a
settlement disclosure; the script recomputes the audit snapshot hash, every
participant-balance hash, the ordered Merkle root, and the final
`certified-disclosure-v1` root from scratch, then walks the chain certificate to
the committed leaf at `/canister/<id>/certified_data`. If the operator's answer
and the certified root disagree, the verifier tells you. You are not trusting the
node that answered; you are checking it.

---

## Verifiable all the way down

A client does not have to trust the node that answered it. The disclosure root
arrives with a certificate, and the repository ships the clients that check it.
Verification composes in layers:

- **The disclosure root** is recomputed from raw fields and matched to the
  certificate's committed leaf by `certified-disclosure-verify.py`.
- **The boundary attestation** is pinned and checked with WebCrypto in the
  certified-frontend client (`examples/asset-canister`): it verifies the
  boundary's Ed25519 signature over the `state_root`, tying the answer to a
  signature rather than a promise.
- **The validator quorum, directly**; so that no boundary is trusted either;
  is checked by a Motoko **MAYO-2** verifier: an oracle-enforced port of the
  node's own Rust verifier, brought on-chain so that any canister can confirm the
  validator set's post-quantum quorum for itself.

That last layer is post-quantum cryptography running inside a smart contract.
`motoko/Mayo2PqVerifier.mo` parses the compact public key and the 186-byte
signature, expands the key through AES-128-CTR, evaluates the full quadratic
P-map, and verifies real production-shape `pq-mayo` signatures; with every
supporting layer pinned to ground truth: the AES-128 path against the FIPS-197
known-answer vectors and the SHAKE path against the `pq-mayo` Rust oracle. It is
here as a study in moving a real cryptographic verifier from a node binary into a
contract, so the quorum is something an outside party can check rather than
something it must take on faith.

---

## How a payment moves through the hub

1. A customer credit transfer arrives as `pain.001`, typed or as compact XML.
2. The hub validates it against the active usage guideline and answers with
   `pain.002`.
3. An accepted payment is transformed to `pacs.008` and dispatched.
4. The bank's `pacs.002` status report moves it to settled, rejected, or
   dispatched; returns are handled through `pacs.004` and `camt.055`.
5. `camt.053` and `camt.054` views expose statement and notification reads.

Every step writes audit evidence. Duplicate detection guards the intake; Bloom
filters give a fast advisory signal while exact maps remain the authority, so a
false positive can never reject a real payment on its own.

---

## The connector, and the integration kit

The connector layer is bidirectional, and its authorization is explicit: a
connector authenticates with a Thebes caller identity, a live Memphis session
token, or an external verifier canister that attests detached Ed25519, MAYO, or
threshold signatures over the hub's canonical envelope hash. Outbound batches are
leased, acknowledged or rejected, retried, and hash-verified on-chain, with a
dead-letter path for what cannot be delivered.

Everything needed to actually try an integration is in `integration-kit/`:
compact XML samples for every supported route; valid and invalid status replay
files; connector envelope and batch-manifest examples; MT103, MT940/MT942, CSV,
and fixed-width legacy samples; Candid call snippets with expected rule IDs;
the certified-disclosure verifier; and named profile packs including
`EG-DOMESTIC-EDU`, `CBPRPLUS-EDU`, `LEGACY-MT103-BRIDGE`, SEPA and Fedwire
education profiles, and `BIS-CPMI-HARMONIZED-CROSSBORDER`.

Two codecs carry the XML. The compact codec is what the payment flows run on:
twenty-two families in a deterministic subset shape, not full XSD conformance,
and `docs/INTEGRATION_READINESS.md` says so. The schema-profile codec
(`motoko/iso/`) carries the official ISO 20022 XSDs as generated profiles; 43
families; validates a message against its schema before reading it, reads
twenty families into typed records (reversals, direct debits, the mandate cycle,
the multilateral settlement request, cash management and liquidity, the
exceptions-and-investigations set, system administration, the business file
header) and writes them back schema-valid; `validateIsoDocument` accepts any of
the 43 with or without its AppHdr. On those sit the MT bridge; thirteen FIN
types (MT101, MT103, MT104, MT202, MT202 COV, MT900, MT910, MT940, MT942,
MT950, MT192, MT196, MT199) read into the hub's records and written back, each
with its field-to-element table as data; and two market-practice rule sets,
CBPR+ and HVPS+, as data over a closed check vocabulary. The MyStandards usage
guidelines themselves are access-controlled and were not fetched: the rule sets
are the hub's reading of the public descriptions, each rule naming its basis,
and the identifier-by-identifier reconciliation with MyStandards is stated as
not performed. `integration-kit/XML_SUPPORT_MATRIX.md` has the tables and,
for every claim, the runner and the report that measured it; xmllint against
the official XSDs, 3,600 mutants with zero disagreements, Prowide cross-parses
of everything written.

---

## Identity

`submitTransportEnvelopeWithMemphis` attributes a submission to a person rather
than to a key, using [Memphis](https://github.com/Mercatura-Forum/thebes-sdk/blob/main/docs/memphis.md), contract **921**. Two strings decide this
and they are **not** the same value:

| | What it is | Changing it |
| --- | --- | --- |
| `origin` (on the gate) | The **pseudonym namespace**, here the label `thebes-example-iso20022`. It decides every submitter's principal. | Orphans every existing account. Frozen for the life of the contract. |
| `memphisAudience` | The **web origin of the frontend** that submits here. Memphis compares it byte-exactly against the origin the token was minted for. | Safe. Set it with `setMemphisAudience` when the submitting frontend moves. |

Institutions run their own frontend, which is why the audience is configurable
while the namespace is not. Passing the namespace as the audience; which is
what a single-argument `verify` does; makes **every** verification fail with
`#Unauthorized`, because the namespace is a label and not a URL.

```motoko
switch (await* MemphisAuth.verifyWithAudience(memphisGate, token, memphisAudience)) { ... }
```

`await*`, not `await`. `verifyWithAudience` is `async*`, and a plain `await` on
a module-level `async` helper that calls another contract replies with the
*inner* value instead of this method's own return.

Full guide, both halves: **[`docs/memphis.md`](https://github.com/Mercatura-Forum/thebes-sdk/blob/main/docs/memphis.md)**.

## Backend interface

The full method surface is enumerated in `docs/ARCHITECTURE.md`. The groups that
matter most for a first read:

| Group | Examples | Purpose |
| --- | --- | --- |
| Validation | `validatePain001`, `validatePacs008Xml`, `validateStatusReportXml` | Verify typed messages and supported XML against the guideline. |
| Lifecycle | `submitPain001`, `dispatchPacs008`, `acknowledgePacs002`, `returnPayment` | Drive a payment through intake, dispatch, status, and returns. |
| Audit evidence | `auditTip`, `auditProof`, `verifyAuditChain` | Read the hash-chain tip, a Merkle proof, and the MMR root. |
| Certified disclosure | `refreshCertifiedSettlementBalances`, `certifiedAuditDisclosure`, `certifiedParticipantBalance`, `verifyCertifiedDisclosure` | Commit and serve certificate-bearing disclosure envelopes. |
| Connector | `registerConnector`, `submitTransportEnvelope`, `leaseOutboundBatches`, `ackOutboundDelivery` | Run the on-chain inbound and outbound connector framework. |
| Oracles | `verifyOraclePhases`, `verifyPaymentPhases`, `verifyPfmiSelfAssessment` | Machine-readable, live-verified phase and self-assessment checks. |
| Guideline | `getGuideline`, `setGuideline`, `supportedStandards`, `capabilities` | Read or replace the rules, and read the declared standards surface. |
| Schema profiles | `validateIsoDocument`, `decodeIsoBreadth`, `encodeIsoBreadth`, `roundTripIsoBreadth`, `isoSchemaProfiles` | Official-shape messages against the generated XSD profiles; the twenty typed families read and written. |
| MT bridge | `decodeMt`, `encodeMt`, `mtBridgeMappings` | Thirteen FIN types to and from the hub's records, with the mapping tables as data. |
| Rule sets | `isoRuleSets`, `isoRuleSetRules`, `validateIsoDocumentWithRuleSet`, `bindGuidelineRuleSet` | CBPR+ and HVPS+ as data, evaluated after the schema, bound to guideline profiles. |

---

## Build and test

```sh
cd motoko
mops install
mops test
"$(ls "$HOME/.cache/mops/moc/1.4.1/moc" "$HOME/Library/Caches/mops/moc/1.4.1/moc" 2>/dev/null | head -1)" --check $(mops sources) main.mo
```

## Deploy

```sh
thebes-deploy identity new me
thebes-deploy deploy iso20022
```

> **Deploying your own copy?** The committed `cid` pins the **live catalog
> deployment** (only its controller can upgrade it). Before your first deploy,
> set `cid = "auto"` in `thebes.toml`: the deploy allocates a fresh canister
> you control and writes its id back into the manifest.

---

## What it builds on

This template stands on work already proven elsewhere in the protocol. The
`thebes-lib` `Admin` and `Pagination` modules are shared with the other Thebes
examples. The audit posture follows the ICRC-ME pattern: standards discovery,
explicit capability metadata, append-only records, hash linkage, and bounded
reads. `motoko/BloomFilter.mo` and `motoko/AuditMMR.mo` adapt ledger ideas for
duplicate prefiltering and compact append-only evidence, and
`motoko/InPlaceSha256d.mo` is vendored from allocation-free Merkle and
SHA-256d work contributed to a Litecoin node implementation.

---

## License

Apache-2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).

Built and maintained by the **Thebes Core Team**.
