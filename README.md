# Pact Contracts

PACT now uses an ERC-8183-aligned commerce kernel instead of the older proprietary escrow/router pair. The core primitive is a `Job` with escrowed payment, provider submission, evaluator attestation, optional hooks, and expiry-based refunds.

## Build and Test

Dependencies are pinned in `foundry.toml` and `soldeer.lock` and are installed into the gitignored `dependencies/` directory via Soldeer.

```bash
forge soldeer install
forge build
forge test
```

## ERC-8183 Commerce

### `PactCommerce`
File: `src/PactCommerce.sol`

Purpose:
- Implements the ERC-8183 job lifecycle: `Open -> Funded -> Submitted -> Terminal`.
- Escrows a single ERC-20 payment token per contract and settles deterministically.
- Supports optional platform fee payout to a treasury on completion only.
- Stores onchain job records: description, deliverable reference, evaluator attestation, and terminal status.
- Exposes the standard hook surface around `setProvider`, `setBudget`, `fund`, `submit`, `complete`, and `reject`.
- Bounds external hook execution with `HOOK_GAS_LIMIT` so policy hooks cannot consume unbounded gas.
- Exposes `previewPayout(jobId)` so clients and frontends can quote provider/treasury settlement before completion.

Roles:
- `client`: creates the job, can set provider, negotiate budget, fund escrow, and reject while still `Open`.
- `provider`: sets or negotiates budget and submits the deliverable reference.
- `evaluator`: a single address that may reject while `Funded`, and complete or reject while `Submitted`.

Core lifecycle:
1. `createJob(provider, evaluator, expiredAt, description, hook)`
2. `setProvider(jobId, provider, optParams)` when created with `provider = address(0)`
3. `setBudget(jobId, amount, optParams)`
4. `fund(jobId, expectedBudget, optParams)`
5. `submit(jobId, deliverable, optParams)`
6. `complete(jobId, reason, optParams)` or `reject(jobId, reason, optParams)`
7. `claimRefund(jobId)` after expiry from `Funded` or `Submitted`

Events:
- `JobCreated`
- `ProviderSet`
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
- `ReputationGateHook` is a concrete PACT policy hook that enforces a minimum provider score on assignment/funding, emits `ProviderScoreVerified`, and records callback + score-check activity for auditing.

PACT-specific direction carried through hooks:
- Reputation gating and allowlists
- Privacy-preserving job policies via opaque `optParams`
- Underwriting and risk checks before funding
- Capital-transfer or fund-management side effects in `afterAction`
- Bidding or assignment verification in `setProvider`
- Custom settlement or reputation updates on terminal transitions

### Deterministic / ZK-style Evaluator
File: `src/evaluators/DeterministicReceiptEvaluator.sol`

Purpose:
- Demonstrates the ERC-8183 evaluator as a contract address.
- Reads the submitted deliverable commitment from `PactCommerce`.
- Completes or rejects the job based on a configured deterministic expectation.
- Forwards opaque evaluator `optParams` into `PactCommerce` so receipt bundles, proof URIs, or policy metadata survive into hook processing.

This is the PACT path for zk-proof verifiers, receipts, or other deterministic validation contracts. Human judges, multisigs, and DAOs fit the same surface by simply being the `evaluator` address on a job.

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
- client rejection from `Open`
- expiry reclaim
- payout previewing for frontends and settlement UX
- hook enforcement, callback recording, and provider-score verification telemetry
- rollback when an `afterAction` policy hook rejects settlement
- deterministic evaluator completion and rejection paths, including forwarded opaque evaluation params
