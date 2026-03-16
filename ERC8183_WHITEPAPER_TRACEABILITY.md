# ERC-8183 Whitepaper Traceability

This note maps the current Solidity implementation to the latest English whitepaper source at `/root/.openclaw/workspace/whitepaper-source/pact_whitepaper_research_en_v3.md`.

## Implemented contract coverage

### 6.3 Multi-layer validation flow

Whitepaper intent:
- Layer 2 agent validators review subjective work and earn a 5% validator reward.
- Incorrect validation can be slashed.
- Layer 3 human jury handles disputes and appeals.

Current implementation:
- `src/evaluators/CommitteeReviewEvaluator.sol` models the Layer 2 validator committee as a single ERC-8183 evaluator address.
- Validators stake the settlement token, vote `Approve` / `Reject` / `Uncertain`, and only receive the validator share after dispute-aware accounting finalizes.
- Committee selection now excludes the job's client/provider/evaluator so the sampled validator panel stays independent from the job participants it is reviewing.
- `src/PactCommerce.sol` provides the terminal-state dispute bond lane used for appeal escalation.
- `src/HumanJury.sol` now models Layer 3 as an explicit high-reputation jury registry with pseudo-random 5-11 juror panel selection, majority voting, aligned-juror reward routing from dispute bonds, participant-exclusion rules for the client/provider/evaluator/challenger set, and dispute-open-time-anchored review deadlines so jury panels cannot outlive the commerce-layer dispute expiry window.
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
- `configureJob(...)` now pseudo-randomly samples a fixed per-job committee from the active validator set using owner-managed validator reputation weights, filters out validators whose current stake cannot cover the job's slashable reward requirement, reserves pending slashable stake for every selected validator before any votes are cast, and `castVote(...)` rejects non-selected validators so not every staker can pile into every review.
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
- `src/evaluators/CommitteeReviewEvaluator.sol` also supports owner-managed validator reputation baselines in the whitepaper's 0-100 range, records resolved/aligned/no-contest vote history onchain, and feeds that performance history back into per-job committee selection weights.

## Explicit remaining gaps

The current contracts intentionally stop short of full whitepaper parity in a few places:
- No onchain Layer 1 auto-validation module exists yet; the repo starts at ERC-8183 job submission plus evaluator review.
- Committee selection is now pseudo-random per job and reputation-weighted, but it still relies on `block.prevrandao` plus owner-configured baseline scores; the new onchain accuracy history only partially closes the broader whitepaper reputation-system gap and does not yet derive weights from uptime or appeal win rate.
- Juror eligibility is reputation-gated and panel selection is pseudo-random, but the full whitepaper reputation system (validator accuracy, appeal win rate, uptime, broader juror scoring updates) is not yet persisted onchain.

## Validation run

The traceability pass was checked with:

```bash
~/.foundry/bin/forge build
~/.foundry/bin/forge test
```
