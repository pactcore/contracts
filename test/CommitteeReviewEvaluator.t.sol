// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {PactCommerce} from "../src/PactCommerce.sol";
import {CommitteeReviewEvaluator} from "../src/evaluators/CommitteeReviewEvaluator.sol";
import {IPactCommerce} from "../src/interfaces/IPactCommerce.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

contract CommitteeReviewEvaluatorTest is Test {
    MockUSDC private usdc;
    PactCommerce private commerce;
    CommitteeReviewEvaluator private committeeEvaluator;

    address private client = makeAddr("client");
    address private provider = makeAddr("provider");
    address private treasury = makeAddr("treasury");
    address private challenger = makeAddr("challenger");
    address private validatorA = makeAddr("validatorA");
    address private validatorB = makeAddr("validatorB");
    address private validatorC = makeAddr("validatorC");
    address private validatorD = makeAddr("validatorD");

    uint256 private constant INITIAL_BALANCE = 20_000e6;
    uint256 private constant VALIDATOR_BANKROLL = 5_000e6;
    uint256 private constant CHALLENGER_BANKROLL = 1_000e6;
    uint256 private constant BUDGET = 1_000e6;
    uint256 private constant MINIMUM_STAKE = 500e6;
    uint256 private constant DISPUTE_WINDOW = 1 days;
    uint16 private constant PLATFORM_FEE_BPS = 500;
    uint16 private constant VALIDATOR_REWARD_BPS = 500;
    uint16 private constant ISSUER_REBATE_BPS = 500;
    uint16 private constant SLASHING_BPS = 1_000;
    uint8 private constant SLASH_AFTER_DISAGREEMENTS = 3;
    uint256 private constant REVIEW_DEADLINE = 3 days;

    function setUp() external {
        usdc = new MockUSDC();
        commerce = new PactCommerce(address(usdc), treasury, PLATFORM_FEE_BPS);
        committeeEvaluator = new CommitteeReviewEvaluator(
            address(commerce),
            address(usdc),
            MINIMUM_STAKE,
            DISPUTE_WINDOW,
            REVIEW_DEADLINE,
            SLASHING_BPS,
            SLASH_AFTER_DISAGREEMENTS,
            treasury
        );

        usdc.mint(client, INITIAL_BALANCE);
        usdc.mint(challenger, CHALLENGER_BANKROLL);
        usdc.mint(validatorA, VALIDATOR_BANKROLL);
        usdc.mint(validatorB, VALIDATOR_BANKROLL);
        usdc.mint(validatorC, VALIDATOR_BANKROLL);

        vm.prank(client);
        usdc.approve(address(commerce), type(uint256).max);

        vm.prank(challenger);
        usdc.approve(address(commerce), type(uint256).max);

        _approveAndStake(validatorA, MINIMUM_STAKE);
        _approveAndStake(validatorB, MINIMUM_STAKE);
        _approveAndStake(validatorC, MINIMUM_STAKE);
    }

    function testCommitteeApprovalsCompleteJobAndSplitValidatorRewardAfterDisputeWindow() external {
        uint256 jobId = _createAndFundJob(7 days);
        bytes32 deliverable = keccak256("deliverable:committee-approval");
        bytes32 successAttestation = keccak256("attestation:committee-approved");
        bytes32 failureAttestation = keccak256("attestation:committee-rejected");
        bytes memory optParams = abi.encode("receipt://bundle", uint256(17));

        vm.prank(provider);
        commerce.submit(jobId, deliverable);

        committeeEvaluator.configureJobWithOptParamsHash(
            jobId, successAttestation, failureAttestation, 2, 2, keccak256(optParams)
        );

        vm.prank(validatorA);
        committeeEvaluator.castVote(jobId, CommitteeReviewEvaluator.VoteChoice.Approve, optParams);

        vm.prank(validatorB);
        committeeEvaluator.castVote(jobId, CommitteeReviewEvaluator.VoteChoice.Approve, optParams);

        IPactCommerce.Job memory job = commerce.getJob(jobId);
        assertEq(uint8(job.status), uint8(IPactCommerce.Status.Completed));
        assertEq(job.attestation, successAttestation);

        uint256 validatorReward = (BUDGET * VALIDATOR_REWARD_BPS) / 10_000;

        assertEq(
            usdc.balanceOf(provider),
            BUDGET - validatorReward - ((BUDGET * PLATFORM_FEE_BPS) / 10_000) - ((BUDGET * ISSUER_REBATE_BPS) / 10_000)
        );
        assertEq(usdc.balanceOf(treasury), (BUDGET * PLATFORM_FEE_BPS) / 10_000);
        assertEq(usdc.balanceOf(client), INITIAL_BALANCE - BUDGET + ((BUDGET * ISSUER_REBATE_BPS) / 10_000));
        assertEq(usdc.balanceOf(address(committeeEvaluator)), (MINIMUM_STAKE * 3) + validatorReward);

        vm.expectRevert(abi.encodeWithSelector(CommitteeReviewEvaluator.JobAccountingNotReady.selector));
        committeeEvaluator.finalizeJobAccounting(jobId);

        vm.expectRevert(abi.encodeWithSelector(CommitteeReviewEvaluator.PendingAccounting.selector, uint256(1)));
        vm.prank(validatorA);
        committeeEvaluator.unstake(1);

        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);
        committeeEvaluator.finalizeJobAccounting(jobId);

        _assertValidatorAccount(validatorA, MINIMUM_STAKE, validatorReward / 2, 0, 0, true);
        _assertValidatorAccount(validatorB, MINIMUM_STAKE, validatorReward / 2, 0, 0, true);
        _assertValidatorAccount(validatorC, MINIMUM_STAKE, 0, 0, 0, true);

        uint256 validatorABalanceBefore = usdc.balanceOf(validatorA);
        vm.prank(validatorA);
        committeeEvaluator.claimRewards();
        assertEq(usdc.balanceOf(validatorA), validatorABalanceBefore + (validatorReward / 2));

        vm.prank(validatorA);
        committeeEvaluator.unstake(1);
        _assertValidatorAccount(validatorA, MINIMUM_STAKE - 1, 0, 0, 0, false);
    }

    function testSelectedValidatorsCannotUnstakeBeforeVotingAndAreReleasedAfterAccounting() external {
        uint256 jobId = _createAndFundJob(7 days);
        bytes32 deliverable = keccak256("deliverable:reserved-selection");
        bytes32 successAttestation = keccak256("attestation:reserved-selection-approved");
        bytes32 failureAttestation = keccak256("attestation:reserved-selection-rejected");

        vm.prank(provider);
        commerce.submit(jobId, deliverable);

        committeeEvaluator.configureJob(jobId, successAttestation, failureAttestation, 2, 2);

        _assertValidatorAccount(validatorA, MINIMUM_STAKE, 0, 0, 1, true);
        _assertValidatorAccount(validatorB, MINIMUM_STAKE, 0, 0, 1, true);
        _assertValidatorAccount(validatorC, MINIMUM_STAKE, 0, 0, 1, true);

        vm.prank(validatorA);
        committeeEvaluator.castVote(jobId, CommitteeReviewEvaluator.VoteChoice.Approve);

        vm.prank(validatorB);
        committeeEvaluator.castVote(jobId, CommitteeReviewEvaluator.VoteChoice.Reject);

        vm.expectRevert(abi.encodeWithSelector(CommitteeReviewEvaluator.PendingAccounting.selector, uint256(1)));
        vm.prank(validatorC);
        committeeEvaluator.unstake(1);

        vm.warp(block.timestamp + REVIEW_DEADLINE + 1);
        committeeEvaluator.finalizeDeadlockedJob(jobId);

        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);
        committeeEvaluator.finalizeJobAccounting(jobId);

        _assertValidatorAccount(validatorC, MINIMUM_STAKE, 0, 0, 0, true);

        vm.prank(validatorC);
        committeeEvaluator.unstake(1);
        _assertValidatorAccount(validatorC, MINIMUM_STAKE - 1, 0, 0, 0, false);
    }

    function testCommitteeRejectionsRefundClientAndDoNotMintRewards() external {
        uint256 jobId = _createAndFundJob(7 days);
        bytes32 deliverable = keccak256("deliverable:committee-rejection");
        bytes32 successAttestation = keccak256("attestation:committee-approved");
        bytes32 failureAttestation = keccak256("attestation:committee-rejected");

        vm.prank(provider);
        commerce.submit(jobId, deliverable);

        committeeEvaluator.configureJob(jobId, successAttestation, failureAttestation, 2, 2);

        vm.prank(validatorA);
        committeeEvaluator.castVote(jobId, CommitteeReviewEvaluator.VoteChoice.Reject);

        vm.prank(validatorB);
        committeeEvaluator.castVote(jobId, CommitteeReviewEvaluator.VoteChoice.Reject);

        IPactCommerce.Job memory job = commerce.getJob(jobId);
        assertEq(uint8(job.status), uint8(IPactCommerce.Status.Rejected));
        assertEq(job.attestation, failureAttestation);
        assertEq(usdc.balanceOf(client), INITIAL_BALANCE);
        assertEq(usdc.balanceOf(address(committeeEvaluator)), MINIMUM_STAKE * 3);

        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);
        committeeEvaluator.finalizeJobAccounting(jobId);

        _assertValidatorAccount(validatorA, MINIMUM_STAKE, 0, 0, 0, true);
        _assertValidatorAccount(validatorB, MINIMUM_STAKE, 0, 0, 0, true);
    }

    function testCommitteeSlashesValidatorAfterThreeConsecutiveDeviations() external {
        uint256 treasuryBefore = usdc.balanceOf(treasury);
        uint256 slashAmount = (MINIMUM_STAKE * SLASHING_BPS) / 10_000;

        for (uint256 i = 0; i < 3; ++i) {
            uint256 jobId = _createAndFundJob(7 days);
            bytes32 deliverable = keccak256(abi.encodePacked("deliverable:deviation", i));
            bytes32 successAttestation = keccak256(abi.encodePacked("attestation:approved", i));
            bytes32 failureAttestation = keccak256(abi.encodePacked("attestation:rejected", i));

            vm.prank(provider);
            commerce.submit(jobId, deliverable);

            committeeEvaluator.configureJob(jobId, successAttestation, failureAttestation, 2, 2);

            vm.prank(validatorA);
            committeeEvaluator.castVote(jobId, CommitteeReviewEvaluator.VoteChoice.Approve);

            vm.prank(validatorC);
            committeeEvaluator.castVote(jobId, CommitteeReviewEvaluator.VoteChoice.Reject);

            vm.prank(validatorB);
            committeeEvaluator.castVote(jobId, CommitteeReviewEvaluator.VoteChoice.Approve);

            vm.warp(block.timestamp + DISPUTE_WINDOW + 1);
            committeeEvaluator.finalizeJobAccounting(jobId);
        }

        uint256 treasuryFees = (BUDGET * PLATFORM_FEE_BPS * 3) / 10_000;
        assertEq(usdc.balanceOf(treasury), treasuryBefore + treasuryFees + slashAmount);

        _assertValidatorAccount(validatorC, MINIMUM_STAKE - slashAmount, 0, 0, 0, false);
        _assertValidatorPerformance(validatorA, 3, 3, 0, 0);
        _assertValidatorPerformance(validatorB, 3, 3, 0, 0);
        _assertValidatorPerformance(validatorC, 3, 0, 0, 0);
        assertEq(committeeEvaluator.validatorReputation(validatorA), 100);
        assertEq(committeeEvaluator.validatorReputation(validatorC), 57);
    }

    function testDisputeResolutionCanOverrideCommitteeAccountingAndRewards() external {
        uint256 jobId = _createAndFundJob(7 days);
        bytes32 deliverable = keccak256("deliverable:jury-override");
        bytes32 successAttestation = keccak256("attestation:jury-approved");
        bytes32 failureAttestation = keccak256("attestation:jury-rejected");
        bytes32 disputeSubjectType = keccak256("committee-decision");
        bytes32 disputeSubjectRef = keccak256("committee://jury-override");
        bytes32 disputeEvidence = keccak256("evidence://jury-override");
        uint256 validatorReward = (BUDGET * VALIDATOR_REWARD_BPS) / 10_000;

        vm.prank(provider);
        commerce.submit(jobId, deliverable);

        committeeEvaluator.configureJob(jobId, successAttestation, failureAttestation, 2, 2);

        vm.prank(validatorA);
        committeeEvaluator.castVote(jobId, CommitteeReviewEvaluator.VoteChoice.Approve);

        vm.prank(validatorC);
        committeeEvaluator.castVote(jobId, CommitteeReviewEvaluator.VoteChoice.Reject);

        vm.prank(validatorB);
        committeeEvaluator.castVote(jobId, CommitteeReviewEvaluator.VoteChoice.Approve);

        vm.expectRevert(abi.encodeWithSelector(CommitteeReviewEvaluator.PendingAccounting.selector, uint256(1)));
        vm.prank(validatorC);
        committeeEvaluator.unstake(1);

        uint256 disputeBond = commerce.disputeBondAmount();
        uint256 challengerBalanceBefore = usdc.balanceOf(challenger);
        uint256 treasuryBalanceBefore = usdc.balanceOf(treasury);

        vm.prank(challenger);
        uint256 disputeId =
            commerce.raiseDispute(jobId, disputeSubjectType, disputeSubjectRef, disputeEvidence, disputeBond);

        vm.expectRevert(abi.encodeWithSelector(CommitteeReviewEvaluator.JobAccountingNotReady.selector));
        committeeEvaluator.finalizeJobAccounting(jobId);

        commerce.resolveDispute(disputeId, true, IPactCommerce.Status.Rejected, failureAttestation);
        committeeEvaluator.finalizeJobAccounting(jobId);

        IPactCommerce.Dispute memory dispute = commerce.getDispute(disputeId);
        assertEq(uint8(dispute.status), uint8(IPactCommerce.DisputeStatus.Upheld));
        assertEq(dispute.resolution, failureAttestation);
        assertEq(usdc.balanceOf(challenger), challengerBalanceBefore - (disputeBond / 10));
        assertEq(usdc.balanceOf(treasury), treasuryBalanceBefore + (disputeBond / 20));

        IPactCommerce.Job memory job = commerce.getJob(jobId);
        assertEq(uint8(job.status), uint8(IPactCommerce.Status.Rejected));
        assertEq(job.attestation, failureAttestation);

        _assertValidatorAccount(validatorA, MINIMUM_STAKE, 0, 1, 0, true);
        _assertValidatorAccount(validatorB, MINIMUM_STAKE, 0, 1, 0, true);
        _assertValidatorAccount(validatorC, MINIMUM_STAKE, validatorReward, 0, 0, true);
        _assertValidatorPerformance(validatorA, 1, 0, 1, 0);
        _assertValidatorPerformance(validatorB, 1, 0, 1, 0);
        _assertValidatorPerformance(validatorC, 1, 1, 1, 0);
        assertEq(committeeEvaluator.validatorReputation(validatorA), 80);
        assertEq(committeeEvaluator.validatorReputation(validatorB), 80);
        assertEq(committeeEvaluator.validatorReputation(validatorC), 100);

        uint256 validatorCBalanceBefore = usdc.balanceOf(validatorC);
        vm.prank(validatorC);
        committeeEvaluator.claimRewards();
        assertEq(usdc.balanceOf(validatorC), validatorCBalanceBefore + validatorReward);
    }

    function testExpiredAppealOutcomeFinalizesAccountingWithoutValidatorRewards() external {
        uint256 jobId = _createAndFundJob(7 days);
        bytes32 deliverable = keccak256("deliverable:expired-appeal");
        bytes32 successAttestation = keccak256("attestation:committee-approved-expired-appeal");
        bytes32 failureAttestation = keccak256("attestation:committee-rejected-expired-appeal");
        bytes32 expiredResolution = keccak256("jury:expired-final-status");
        uint256 validatorReward = (BUDGET * VALIDATOR_REWARD_BPS) / 10_000;

        vm.prank(provider);
        commerce.submit(jobId, deliverable);

        committeeEvaluator.configureJob(jobId, successAttestation, failureAttestation, 2, 2);

        vm.prank(validatorA);
        committeeEvaluator.castVote(jobId, CommitteeReviewEvaluator.VoteChoice.Approve);

        vm.prank(validatorC);
        committeeEvaluator.castVote(jobId, CommitteeReviewEvaluator.VoteChoice.Reject);

        vm.prank(validatorB);
        committeeEvaluator.castVote(jobId, CommitteeReviewEvaluator.VoteChoice.Approve);

        uint256 disputeBond = commerce.disputeBondAmount();
        uint256 challengerBalanceBefore = usdc.balanceOf(challenger);
        uint256 treasuryBalanceBefore = usdc.balanceOf(treasury);

        vm.prank(challenger);
        uint256 disputeId = commerce.raiseDispute(
            jobId,
            keccak256("committee-decision"),
            keccak256("committee://expired"),
            keccak256("evidence://expired"),
            disputeBond
        );

        commerce.resolveDispute(disputeId, true, IPactCommerce.Status.Expired, expiredResolution);
        committeeEvaluator.finalizeJobAccounting(jobId);

        IPactCommerce.Dispute memory dispute = commerce.getDispute(disputeId);
        IPactCommerce.Job memory job = commerce.getJob(jobId);
        assertEq(uint8(dispute.status), uint8(IPactCommerce.DisputeStatus.Upheld));
        assertEq(dispute.resolution, expiredResolution);
        assertEq(uint8(job.status), uint8(IPactCommerce.Status.Expired));
        assertEq(job.attestation, expiredResolution);

        _assertValidatorAccount(validatorA, MINIMUM_STAKE, 0, 0, 0, true);
        _assertValidatorAccount(validatorB, MINIMUM_STAKE, 0, 0, 0, true);
        _assertValidatorAccount(validatorC, MINIMUM_STAKE, 0, 0, 0, true);

        uint256 penaltyAmount = disputeBond / 10;
        assertEq(usdc.balanceOf(challenger), challengerBalanceBefore - penaltyAmount);
        assertEq(usdc.balanceOf(treasury), treasuryBalanceBefore + (penaltyAmount / 2) + validatorReward);
        assertEq(usdc.balanceOf(address(committeeEvaluator)), MINIMUM_STAKE * 3);
    }

    function testExpiredAppealOutcomeDoesNotIncrementExistingDeviationCounts() external {
        uint256 validatorReward = (BUDGET * VALIDATOR_REWARD_BPS) / 10_000;

        uint256 firstJobId = _createAndFundJob(7 days);
        bytes32 firstDeliverable = keccak256("deliverable:baseline-deviation");
        bytes32 firstSuccessAttestation = keccak256("attestation:baseline-approved");
        bytes32 firstFailureAttestation = keccak256("attestation:baseline-rejected");

        vm.prank(provider);
        commerce.submit(firstJobId, firstDeliverable);

        committeeEvaluator.configureJob(firstJobId, firstSuccessAttestation, firstFailureAttestation, 2, 2);

        vm.prank(validatorA);
        committeeEvaluator.castVote(firstJobId, CommitteeReviewEvaluator.VoteChoice.Approve);

        vm.prank(validatorC);
        committeeEvaluator.castVote(firstJobId, CommitteeReviewEvaluator.VoteChoice.Reject);

        vm.prank(validatorB);
        committeeEvaluator.castVote(firstJobId, CommitteeReviewEvaluator.VoteChoice.Approve);

        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);
        committeeEvaluator.finalizeJobAccounting(firstJobId);

        _assertValidatorAccount(validatorA, MINIMUM_STAKE, validatorReward / 2, 0, 0, true);
        _assertValidatorAccount(validatorB, MINIMUM_STAKE, validatorReward / 2, 0, 0, true);
        _assertValidatorAccount(validatorC, MINIMUM_STAKE, 0, 1, 0, true);

        uint256 secondJobId = _createAndFundJob(7 days);
        bytes32 secondDeliverable = keccak256("deliverable:expired-appeal-baseline");
        bytes32 secondSuccessAttestation = keccak256("attestation:expired-appeal-baseline-approved");
        bytes32 secondFailureAttestation = keccak256("attestation:expired-appeal-baseline-rejected");
        bytes32 expiredResolution = keccak256("jury:expired-with-baseline-deviation");

        vm.prank(provider);
        commerce.submit(secondJobId, secondDeliverable);

        committeeEvaluator.configureJob(secondJobId, secondSuccessAttestation, secondFailureAttestation, 2, 2);

        vm.prank(validatorA);
        committeeEvaluator.castVote(secondJobId, CommitteeReviewEvaluator.VoteChoice.Approve);

        vm.prank(validatorC);
        committeeEvaluator.castVote(secondJobId, CommitteeReviewEvaluator.VoteChoice.Reject);

        vm.prank(validatorB);
        committeeEvaluator.castVote(secondJobId, CommitteeReviewEvaluator.VoteChoice.Approve);

        uint256 disputeBond = commerce.disputeBondAmount();

        vm.prank(challenger);
        uint256 disputeId = commerce.raiseDispute(
            secondJobId,
            keccak256("committee-decision"),
            keccak256("committee://expired-baseline"),
            keccak256("evidence://expired-baseline"),
            disputeBond
        );

        commerce.resolveDispute(disputeId, true, IPactCommerce.Status.Expired, expiredResolution);
        committeeEvaluator.finalizeJobAccounting(secondJobId);

        _assertValidatorAccount(validatorA, MINIMUM_STAKE, validatorReward / 2, 0, 0, true);
        _assertValidatorAccount(validatorB, MINIMUM_STAKE, validatorReward / 2, 0, 0, true);
        _assertValidatorAccount(validatorC, MINIMUM_STAKE, 0, 1, 0, true);
        _assertValidatorPerformance(validatorA, 1, 1, 1, 1);
        _assertValidatorPerformance(validatorB, 1, 1, 1, 1);
        _assertValidatorPerformance(validatorC, 1, 0, 1, 1);
        assertEq(committeeEvaluator.validatorReputation(validatorA), 100);
        assertEq(committeeEvaluator.validatorReputation(validatorC), 80);
    }

    function testCommitteeRejectsUnexpectedOptParamsHash() external {
        uint256 jobId = _createAndFundJob(7 days);
        bytes32 deliverable = keccak256("deliverable:hash-bound");
        bytes32 successAttestation = keccak256("attestation:hash-bound-approved");
        bytes32 failureAttestation = keccak256("attestation:hash-bound-rejected");
        bytes memory expectedOptParams = abi.encode("receipt://bundle", uint256(88));
        bytes memory wrongOptParams = abi.encode("receipt://bundle", uint256(99));

        vm.prank(provider);
        commerce.submit(jobId, deliverable);

        committeeEvaluator.configureJobWithOptParamsHash(
            jobId, successAttestation, failureAttestation, 2, 2, keccak256(expectedOptParams)
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                CommitteeReviewEvaluator.InvalidOptParamsHash.selector,
                keccak256(wrongOptParams),
                keccak256(expectedOptParams)
            )
        );
        vm.prank(validatorA);
        committeeEvaluator.castVote(jobId, CommitteeReviewEvaluator.VoteChoice.Approve, wrongOptParams);
    }

    function testConfigureJobRevertsWhenTooFewValidatorsCanCoverReward() external {
        uint256 undercollateralizedMinimumStake = 300e6;
        CommitteeReviewEvaluator undercollateralizedEvaluator = new CommitteeReviewEvaluator(
            address(commerce),
            address(usdc),
            undercollateralizedMinimumStake,
            DISPUTE_WINDOW,
            REVIEW_DEADLINE,
            SLASHING_BPS,
            SLASH_AFTER_DISAGREEMENTS,
            treasury
        );
        address undercollateralizedValidator = makeAddr("undercollateralizedValidator");

        usdc.mint(undercollateralizedValidator, VALIDATOR_BANKROLL);
        _approveAndStake(
            address(undercollateralizedEvaluator), undercollateralizedValidator, undercollateralizedMinimumStake
        );

        vm.prank(client);
        uint256 jobId = commerce.createJob(
            provider, address(undercollateralizedEvaluator), block.timestamp + 7 days, "committee-reviewed ERC-8183 job"
        );

        vm.prank(client);
        commerce.setBudget(jobId, BUDGET);

        vm.prank(client);
        commerce.fund(jobId, BUDGET);

        vm.prank(provider);
        commerce.submit(jobId, keccak256("deliverable:stake-coverage"));

        uint256 validatorReward = undercollateralizedEvaluator.validatorRewardForJob(jobId);
        uint256 requiredStake = undercollateralizedEvaluator.minimumRequiredStakeForJob(jobId);
        assertEq(validatorReward, (BUDGET * VALIDATOR_REWARD_BPS) / 10_000);
        assertEq(requiredStake, 500e6);

        vm.expectRevert(
            abi.encodeWithSelector(
                CommitteeReviewEvaluator.InsufficientEligibleValidators.selector, uint256(0), uint256(1)
            )
        );
        undercollateralizedEvaluator.configureJob(
            jobId,
            keccak256("attestation:stake-coverage-approved"),
            keccak256("attestation:stake-coverage-rejected"),
            1,
            1
        );
    }

    function testSampledCommitteeExcludesValidatorsWithoutSlashCoverage() external {
        uint256 undercollateralizedMinimumStake = 300e6;
        CommitteeReviewEvaluator mixedStakeEvaluator = new CommitteeReviewEvaluator(
            address(commerce),
            address(usdc),
            undercollateralizedMinimumStake,
            DISPUTE_WINDOW,
            REVIEW_DEADLINE,
            SLASHING_BPS,
            SLASH_AFTER_DISAGREEMENTS,
            treasury
        );
        address undercollateralizedValidator = makeAddr("undercollateralizedValidator");
        address healthyValidator = makeAddr("healthyValidator");

        usdc.mint(undercollateralizedValidator, VALIDATOR_BANKROLL);
        usdc.mint(healthyValidator, VALIDATOR_BANKROLL);
        _approveAndStake(address(mixedStakeEvaluator), undercollateralizedValidator, undercollateralizedMinimumStake);
        _approveAndStake(address(mixedStakeEvaluator), healthyValidator, 500e6);

        vm.prank(client);
        uint256 jobId = commerce.createJob(
            provider, address(mixedStakeEvaluator), block.timestamp + 7 days, "committee-reviewed ERC-8183 job"
        );

        vm.prank(client);
        commerce.setBudget(jobId, BUDGET);

        vm.prank(client);
        commerce.fund(jobId, BUDGET);

        vm.prank(provider);
        commerce.submit(jobId, keccak256("deliverable:sampled-stake-coverage"));

        mixedStakeEvaluator.configureJob(
            jobId,
            keccak256("attestation:sampled-stake-coverage-approved"),
            keccak256("attestation:sampled-stake-coverage-rejected"),
            1,
            1
        );

        address[] memory committee = mixedStakeEvaluator.getCommittee(jobId);
        assertEq(committee.length, 1);
        assertEq(committee[0], healthyValidator);
        assertFalse(_containsAddress(committee, undercollateralizedValidator));

        vm.expectRevert(
            abi.encodeWithSelector(CommitteeReviewEvaluator.ValidatorNotSelected.selector, undercollateralizedValidator)
        );
        vm.prank(undercollateralizedValidator);
        mixedStakeEvaluator.castVote(jobId, CommitteeReviewEvaluator.VoteChoice.Approve);
    }

    function testConfigureJobRevertsBeforeProviderSubmission() external {
        uint256 jobId = _createAndFundJob(7 days);

        vm.expectRevert(CommitteeReviewEvaluator.InvalidJobStatus.selector);
        committeeEvaluator.configureJob(
            jobId, keccak256("attestation:premature-approved"), keccak256("attestation:premature-rejected"), 2, 2
        );
    }

    function testConfigureJobRevertsWhenReviewIsAlreadyConfigured() external {
        uint256 jobId = _createAndFundJob(7 days);
        bytes32 deliverable = keccak256("deliverable:single-shot-config");

        vm.prank(provider);
        commerce.submit(jobId, deliverable);

        committeeEvaluator.configureJob(
            jobId, keccak256("attestation:single-shot-approved"), keccak256("attestation:single-shot-rejected"), 2, 2
        );

        vm.expectRevert(CommitteeReviewEvaluator.JobAlreadyConfigured.selector);
        committeeEvaluator.configureJob(
            jobId,
            keccak256("attestation:single-shot-approved-2"),
            keccak256("attestation:single-shot-rejected-2"),
            2,
            2
        );
    }

    function testConfigureJobRevertsWhenVotesAlreadyExist() external {
        uint256 jobId = _createAndFundJob(7 days);
        bytes32 deliverable = keccak256("deliverable:no-vote-reset");
        bytes32 successAttestation = keccak256("attestation:no-vote-reset-approved");
        bytes32 failureAttestation = keccak256("attestation:no-vote-reset-rejected");

        vm.prank(provider);
        commerce.submit(jobId, deliverable);

        committeeEvaluator.configureJob(jobId, successAttestation, failureAttestation, 2, 2);

        address[] memory committee = committeeEvaluator.getCommittee(jobId);
        vm.prank(committee[0]);
        committeeEvaluator.castVote(jobId, CommitteeReviewEvaluator.VoteChoice.Approve);

        vm.expectRevert(CommitteeReviewEvaluator.JobAlreadyConfigured.selector);
        committeeEvaluator.configureJob(
            jobId,
            keccak256("attestation:no-vote-reset-approved-2"),
            keccak256("attestation:no-vote-reset-rejected-2"),
            2,
            2
        );

        assertEq(
            uint8(committeeEvaluator.votes(jobId, committee[0])), uint8(CommitteeReviewEvaluator.VoteChoice.Approve)
        );
        _assertValidatorAccount(committee[0], MINIMUM_STAKE, 0, 0, 1, true);
    }

    function testConfigureJobRevertsAfterJobAlreadyTerminal() external {
        uint256 jobId = _createAndFundJob(7 days);
        bytes32 deliverable = keccak256("deliverable:terminal-config");
        bytes32 successAttestation = keccak256("attestation:terminal-approved");
        bytes32 failureAttestation = keccak256("attestation:terminal-rejected");

        vm.prank(provider);
        commerce.submit(jobId, deliverable);

        committeeEvaluator.configureJob(jobId, successAttestation, failureAttestation, 2, 2);

        vm.prank(validatorA);
        committeeEvaluator.castVote(jobId, CommitteeReviewEvaluator.VoteChoice.Approve);

        vm.prank(validatorB);
        committeeEvaluator.castVote(jobId, CommitteeReviewEvaluator.VoteChoice.Approve);

        vm.expectRevert(CommitteeReviewEvaluator.InvalidJobStatus.selector);
        committeeEvaluator.configureJob(
            jobId, keccak256("attestation:reconfigured-approved"), keccak256("attestation:reconfigured-rejected"), 2, 2
        );
    }

    function testConfigureJobRevertsWhenThresholdsNeedMoreActiveValidators() external {
        uint256 jobId = _createAndFundJob(7 days);

        vm.prank(provider);
        commerce.submit(jobId, keccak256("deliverable:insufficient-active-set"));

        vm.expectRevert(
            abi.encodeWithSelector(
                CommitteeReviewEvaluator.InsufficientActiveValidators.selector, uint256(4), uint256(3)
            )
        );
        committeeEvaluator.configureJob(
            jobId,
            keccak256("attestation:insufficient-active-approved"),
            keccak256("attestation:insufficient-active-rejected"),
            3,
            2
        );
    }

    function testConfigureJobRevertsWhenOnlyParticipantsCanFillCommittee() external {
        CommitteeReviewEvaluator conflictedEvaluator = new CommitteeReviewEvaluator(
            address(commerce),
            address(usdc),
            MINIMUM_STAKE,
            DISPUTE_WINDOW,
            REVIEW_DEADLINE,
            SLASHING_BPS,
            SLASH_AFTER_DISAGREEMENTS,
            treasury
        );

        usdc.mint(provider, VALIDATOR_BANKROLL);
        usdc.mint(validatorD, VALIDATOR_BANKROLL);
        _approveAndStake(address(conflictedEvaluator), client, MINIMUM_STAKE);
        _approveAndStake(address(conflictedEvaluator), provider, MINIMUM_STAKE);
        _approveAndStake(address(conflictedEvaluator), validatorD, MINIMUM_STAKE);

        vm.prank(client);
        uint256 jobId = commerce.createJob(
            provider, address(conflictedEvaluator), block.timestamp + 7 days, "conflicted committee job"
        );

        vm.prank(client);
        commerce.setBudget(jobId, BUDGET);

        vm.prank(client);
        commerce.fund(jobId, BUDGET);

        vm.prank(provider);
        commerce.submit(jobId, keccak256("deliverable:conflicted-committee"));

        vm.expectRevert(
            abi.encodeWithSelector(
                CommitteeReviewEvaluator.InsufficientEligibleValidators.selector, uint256(1), uint256(2)
            )
        );
        conflictedEvaluator.configureJob(
            jobId, keccak256("attestation:conflicted-approved"), keccak256("attestation:conflicted-rejected"), 2, 1
        );
    }

    function testSampledCommitteeRejectsVotesFromUnselectedValidators() external {
        CommitteeReviewEvaluator sampledEvaluator = new CommitteeReviewEvaluator(
            address(commerce),
            address(usdc),
            MINIMUM_STAKE,
            DISPUTE_WINDOW,
            REVIEW_DEADLINE,
            SLASHING_BPS,
            SLASH_AFTER_DISAGREEMENTS,
            treasury
        );

        usdc.mint(validatorD, VALIDATOR_BANKROLL);
        _approveAndStake(address(sampledEvaluator), validatorA, MINIMUM_STAKE);
        _approveAndStake(address(sampledEvaluator), validatorB, MINIMUM_STAKE);
        _approveAndStake(address(sampledEvaluator), validatorC, MINIMUM_STAKE);
        _approveAndStake(address(sampledEvaluator), validatorD, MINIMUM_STAKE);

        vm.prank(client);
        uint256 jobId =
            commerce.createJob(provider, address(sampledEvaluator), block.timestamp + 7 days, "sampled committee job");

        vm.prank(client);
        commerce.setBudget(jobId, BUDGET);

        vm.prank(client);
        commerce.fund(jobId, BUDGET);

        vm.prank(provider);
        commerce.submit(jobId, keccak256("deliverable:sampled-committee"));

        sampledEvaluator.configureJob(
            jobId, keccak256("attestation:sampled-approved"), keccak256("attestation:sampled-rejected"), 2, 1
        );

        address[] memory committee = sampledEvaluator.getCommittee(jobId);
        assertEq(committee.length, 2);

        address[] memory candidates = new address[](4);
        candidates[0] = validatorA;
        candidates[1] = validatorB;
        candidates[2] = validatorC;
        candidates[3] = validatorD;

        address unselected;
        for (uint256 i = 0; i < candidates.length; ++i) {
            if (!_containsAddress(committee, candidates[i])) {
                unselected = candidates[i];
                break;
            }
        }

        assertTrue(unselected != address(0));

        vm.expectRevert(abi.encodeWithSelector(CommitteeReviewEvaluator.ValidatorNotSelected.selector, unselected));
        vm.prank(unselected);
        sampledEvaluator.castVote(jobId, CommitteeReviewEvaluator.VoteChoice.Approve);
    }

    function testWeightedCommitteeSelectionUsesValidatorReputation() external {
        CommitteeReviewEvaluator weightedEvaluator = new CommitteeReviewEvaluator(
            address(commerce),
            address(usdc),
            MINIMUM_STAKE,
            DISPUTE_WINDOW,
            REVIEW_DEADLINE,
            SLASHING_BPS,
            SLASH_AFTER_DISAGREEMENTS,
            treasury
        );

        usdc.mint(validatorD, VALIDATOR_BANKROLL);
        _approveAndStake(address(weightedEvaluator), validatorA, MINIMUM_STAKE);
        _approveAndStake(address(weightedEvaluator), validatorB, MINIMUM_STAKE);
        _approveAndStake(address(weightedEvaluator), validatorC, MINIMUM_STAKE);
        _approveAndStake(address(weightedEvaluator), validatorD, MINIMUM_STAKE);

        weightedEvaluator.setValidatorReputation(validatorA, 100);
        weightedEvaluator.setValidatorReputation(validatorB, 80);
        weightedEvaluator.setValidatorReputation(validatorC, 20);
        weightedEvaluator.setValidatorReputation(validatorD, 5);

        vm.prank(client);
        uint256 jobId = commerce.createJob(
            provider, address(weightedEvaluator), block.timestamp + 7 days, "weighted committee job"
        );

        vm.prank(client);
        commerce.setBudget(jobId, BUDGET);

        vm.prank(client);
        commerce.fund(jobId, BUDGET);

        vm.prank(provider);
        commerce.submit(jobId, keccak256("deliverable:weighted-committee"));

        bytes32 successAttestation = keccak256("attestation:weighted-approved");
        bytes32 failureAttestation = keccak256("attestation:weighted-rejected");

        vm.prevrandao(keccak256("weighted-selection-seed"));

        bytes32 selectionSeed = keccak256(
            abi.encode(block.prevrandao, block.timestamp, jobId, successAttestation, failureAttestation, uint256(2))
        );

        weightedEvaluator.configureJob(jobId, successAttestation, failureAttestation, 2, 1);

        address[] memory committee = weightedEvaluator.getCommittee(jobId);
        assertEq(committee.length, 2);
        assertEq(weightedEvaluator.validatorReputation(validatorD), 5);

        address[] memory candidates = new address[](4);
        candidates[0] = validatorA;
        candidates[1] = validatorB;
        candidates[2] = validatorC;
        candidates[3] = validatorD;

        uint16[] memory selectionWeights = new uint16[](4);
        selectionWeights[0] = 10_000;
        selectionWeights[1] = 8_000;
        selectionWeights[2] = 2_000;
        selectionWeights[3] = 500;

        address[] memory expectedCommittee = _expectedWeightedCommittee(candidates, selectionWeights, selectionSeed, 2);
        assertEq(committee[0], expectedCommittee[0]);
        assertEq(committee[1], expectedCommittee[1]);
    }

    function testValidatorResponseScoreDefaultsToMaximumAndPenalizesNoShows() external {
        assertEq(committeeEvaluator.validatorResponseScore(validatorA), 100);
        assertEq(committeeEvaluator.validatorSelectionWeight(validatorA), 10_000);

        uint256 jobId = _createAndFundJob(7 days);
        bytes32 deliverable = keccak256("deliverable:no-show-response-score");
        bytes32 successAttestation = keccak256("attestation:no-show-response-approved");
        bytes32 failureAttestation = keccak256("attestation:no-show-response-rejected");

        vm.prank(provider);
        commerce.submit(jobId, deliverable);

        committeeEvaluator.configureJob(jobId, successAttestation, failureAttestation, 2, 2);

        vm.prank(validatorA);
        committeeEvaluator.castVote(jobId, CommitteeReviewEvaluator.VoteChoice.Approve);

        vm.prank(validatorB);
        committeeEvaluator.castVote(jobId, CommitteeReviewEvaluator.VoteChoice.Approve);

        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);
        committeeEvaluator.finalizeJobAccounting(jobId);

        assertEq(committeeEvaluator.validatorAssignments(validatorA), 1);
        assertEq(committeeEvaluator.validatorResponses(validatorA), 1);
        assertEq(committeeEvaluator.validatorAssignments(validatorC), 1);
        assertEq(committeeEvaluator.validatorResponses(validatorC), 0);

        assertEq(committeeEvaluator.validatorResponseScore(validatorA), 100);
        assertEq(committeeEvaluator.validatorResponseScore(validatorC), 75);
        assertLt(committeeEvaluator.validatorSelectionWeight(validatorC), committeeEvaluator.validatorSelectionWeight(validatorA));
    }

    function testWeightedCommitteeSelectionPenalizesRepeatedNoShows() external {
        CommitteeReviewEvaluator responsiveEvaluator = new CommitteeReviewEvaluator(
            address(commerce),
            address(usdc),
            MINIMUM_STAKE,
            DISPUTE_WINDOW,
            REVIEW_DEADLINE,
            SLASHING_BPS,
            SLASH_AFTER_DISAGREEMENTS,
            treasury
        );

        usdc.mint(validatorD, VALIDATOR_BANKROLL);
        _approveAndStake(address(responsiveEvaluator), validatorA, MINIMUM_STAKE);
        _approveAndStake(address(responsiveEvaluator), validatorB, MINIMUM_STAKE);
        _approveAndStake(address(responsiveEvaluator), validatorD, MINIMUM_STAKE);

        for (uint256 i = 0; i < 3; ++i) {
            vm.prank(client);
            uint256 trainingJobId = commerce.createJob(
                provider, address(responsiveEvaluator), block.timestamp + 7 days, "response-training committee job"
            );

            vm.prank(client);
            commerce.setBudget(trainingJobId, BUDGET);

            vm.prank(client);
            commerce.fund(trainingJobId, BUDGET);

            vm.prank(provider);
            commerce.submit(trainingJobId, keccak256(abi.encodePacked("deliverable:response-training", i)));

            responsiveEvaluator.configureJob(
                trainingJobId,
                keccak256(abi.encodePacked("attestation:response-training-approved", i)),
                keccak256(abi.encodePacked("attestation:response-training-rejected", i)),
                2,
                2
            );

            vm.prank(validatorA);
            responsiveEvaluator.castVote(trainingJobId, CommitteeReviewEvaluator.VoteChoice.Approve);

            vm.prank(validatorB);
            responsiveEvaluator.castVote(trainingJobId, CommitteeReviewEvaluator.VoteChoice.Approve);

            vm.warp(block.timestamp + DISPUTE_WINDOW + 1);
            responsiveEvaluator.finalizeJobAccounting(trainingJobId);
        }

        assertEq(responsiveEvaluator.validatorAssignments(validatorD), 3);
        assertEq(responsiveEvaluator.validatorResponses(validatorD), 0);
        assertEq(responsiveEvaluator.validatorResponseScore(validatorD), 50);

        _approveAndStake(address(responsiveEvaluator), validatorC, MINIMUM_STAKE);

        vm.prank(client);
        uint256 jobId = commerce.createJob(
            provider, address(responsiveEvaluator), block.timestamp + 7 days, "response-weighted committee job"
        );

        vm.prank(client);
        commerce.setBudget(jobId, BUDGET);

        vm.prank(client);
        commerce.fund(jobId, BUDGET);

        vm.prank(provider);
        commerce.submit(jobId, keccak256("deliverable:response-weighted-committee"));

        bytes32 successAttestation = keccak256("attestation:response-weighted-approved");
        bytes32 failureAttestation = keccak256("attestation:response-weighted-rejected");

        vm.prevrandao(keccak256("response-weighted-selection-seed"));

        bytes32 selectionSeed = keccak256(
            abi.encode(block.prevrandao, block.timestamp, jobId, successAttestation, failureAttestation, uint256(2))
        );

        responsiveEvaluator.configureJob(jobId, successAttestation, failureAttestation, 2, 1);

        address[] memory committee = responsiveEvaluator.getCommittee(jobId);
        assertEq(committee.length, 2);

        address[] memory candidates = new address[](4);
        candidates[0] = validatorA;
        candidates[1] = validatorB;
        candidates[2] = validatorD;
        candidates[3] = validatorC;

        uint16[] memory adjustedWeights = new uint16[](4);
        adjustedWeights[0] = 10_000;
        adjustedWeights[1] = 10_000;
        adjustedWeights[2] = 5_000;
        adjustedWeights[3] = 10_000;

        address[] memory expectedCommittee = _expectedWeightedCommittee(candidates, adjustedWeights, selectionSeed, 2);
        assertEq(committee[0], expectedCommittee[0]);
        assertEq(committee[1], expectedCommittee[1]);
    }

    function testUnsetValidatorReputationDefaultsToMaximumScore() external {
        assertEq(committeeEvaluator.validatorReputation(validatorA), 100);
        assertEq(committeeEvaluator.validatorReputation(makeAddr("unsetValidator")), 100);

        committeeEvaluator.setValidatorReputation(validatorA, 40);
        assertEq(committeeEvaluator.validatorReputation(validatorA), 40);
    }

    function testSetValidatorReputationRejectsOutOfRangeScores() external {
        vm.expectRevert(abi.encodeWithSelector(CommitteeReviewEvaluator.InvalidReputation.selector, uint16(0)));
        committeeEvaluator.setValidatorReputation(validatorA, 0);

        vm.expectRevert(abi.encodeWithSelector(CommitteeReviewEvaluator.InvalidReputation.selector, uint16(101)));
        committeeEvaluator.setValidatorReputation(validatorA, 101);
    }

    function testConfiguredValidatorReputationActsAsBaselineForDerivedScore() external {
        committeeEvaluator.setValidatorReputation(validatorA, 40);
        assertEq(committeeEvaluator.validatorReputation(validatorA), 40);

        uint256 jobId = _createAndFundJob(7 days);
        bytes32 deliverable = keccak256("deliverable:baseline-reputation");
        bytes32 successAttestation = keccak256("attestation:baseline-reputation-approved");
        bytes32 failureAttestation = keccak256("attestation:baseline-reputation-rejected");

        vm.prank(provider);
        commerce.submit(jobId, deliverable);

        committeeEvaluator.configureJob(jobId, successAttestation, failureAttestation, 2, 2);

        vm.prank(validatorA);
        committeeEvaluator.castVote(jobId, CommitteeReviewEvaluator.VoteChoice.Approve);

        vm.prank(validatorB);
        committeeEvaluator.castVote(jobId, CommitteeReviewEvaluator.VoteChoice.Approve);

        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);
        committeeEvaluator.finalizeJobAccounting(jobId);

        _assertValidatorPerformance(validatorA, 1, 1, 0, 0);
        assertEq(committeeEvaluator.validatorReputation(validatorA), 52);
    }

    function testCommitteeRejectsLateVotesAfterDeadline() external {
        uint256 jobId = _createAndFundJob(7 days);
        bytes32 deliverable = keccak256("deliverable:late-vote");
        bytes32 successAttestation = keccak256("attestation:late-vote-approved");
        bytes32 failureAttestation = keccak256("attestation:late-vote-rejected");

        vm.prank(provider);
        commerce.submit(jobId, deliverable);

        uint256 configTimestamp = block.timestamp;
        committeeEvaluator.configureJob(jobId, successAttestation, failureAttestation, 2, 2);

        vm.prank(validatorA);
        committeeEvaluator.castVote(jobId, CommitteeReviewEvaluator.VoteChoice.Approve);

        uint256 expectedDeadline = configTimestamp + REVIEW_DEADLINE;
        vm.warp(expectedDeadline);

        vm.expectRevert(
            abi.encodeWithSelector(CommitteeReviewEvaluator.ReviewDeadlinePassed.selector, expectedDeadline)
        );
        vm.prank(validatorB);
        committeeEvaluator.castVote(jobId, CommitteeReviewEvaluator.VoteChoice.Approve);

        committeeEvaluator.finalizeDeadlockedJob(jobId);

        IPactCommerce.Job memory job = commerce.getJob(jobId);
        assertEq(uint8(job.status), uint8(IPactCommerce.Status.Rejected));
        assertEq(job.attestation, failureAttestation);
        _assertValidatorAccount(validatorB, MINIMUM_STAKE, 0, 0, 1, true);
    }

    function testSplitVoteDeadlockCanBeResolvedAfterDeadline() external {
        uint256 jobId = _createAndFundJob(7 days);
        bytes32 deliverable = keccak256("deliverable:split-vote");
        bytes32 successAttestation = keccak256("attestation:split-approved");
        bytes32 failureAttestation = keccak256("attestation:split-rejected");

        vm.prank(provider);
        commerce.submit(jobId, deliverable);

        uint256 configTimestamp = block.timestamp;
        committeeEvaluator.configureJob(jobId, successAttestation, failureAttestation, 2, 2);

        // 1 approve, 1 reject, 1 uncertain => deadlock
        vm.prank(validatorA);
        committeeEvaluator.castVote(jobId, CommitteeReviewEvaluator.VoteChoice.Approve);

        vm.prank(validatorB);
        committeeEvaluator.castVote(jobId, CommitteeReviewEvaluator.VoteChoice.Reject);

        vm.prank(validatorC);
        committeeEvaluator.castVote(jobId, CommitteeReviewEvaluator.VoteChoice.Uncertain);

        // Job should still be Submitted (no threshold reached)
        IPactCommerce.Job memory job = commerce.getJob(jobId);
        assertEq(uint8(job.status), uint8(IPactCommerce.Status.Submitted));

        // Cannot finalize before deadline
        uint256 expectedDeadline = configTimestamp + REVIEW_DEADLINE;
        vm.expectRevert(
            abi.encodeWithSelector(CommitteeReviewEvaluator.ReviewDeadlineNotReached.selector, expectedDeadline)
        );
        committeeEvaluator.finalizeDeadlockedJob(jobId);

        // Warp past deadline
        vm.warp(expectedDeadline + 1);
        committeeEvaluator.finalizeDeadlockedJob(jobId);

        // Job should be Rejected (deadlock default)
        job = commerce.getJob(jobId);
        assertEq(uint8(job.status), uint8(IPactCommerce.Status.Rejected));
        assertEq(job.attestation, failureAttestation);

        // Client refunded
        assertEq(usdc.balanceOf(client), INITIAL_BALANCE);

        // Validators can finalize accounting and unstake
        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);
        committeeEvaluator.finalizeJobAccounting(jobId);

        vm.prank(validatorA);
        committeeEvaluator.unstake(1);
    }

    function testAllUncertainVotesDeadlockResolvedByTimeout() external {
        uint256 jobId = _createAndFundJob(7 days);
        bytes32 deliverable = keccak256("deliverable:all-uncertain");
        bytes32 successAttestation = keccak256("attestation:all-uncertain-approved");
        bytes32 failureAttestation = keccak256("attestation:all-uncertain-rejected");

        vm.prank(provider);
        commerce.submit(jobId, deliverable);

        uint256 configTs = block.timestamp;
        committeeEvaluator.configureJob(jobId, successAttestation, failureAttestation, 2, 2);

        vm.prank(validatorA);
        committeeEvaluator.castVote(jobId, CommitteeReviewEvaluator.VoteChoice.Uncertain);

        vm.prank(validatorB);
        committeeEvaluator.castVote(jobId, CommitteeReviewEvaluator.VoteChoice.Uncertain);

        vm.prank(validatorC);
        committeeEvaluator.castVote(jobId, CommitteeReviewEvaluator.VoteChoice.Uncertain);

        vm.warp(configTs + REVIEW_DEADLINE + 1);
        committeeEvaluator.finalizeDeadlockedJob(jobId);

        IPactCommerce.Job memory job = commerce.getJob(jobId);
        assertEq(uint8(job.status), uint8(IPactCommerce.Status.Rejected));
    }

    function _approveAndStake(address validator, uint256 amount) internal {
        _approveAndStake(address(committeeEvaluator), validator, amount);
    }

    function _approveAndStake(address evaluator, address validator, uint256 amount) internal {
        vm.startPrank(validator);
        usdc.approve(evaluator, type(uint256).max);
        CommitteeReviewEvaluator(evaluator).stake(amount);
        vm.stopPrank();
    }

    function _expectedWeightedCommittee(
        address[] memory candidates,
        uint16[] memory reputations,
        bytes32 selectionSeed,
        uint256 committeeSize
    ) internal pure returns (address[] memory committee) {
        committee = new address[](committeeSize);

        for (uint256 i = 0; i < committeeSize; ++i) {
            uint256 remainingWeight;
            for (uint256 j = i; j < candidates.length; ++j) {
                remainingWeight += reputations[j];
            }

            uint256 targetWeight = uint256(keccak256(abi.encode(selectionSeed, i))) % remainingWeight;
            uint256 cumulativeWeight;
            uint256 selectedIndex = i;

            for (uint256 j = i; j < candidates.length; ++j) {
                cumulativeWeight += reputations[j];
                if (targetWeight < cumulativeWeight) {
                    selectedIndex = j;
                    break;
                }
            }

            (candidates[i], candidates[selectedIndex]) = (candidates[selectedIndex], candidates[i]);
            (reputations[i], reputations[selectedIndex]) = (reputations[selectedIndex], reputations[i]);
            committee[i] = candidates[i];
        }
    }

    function _containsAddress(address[] memory values, address candidate) internal pure returns (bool) {
        for (uint256 i = 0; i < values.length; ++i) {
            if (values[i] == candidate) {
                return true;
            }
        }

        return false;
    }

    function _assertValidatorAccount(
        address validator,
        uint256 expectedStake,
        uint256 expectedRewards,
        uint8 expectedDeviations,
        uint32 expectedPendingAccountings,
        bool expectedActive
    ) internal view {
        (uint256 stakeAmount, uint256 rewardAmount, uint8 deviationCount, uint32 pendingAccountings, bool active) =
            committeeEvaluator.validators(validator);
        assertEq(stakeAmount, expectedStake);
        assertEq(rewardAmount, expectedRewards);
        assertEq(deviationCount, expectedDeviations);
        assertEq(pendingAccountings, expectedPendingAccountings);
        assertEq(active, expectedActive);
    }

    function _assertValidatorPerformance(
        address validator,
        uint32 expectedResolvedVotes,
        uint32 expectedAlignedVotes,
        uint32 expectedDisputedVotes,
        uint32 expectedNoContestVotes
    ) internal view {
        (uint32 resolvedVotes, uint32 alignedVotes, uint32 disputedVotes, uint32 noContestVotes) =
            committeeEvaluator.validatorPerformances(validator);
        assertEq(resolvedVotes, expectedResolvedVotes);
        assertEq(alignedVotes, expectedAlignedVotes);
        assertEq(disputedVotes, expectedDisputedVotes);
        assertEq(noContestVotes, expectedNoContestVotes);
    }

    function _createAndFundJob(uint256 expiryOffset) internal returns (uint256 jobId) {
        vm.prank(client);
        jobId = commerce.createJob(
            provider, address(committeeEvaluator), block.timestamp + expiryOffset, "committee-reviewed ERC-8183 job"
        );

        vm.prank(client);
        commerce.setBudget(jobId, BUDGET);

        vm.prank(client);
        commerce.fund(jobId, BUDGET);
    }
}
