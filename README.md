# Pact Contracts

PACT Contracts is the Solidity/Foundry contract suite for the PACT network.

The repository now centers its commerce layer on an ERC-8183-aligned `Job` primitive instead of the older proprietary escrow/router pair. The core flow covers escrowed payment, provider submission, evaluator attestation, optional hooks, terminal-state dispute bonding, and expiry-based refunds.

## Repository Status

This repository is intended to be public, auditable, and contributor-friendly:
- contract dependencies are managed with Soldeer
- CI runs formatting, build, and test checks on every PR
- the commerce layer exposes ERC-8183-style lifecycle, hook, and evaluator surfaces
- deterministic and governance-driven evaluator paths are both covered by tests

## License

This repository is released under the MIT license. See `LICENSE`.

## Build and Test

Dependencies are pinned in `foundry.toml` and `soldeer.lock` and are installed into the gitignored `dependencies/` directory via Soldeer.

```bash
forge soldeer install
forge fmt
forge build
forge test -vvv
```

## ERC-8183 Commerce

### `PactCommerce`
File: `src/PactCommerce.sol`

Purpose:
- Implements the ERC-8183 job lifecycle: `Open -> Funded -> Submitted -> Terminal`.
- Escrows a single ERC-20 payment token per contract and settles deterministically.
- Settles completions with the legacy PACT economics split: provider / validator / treasury / issuer = 85 / 5 / 5 / 5 by default when treasury fee is configured to 5%.
- Adds a dispute bond lane for terminal jobs so jury/governance review can be modeled without reopening escrow state, including challenger slashing splits for upheld vs. rejected disputes, explicit terminal-status overrides for upheld appeals, and a deadline before unresolved disputes can expire back to the challenger.
- Stores onchain job records: description, deliverable reference, evaluator attestation, and terminal status.
- Allows evaluator assignment or replacement while a job remains `Open`, including jobs created without an evaluator.
- Exposes the standard hook surface around `setProvider`, `setEvaluator`, `setBudget`, `fund`, `submit`, `complete`, and `reject`.
- Bounds external hook execution with `HOOK_GAS_LIMIT` so policy hooks cannot consume unbounded gas.
- Exposes `previewPayout(jobId)` and `previewSettlement(jobId)` so clients and frontends can quote aggregate withheld value plus the full provider / validator / treasury / issuer breakdown before completion.

Roles:
- `client`: creates the job, can set provider, negotiate budget, fund escrow, and reject while still `Open`.
- `provider`: sets or negotiates budget and submits the deliverable reference.
- `evaluator`: a single address that may reject while `Funded`, and complete or reject while `Submitted`; if it implements `settlementRecipient()`, the validator share routes there instead of to the evaluator address itself.
- `challenger`: posts the fixed dispute bond to escalate a terminal job into jury / governance review.
- `owner`: resolves disputes and routes the bond into challenger refund plus jury/protocol allocations while explicitly setting the final terminal job status for upheld appeals instead of reopening escrow settlement.

Core lifecycle:
1. `createJob(provider, evaluator, expiredAt, description, hook)`
2. `setProvider(jobId, provider, optParams)` when created with `provider = address(0)`
3. `setEvaluator(jobId, evaluator, optParams)` when review authority is selected later or replaced during negotiation
4. `setBudget(jobId, amount, optParams)`
5. `fund(jobId, expectedBudget, optParams)`
6. `submit(jobId, deliverable, optParams)`
7. `complete(jobId, reason, optParams)` or `reject(jobId, reason, optParams)`
8. `raiseDispute(jobId, subjectType, subjectRef, evidenceHash, expectedBondAmount)` for terminal-state jury escalation
9. `resolveDispute(disputeId, upheld, finalStatus, resolution)` by the contract owner / governance authority, applying the dispute-bond slashing split in-place and updating the final terminal job status for upheld appeals
10. `expireDispute(disputeId, resolution)` after the dispute liveness deadline to return the full bond to the challenger when review stalls
11. `claimRefund(jobId)` after expiry from `Funded` or `Submitted`

Events:
- `JobCreated`
- `ProviderSet`
- `EvaluatorSet`
- `BudgetSet`
- `JobFunded`
- `JobSubmitted`
- `JobCompleted`
- `JobRejected`
- `JobExpired`
- `PaymentReleased`
- `SettlementDistributed`
- `Refunded`
- `DisputeRaised`
- `DisputeResolved`

### Hooks
Files:
- `src/interfaces/IACPHook.sol`
- `src/hooks/BaseCommerceHook.sol`
- `src/hooks/ReputationGateHook.sol`
- `src/hooks/ApprovedEvaluatorHook.sol`
- `src/hooks/CounterpartyPolicyHook.sol`

Purpose:
- `IACPHook` follows the ERC-8183 hook interface with `beforeAction` and `afterAction`.
- `BaseCommerceHook` restricts callbacks to the commerce contract.
- `ReputationGateHook` is a concrete PACT policy hook that enforces a minimum provider score on assignment/funding, emits `ProviderScoreVerified`, and records callback and score-check activity for auditing.
- `ApprovedEvaluatorHook` is a companion evaluator-policy hook that allowlists trusted human judges, DAO evaluators, and zk/deterministic verifier contracts on assignment and funding.
- `CounterpartyPolicyHook` combines provider-score gating and evaluator allowlists in one hook so a single ERC-8183 job can enforce both policies before funding.

PACT-specific direction carried through hooks:
- reputation gating and allowlists
- evaluator allowlists for governance, human-review, or zk-verifier routes
- combined provider/evaluator policy enforcement under the single-hook job model
- privacy-preserving job policies via opaque `optParams`
- underwriting and risk checks before funding
- capital-transfer or fund-management side effects in `afterAction`
- bidding or assignment verification in `setProvider`
- custom settlement or reputation updates on terminal transitions

### Deterministic / ZK-style Evaluator
File: `src/evaluators/DeterministicReceiptEvaluator.sol`

Purpose:
- Demonstrates the ERC-8183 evaluator as a contract address.
- Reads the submitted deliverable commitment from `PactCommerce`.
- Completes or rejects the job based on a configured deterministic expectation.
- Can additionally bind evaluation to the hash of opaque evaluator `optParams`, so receipt bundles or proof payloads are checked before settlement while still being forwarded into `PactCommerce` hooks.
- Consumes expectations after evaluation so proof configurations are one-shot by default.
- Implements `settlementRecipient()` so the validator share routes to the evaluator owner instead of remaining trapped on the evaluator contract.

This is the PACT path for zk-proof verifiers, receipts, or other deterministic validation contracts. Human judges, multisigs, and DAOs fit the same surface by simply being the `evaluator` address on a job.

### Committee Evaluator
File: `src/evaluators/CommitteeReviewEvaluator.sol`

Purpose:
- Adds an ERC-8183-compatible evaluator contract for Layer-2 agent-validator review instead of a single judge address.
- Pseudo-randomly samples a per-job validator committee from the active staker set with owner-managed 1-100 reputation weights, excludes the job's client/provider/evaluator from that draw, defaults unset validators to the legacy max score, exposes the selected panel onchain, and rejects votes from non-selected validators.
- Requires `configureJob(...)` to happen only after the provider has submitted evidence, and only once per job, so the validator review window cannot start early or be reset later to reseed the committee / deadline.
- Lets selected validators stake the settlement token, cast `Approve` / `Reject` / `Uncertain` votes, and resolve a submitted job once an approval or rejection threshold is met.
- Routes the validator settlement share into the evaluator contract, rejects votes when a validator's stake cannot economically cover the job's validator reward share, and only finalizes validator rewards after either the committee dispute window expires or a terminal `raiseDispute(...)` challenge is resolved.
- Tracks consecutive deviations from the final committee-or-jury outcome and slashes validator stake after a configurable number of disagreements, so jury/governance review can override committee-majority accounting instead of merely annotating it.
- Locks validator unstaking while they still have unresolved committee jobs, preserving slashable stake until the whitepaper-style appeal lane finishes.
- Can optionally bind votes to the hash of opaque evaluator `optParams`, so receipt bundles or evidence payloads stay hash-checked all the way into settlement.

This is the PACT path for multi-agent validator committees: a job still exposes a single ERC-8183 `evaluator` address, but that address can now encapsulate quorum voting, reward routing, dispute-aware accounting, and slashing semantics internally.

### Human Jury
File: `src/HumanJury.sol`

Purpose:
- Turns terminal-state `raiseDispute(...)` appeals into a concrete Layer-3 jury contract instead of leaving review as a bare `owner()` action.
- Maintains a registry of high-reputation jurors, pseudo-randomly selects an odd-sized 5-11 member panel per dispute while excluding the job's client/provider/evaluator and the active challenger, and tracks per-dispute `Uphold` / `Reject` votes.
- Calls `resolveDispute(...)` once the panel reaches a majority and, when `PactCommerce` ownership is delegated to the jury contract, becomes the onchain jury recipient for dispute-bond payouts.
- Anchors each jury deadline to the dispute's original `openedAt` timestamp and requires the jury deadline configuration to match `PactCommerce`'s dispute-expiry window, so late-created panels cannot outlive or be bypassed by the commerce-layer expiry path.
- Routes stalled review expiry through `expireDispute(...)`, preserving the original terminal job state while refunding the challenger's full bond when jury liveness fails.
- Splits the jury share of the dispute bond across aligned jurors as claimable rewards, so the whitepaper's human-jury lane has explicit economic routing instead of an implied treasury sink.
- Keeps low-reputation or inactive jurors out of new panels while still exposing the selected panel for offchain transparency and auditability.

This closes the biggest remaining gap in the three-layer verification path: committee outcomes can now bridge into an actual jury contract before governance-level policy orchestration.

### Governance Evaluator
Files:
- `src/evaluators/GovernanceReviewEvaluator.sol`
- `src/interfaces/IGovernanceEvaluator.sol`
- `src/PactGovernance.sol`

Purpose:
- Turns DAO review into a concrete ERC-8183 evaluator path.
- Lets tokenholders create `createCommerceDecisionProposal(...)` proposals that target a governance-owned evaluator contract.
- Lets tokenholders create `createCommerceDisputeProposal(...)` proposals that resolve a posted dispute bond once `PactCommerce` ownership is delegated to governance.
- Works cleanly with deferred evaluator selection, so a client can create a job first and later route review authority to governance before funding.
- After the proposal clears voting and timelock, governance executes the evaluator call, which then completes or rejects the job from the evaluator address.
- The same proposal flow can finalize dispute review on terminal jobs without reopening escrow settlement.
- Preserves opaque evaluator `optParams` all the way through to `PactCommerce` hooks, so governance decisions can carry proposal URIs, evidence bundles, or offchain deliberation metadata.
- Implements `settlementRecipient()` so the validator share routes to the governance contract rather than staying on the evaluator shim.

This gives PACT a tested human/DAO review flow without changing the underlying ERC-8183 job permissions: `PactCommerce` still only accepts settlement from the configured evaluator address.

## Other Contracts

The rest of the repository remains unchanged:
- `src/PactIdentitySBT.sol`
- `src/PactStaking.sol`
- `src/PactGovernance.sol`
- `src/PactRewards.sol`

## Tests

`test/PactCommerce.t.sol` covers:
- full lifecycle completion
- evaluator rejection from `Funded` and `Submitted`
- human-judge completion with the client acting as evaluator
- governance-evaluator completion and rejection after DAO proposal execution
- governance-authored dispute resolution after commerce ownership is delegated to the DAO, including jury/protocol bond splits
- client rejection from `Open`
- expiry reclaim
- payout previewing for frontends and settlement UX, including the 85 / 5 / 5 / 5 provider / validator / treasury / issuer split
- hook enforcement, callback recording, provider-score verification telemetry, evaluator allowlist enforcement, and combined counterparty policy enforcement
- rollback when an `afterAction` policy hook rejects settlement
- deterministic evaluator completion and rejection paths, including forwarded opaque evaluation params, hash-bound proof bundle checks, and one-shot expectation consumption

`test/CommitteeReviewEvaluator.t.sol` covers committee approval and rejection flows, reputation-weighted sampled-committee membership enforcement, active-validator capacity checks, dispute-window gating, jury/dispute overrides of validator accounting, reward splitting across aligned validators, opt-params hash binding, and slashing after three consecutive deviations.

`test/HumanJury.t.sol` covers high-reputation jury-panel selection, low-reputation juror exclusion, upheld-vs-rejected dispute outcomes, jury reward distribution, and the bridge from committee review into final jury accounting.

`test/PactGovernance.t.sol` also covers governance-authored ERC-8183 decision and dispute proposals and verifies the encoded call target/data for both helper paths.

## Security

See `SECURITY.md` for vulnerability reporting guidance.

## Contributing

See `CONTRIBUTING.md` for development workflow and PR expectations.
