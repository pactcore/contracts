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

    uint256 private constant INITIAL_BALANCE = 20_000e6;
    uint256 private constant VALIDATOR_BANKROLL = 5_000e6;
    uint256 private constant CHALLENGER_BANKROLL = 1_000e6;
    uint256 private constant BUDGET = 1_000e6;
    uint256 private constant MINIMUM_STAKE = 300e6;
    uint256 private constant DISPUTE_WINDOW = 1 days;
    uint16 private constant PLATFORM_FEE_BPS = 500;
    uint16 private constant VALIDATOR_REWARD_BPS = 500;
    uint16 private constant ISSUER_REBATE_BPS = 500;
    uint16 private constant SLASHING_BPS = 1_000;
    uint8 private constant SLASH_AFTER_DISAGREEMENTS = 3;

    function setUp() external {
        usdc = new MockUSDC();
        commerce = new PactCommerce(address(usdc), treasury, PLATFORM_FEE_BPS);
        committeeEvaluator = new CommitteeReviewEvaluator(
            address(commerce),
            address(usdc),
            MINIMUM_STAKE,
            DISPUTE_WINDOW,
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

        uint256 treasuryFees = ((BUDGET * PLATFORM_FEE_BPS) / 10_000) * 3;
        assertEq(usdc.balanceOf(treasury), treasuryBefore + treasuryFees + slashAmount);

        _assertValidatorAccount(validatorC, MINIMUM_STAKE - slashAmount, 0, 0, 0, false);
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

        vm.prank(challenger);
        uint256 disputeId = commerce.raiseDispute(
            jobId, disputeSubjectType, disputeSubjectRef, disputeEvidence, commerce.disputeBondAmount()
        );

        vm.expectRevert(abi.encodeWithSelector(CommitteeReviewEvaluator.JobAccountingNotReady.selector));
        committeeEvaluator.finalizeJobAccounting(jobId);

        commerce.resolveDispute(disputeId, true, failureAttestation);
        committeeEvaluator.finalizeJobAccounting(jobId);

        IPactCommerce.Dispute memory dispute = commerce.getDispute(disputeId);
        assertEq(uint8(dispute.status), uint8(IPactCommerce.DisputeStatus.Upheld));
        assertEq(dispute.resolution, failureAttestation);

        _assertValidatorAccount(validatorA, MINIMUM_STAKE, 0, 1, 0, true);
        _assertValidatorAccount(validatorB, MINIMUM_STAKE, 0, 1, 0, true);
        _assertValidatorAccount(validatorC, MINIMUM_STAKE, validatorReward, 0, 0, true);

        uint256 validatorCBalanceBefore = usdc.balanceOf(validatorC);
        vm.prank(validatorC);
        committeeEvaluator.claimRewards();
        assertEq(usdc.balanceOf(validatorC), validatorCBalanceBefore + validatorReward);
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

    function _approveAndStake(address validator, uint256 amount) internal {
        vm.startPrank(validator);
        usdc.approve(address(committeeEvaluator), type(uint256).max);
        committeeEvaluator.stake(amount);
        vm.stopPrank();
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
