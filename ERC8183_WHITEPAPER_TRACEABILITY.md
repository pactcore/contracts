# ERC-8183 Whitepaper Traceability

This note maps the current Solidity implementation to the latest English whitepaper source at `/root/.openclaw/workspace/whitepaper-source/pact_whitepaper_research_en_v3.md`.

## Implemented contract coverage

### 6.3 Multi-layer validation flow

Whitepaper intent:
- Layer 1 auto validation cheaply handles clear-cut submissions before subjective review is needed.
- Layer 2 agent validators review subjective work and earn a 5% validator reward.
- Incorrect validation can be slashed.
- Layer 3 human jury handles disputes and appeals.

Current implementation:
- `src/evaluators/LayeredAutoReviewEvaluator.sol` now models the Layer 1 auto-validation lane as an ERC-8183 evaluator contract that auto-completes matching submissions, auto-rejects obvious mismatches when configured to do so, or escalates uncertain cases into a designated Layer-2 review authority without changing the job's evaluator address.
- `src/evaluators/CommitteeReviewEvaluator.sol` models the Layer 2 validator committee as a single ERC-8183 evaluator address.
- Validators stake the settlement token, vote `Approve` / `Reject` / `Uncertain`, and only receive the validator share after dispute-aware accounting finalizes.
- Committee selection now excludes the job's client/provider/evaluator so the sampled validator panel stays independent from the job participants it is reviewing.
- `src/PactCommerce.sol` provides the terminal-state dispute bond lane used for appeal escalation.
- `src/HumanJury.sol` now models Layer 3 as an explicit high-reputation jury registry with pseudo-random 5-11 juror panel selection, majority voting, aligned-juror reward routing from dispute bonds, participant-exclusion rules for the client/provider/evaluator/challenger set, dispute-open-time-anchored review deadlines so jury panels cannot outlive the commerce-layer dispute expiry window, and onchain juror accuracy/response plus pending-panel load telemetry that feeds back into future panel-selection weights.
- `src/evaluators/GovernanceReviewEvaluator.sol` remains the governance/DAO escalation path above the jury lane.

### 8.1 Validator game and slashing

Whitepaper intent:
- Strategy space: `Accept`, `Reject`, `Uncertain`.
- Honest majority voters receive reward `R`.
- Deviators are slashed after three consecutive disagreements.

Current implementation:
- `CommitteeReviewEvaluator.VoteChoice` matches the whitepaper strategy space.
- Committee configuration now requires the commerce job to already be `Submitted`, and it is single-shot per job, which keeps the validator review deadline anchored to posted evidence instead of allowing premature or replayed reconfiguration windows.
- The validator share remains the commerce-layer 5% reward lane.
- `consecutiveDeviations`, `slashAfterDisagreements`, and `slashingBps` implement repeated-deviation slashing.
- `configureJob(...)` now pseudo-randomly samples a fixed per-job committee from the active validator set using owner-managed validator reputation weights, filters out validators whose current stake cannot cover the job's slashable reward requirement, reserves pending slashable stake for every selected validator before any votes are cast, tracks committee assignments versus actual vote responses, and `castVote(...)` rejects non-selected validators so not every staker can pile into every review.
- `validatorRewardForJob(jobId)`, `minimumRequiredStakeForJob(jobId)`, committee selection, and the `castVote(...)` stake-coverage check now enforce the paper's `alpha >= R / Stake` condition per job before a validator can participate.
- `finalizeJobAccounting(jobId)` delays reward allocation until either the dispute window expires or a raised dispute is resolved.

### 8.6 Dispute-game settlement

Whitepaper intent:
- Participants can accept the result or escalate through dispute.
- The dispute lane should protect honest actors while discouraging spam challenges.

Current implementation:
- `PactCommerce.raiseDispute(...)` requires the fixed dispute bond and only allows one terminal-state dispute per job.
- `PactCommerce.resolveDispute(...)` routes the bond differently for upheld vs. rejected disputes.
- `CommitteeReviewEvaluator.finalizeJobAccounting(...)` waits for either dispute expiry or dispute resolution before releasing the stake reserved at committee-selection time and validator rewards, and treats upheld appeals that end in `Expired` as no-fault outcomes so unresolved review does not count as a validator disagreement.

### 6.4 Reputation-aware policy hooks

Whitepaper intent:
- Reputation affects who can participate in task execution and review.

Current implementation:
- `src/hooks/ReputationGateHook.sol` and `src/hooks/CounterpartyPolicyHook.sol` enforce provider-score gating and evaluator allowlists around the ERC-8183 commerce flow.
- `src/evaluators/CommitteeReviewEvaluator.sol` also supports owner-managed validator reputation baselines in the whitepaper's 0-100 range, records resolved/aligned/no-contest vote history plus committee assignment/response history and resolved-appeal alignment onchain, and feeds those performance signals back into per-job committee selection weights.

## Explicit remaining gaps

The current contracts intentionally stop short of full whitepaper parity in a few places:
- Layer 1 auto validation is now represented onchain, but the actual image/GPS/timestamp inference still arrives as opaque offchain evidence hashes instead of a native onchain AI or ZK proof verifier, and the whitepaper's "free" Layer 1 economics still map onto the existing evaluator reward lane.
- Committee selection is now pseudo-random per job and combines baseline reputation, onchain review accuracy, committee response history, and resolved-appeal alignment, but it still relies on `block.prevrandao` plus owner-configured baseline scores and does not yet derive weights from direct uptime telemetry.
- Juror eligibility is reputation-gated and panel selection now blends baseline reputation with onchain appeal accuracy, response history, and concurrent panel load, but the broader whitepaper reputation system still stops short of full cross-role uptime scoring, non-jury reputation propagation, and stronger-than-`block.prevrandao` entropy for panel draws.

## Validation run

The traceability pass was checked with:

```bash
~/.foundry/bin/forge build
~/.foundry/bin/forge test
```
