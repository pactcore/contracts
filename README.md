# Pact Contracts

PACT Contracts is the Solidity/Foundry contract suite for the PACT network.

The repository now centers its commerce layer on an ERC-8183-aligned `Job` primitive instead of the older proprietary escrow/router pair. The core flow covers escrowed payment, provider submission, evaluator attestation, optional hooks, and expiry-based refunds.

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
- Supports optional platform fee payout to a treasury on completion only.
- Stores onchain job records: description, deliverable reference, evaluator attestation, and terminal status.
- Allows evaluator assignment or replacement while a job remains `Open`, including jobs created without an evaluator.
- Exposes the standard hook surface around `setProvider`, `setEvaluator`, `setBudget`, `fund`, `submit`, `complete`, and `reject`.
- Bounds external hook execution with `HOOK_GAS_LIMIT` so policy hooks cannot consume unbounded gas.
- Exposes `previewPayout(jobId)` so clients and frontends can quote provider/treasury settlement before completion.

Roles:
- `client`: creates the job, can set provider, negotiate budget, fund escrow, and reject while still `Open`.
- `provider`: sets or negotiates budget and submits the deliverable reference.
- `evaluator`: a single address that may reject while `Funded`, and complete or reject while `Submitted`.

Core lifecycle:
1. `createJob(provider, evaluator, expiredAt, description, hook)`
2. `setProvider(jobId, provider, optParams)` when created with `provider = address(0)`
3. `setEvaluator(jobId, evaluator, optParams)` when review authority is selected later or replaced during negotiation
4. `setBudget(jobId, amount, optParams)`
5. `fund(jobId, expectedBudget, optParams)`
6. `submit(jobId, deliverable, optParams)`
7. `complete(jobId, reason, optParams)` or `reject(jobId, reason, optParams)`
8. `claimRefund(jobId)` after expiry from `Funded` or `Submitted`

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
- `Refunded`

### Hooks
Files:
- `src/interfaces/IACPHook.sol`
- `src/hooks/BaseCommerceHook.sol`
- `src/hooks/ReputationGateHook.sol`

Purpose:
- `IACPHook` follows the ERC-8183 hook interface with `beforeAction` and `afterAction`.
- `BaseCommerceHook` restricts callbacks to the commerce contract.
- `ReputationGateHook` is a concrete PACT policy hook that enforces a minimum provider score on assignment/funding, emits `ProviderScoreVerified`, and records callback and score-check activity for auditing.

PACT-specific direction carried through hooks:
- reputation gating and allowlists
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
- Forwards opaque evaluator `optParams` into `PactCommerce` so receipt bundles, proof URIs, or policy metadata survive into hook processing.

This is the PACT path for zk-proof verifiers, receipts, or other deterministic validation contracts. Human judges, multisigs, and DAOs fit the same surface by simply being the `evaluator` address on a job.

### Governance Evaluator
Files:
- `src/evaluators/GovernanceReviewEvaluator.sol`
- `src/interfaces/IGovernanceEvaluator.sol`
- `src/PactGovernance.sol`

Purpose:
- Turns DAO review into a concrete ERC-8183 evaluator path.
- Lets tokenholders create `createCommerceDecisionProposal(...)` proposals that target a governance-owned evaluator contract.
- Works cleanly with deferred evaluator selection, so a client can create a job first and later route review authority to governance before funding.
- After the proposal clears voting and timelock, governance executes the evaluator call, which then completes or rejects the job from the evaluator address.
- Preserves opaque evaluator `optParams` all the way through to `PactCommerce` hooks, so governance decisions can carry proposal URIs, evidence bundles, or offchain deliberation metadata.

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
- client rejection from `Open`
- expiry reclaim
- payout previewing for frontends and settlement UX
- hook enforcement, callback recording, and provider-score verification telemetry
- rollback when an `afterAction` policy hook rejects settlement
- deterministic evaluator completion and rejection paths, including forwarded opaque evaluation params

`test/PactGovernance.t.sol` also covers governance-authored ERC-8183 decision proposals and verifies the encoded call target/data for the governance evaluator path.

## Security

See `SECURITY.md` for vulnerability reporting guidance.

## Contributing

See `CONTRIBUTING.md` for development workflow and PR expectations.
