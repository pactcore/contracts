// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {HumanJury} from "../src/HumanJury.sol";
import {PactCommerce} from "../src/PactCommerce.sol";
import {CommitteeReviewEvaluator} from "../src/evaluators/CommitteeReviewEvaluator.sol";
import {IPactCommerce} from "../src/interfaces/IPactCommerce.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

contract HumanJuryTest is Test {
    MockUSDC private usdc;
    PactCommerce private commerce;
    CommitteeReviewEvaluator private committeeEvaluator;
    HumanJury private humanJury;

    address private client = makeAddr("client");
    address private provider = makeAddr("provider");
    address private evaluator = makeAddr("evaluator");
    address private treasury = makeAddr("treasury");
    address private challenger = makeAddr("challenger");
    address private validatorA = makeAddr("validatorA");
    address private validatorB = makeAddr("validatorB");
    address private validatorC = makeAddr("validatorC");
    address private jurorA = makeAddr("jurorA");
    address private jurorB = makeAddr("jurorB");
    address private jurorC = makeAddr("jurorC");
    address private jurorD = makeAddr("jurorD");
    address private jurorE = makeAddr("jurorE");
    address private lowReputationJuror = makeAddr("lowReputationJuror");

    uint256 private constant INITIAL_BALANCE = 20_000e6;
    uint256 private constant VALIDATOR_BANKROLL = 5_000e6;
    uint256 private constant CHALLENGER_BANKROLL = 1_000e6;
    uint256 private constant BUDGET = 1_000e6;
    uint256 private constant MINIMUM_STAKE = 500e6;
    uint256 private constant DISPUTE_WINDOW = 1 days;
    uint16 private constant PLATFORM_FEE_BPS = 500;
    uint16 private constant VALIDATOR_REWARD_BPS = 500;
    uint16 private constant SLASHING_BPS = 1_000;
    uint8 private constant SLASH_AFTER_DISAGREEMENTS = 3;
    uint16 private constant MINIMUM_JUROR_REPUTATION = 80;
    uint8 private constant JURY_PANEL_SIZE = 5;
    uint256 private constant REVIEW_DEADLINE_DURATION = 7 days;
    uint256 private constant COMMITTEE_REVIEW_DEADLINE = 3 days;

    function setUp() external {
        usdc = new MockUSDC();
        commerce = new PactCommerce(address(usdc), treasury, PLATFORM_FEE_BPS);
        committeeEvaluator = new CommitteeReviewEvaluator(
            address(commerce),
            address(usdc),
            MINIMUM_STAKE,
            DISPUTE_WINDOW,
            COMMITTEE_REVIEW_DEADLINE,
            SLASHING_BPS,
            SLASH_AFTER_DISAGREEMENTS,
            treasury
        );
        humanJury = new HumanJury(
            address(commerce), address(usdc), MINIMUM_JUROR_REPUTATION, JURY_PANEL_SIZE, REVIEW_DEADLINE_DURATION
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

        humanJury.configureJuror(jurorA, 95, true);
        humanJury.configureJuror(jurorB, 91, true);
        humanJury.configureJuror(jurorC, 90, true);
        humanJury.configureJuror(jurorD, 88, true);
        humanJury.configureJuror(jurorE, 86, true);
        humanJury.configureJuror(lowReputationJuror, 55, true);
    }

    function testHumanJuryOverturnsCommitteeDecisionAndFeedsBackIntoValidatorAccounting() external {
        uint256 jobId = _createAndFundCommitteeJob(7 days);
        bytes32 deliverable = keccak256("deliverable:committee-human-jury");
        bytes32 successAttestation = keccak256("attestation:committee-approved");
        bytes32 failureAttestation = keccak256("attestation:human-jury-rejected");
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

        vm.prank(challenger);
        uint256 disputeId = commerce.raiseDispute(
            jobId,
            keccak256("committee-decision"),
            keccak256("committee://human-jury"),
            keccak256("evidence://human-jury"),
            disputeBond
        );

        commerce.transferOwnership(address(humanJury));

        humanJury.createReview(
            disputeId, IPactCommerce.Status.Rejected, failureAttestation, keccak256("jury:dispute-rejected")
        );

        address[] memory panel = humanJury.getPanel(disputeId);
        assertEq(panel.length, JURY_PANEL_SIZE);
        assertFalse(_contains(panel, lowReputationJuror));

        vm.prank(panel[0]);
        humanJury.castVote(disputeId, HumanJury.VoteChoice.Uphold);

        vm.prank(panel[1]);
        humanJury.castVote(disputeId, HumanJury.VoteChoice.Uphold);

        vm.prank(panel[2]);
        humanJury.castVote(disputeId, HumanJury.VoteChoice.Uphold);

        IPactCommerce.Dispute memory dispute = commerce.getDispute(disputeId);
        assertEq(uint8(dispute.status), uint8(IPactCommerce.DisputeStatus.Upheld));
        assertEq(dispute.resolution, failureAttestation);

        IPactCommerce.Job memory job = commerce.getJob(jobId);
        assertEq(uint8(job.status), uint8(IPactCommerce.Status.Rejected));
        assertEq(job.attestation, failureAttestation);

        committeeEvaluator.finalizeJobAccounting(jobId);

        _assertValidatorAccount(validatorA, MINIMUM_STAKE, 0, 1, 0, true);
        _assertValidatorAccount(validatorB, MINIMUM_STAKE, 0, 1, 0, true);
        _assertValidatorAccount(validatorC, MINIMUM_STAKE, validatorReward, 0, 0, true);

        uint256 juryReward = commerce.disputeBondAmount() / 20;
        (,, uint256 firstJurorRewards, bool firstJurorActive) = humanJury.jurors(panel[0]);
        (,, uint256 secondJurorRewards, bool secondJurorActive) = humanJury.jurors(panel[1]);
        (,, uint256 thirdJurorRewards, bool thirdJurorActive) = humanJury.jurors(panel[2]);
        assertTrue(firstJurorActive && secondJurorActive && thirdJurorActive);
        assertEq(firstJurorRewards, (juryReward / 3) + (juryReward % 3));
        assertEq(secondJurorRewards, juryReward / 3);
        assertEq(thirdJurorRewards, juryReward / 3);

        uint256 jurorBalanceBefore = usdc.balanceOf(panel[0]);
        vm.prank(panel[0]);
        humanJury.claimRewards();
        assertEq(usdc.balanceOf(panel[0]), jurorBalanceBefore + firstJurorRewards);
    }

    function testHumanJuryRejectsDisputeAndKeepsLowReputationJurorOffPanel() external {
        uint256 jobId = _createAndFundDirectReviewJob(7 days);
        bytes32 deliverable = keccak256("deliverable:direct-human-jury");
        bytes32 completionAttestation = keccak256("attestation:completed");
        bytes32 rejectedResolution = keccak256("jury:reject-dispute");

        vm.prank(provider);
        commerce.submit(jobId, deliverable);

        vm.prank(evaluator);
        commerce.complete(jobId, completionAttestation);

        uint256 disputeBond = commerce.disputeBondAmount();

        vm.prank(challenger);
        uint256 disputeId = commerce.raiseDispute(
            jobId,
            keccak256("human-review"),
            keccak256("completion://1"),
            keccak256("evidence://jury-rejects-dispute"),
            disputeBond
        );

        commerce.transferOwnership(address(humanJury));

        humanJury.createReview(
            disputeId, IPactCommerce.Status.Rejected, keccak256("unused-upheld-resolution"), rejectedResolution
        );

        address[] memory panel = humanJury.getPanel(disputeId);
        assertEq(panel.length, JURY_PANEL_SIZE);
        assertFalse(_contains(panel, lowReputationJuror));

        vm.expectRevert(HumanJury.JurorNotSelected.selector);
        vm.prank(lowReputationJuror);
        humanJury.castVote(disputeId, HumanJury.VoteChoice.Reject);

        vm.prank(panel[0]);
        humanJury.castVote(disputeId, HumanJury.VoteChoice.Reject);

        vm.prank(panel[1]);
        humanJury.castVote(disputeId, HumanJury.VoteChoice.Reject);

        vm.prank(panel[2]);
        humanJury.castVote(disputeId, HumanJury.VoteChoice.Reject);

        IPactCommerce.Dispute memory dispute = commerce.getDispute(disputeId);
        assertEq(uint8(dispute.status), uint8(IPactCommerce.DisputeStatus.Rejected));
        assertEq(dispute.resolution, rejectedResolution);

        IPactCommerce.Job memory job = commerce.getJob(jobId);
        assertEq(uint8(job.status), uint8(IPactCommerce.Status.Completed));
        assertEq(job.attestation, completionAttestation);

        uint256 juryReward = commerce.disputeBondAmount() / 2;
        (,, uint256 firstJurorRewards,) = humanJury.jurors(panel[0]);
        (,, uint256 secondJurorRewards,) = humanJury.jurors(panel[1]);
        (,, uint256 thirdJurorRewards,) = humanJury.jurors(panel[2]);
        assertEq(firstJurorRewards, (juryReward / 3) + (juryReward % 3));
        assertEq(secondJurorRewards, juryReward / 3);
        assertEq(thirdJurorRewards, juryReward / 3);

        uint256 jurorBalanceBefore = usdc.balanceOf(panel[1]);
        vm.prank(panel[1]);
        humanJury.claimRewards();
        assertEq(usdc.balanceOf(panel[1]), jurorBalanceBefore + secondJurorRewards);
    }

    function testExpiredReviewResolvesDisputeAsRejectedAfterDeadline() external {
        uint256 jobId = _createAndFundDirectReviewJob(7 days);
        bytes32 deliverable = keccak256("deliverable:expired-review");
        bytes32 completionAttestation = keccak256("attestation:completed-expired-review");

        vm.prank(provider);
        commerce.submit(jobId, deliverable);

        vm.prank(evaluator);
        commerce.complete(jobId, completionAttestation);

        uint256 disputeBond = commerce.disputeBondAmount();

        vm.prank(challenger);
        uint256 disputeId = commerce.raiseDispute(
            jobId,
            keccak256("human-review"),
            keccak256("completion://expired-review"),
            keccak256("evidence://expired-review"),
            disputeBond
        );

        commerce.transferOwnership(address(humanJury));

        humanJury.createReview(
            disputeId,
            IPactCommerce.Status.Rejected,
            keccak256("upheld-resolution"),
            keccak256("rejected-resolution-expired")
        );

        address[] memory panel = humanJury.getPanel(disputeId);
        assertEq(panel.length, JURY_PANEL_SIZE);

        // Only 2 jurors vote (not enough for majority of 3)
        vm.prank(panel[0]);
        humanJury.castVote(disputeId, HumanJury.VoteChoice.Uphold);

        vm.prank(panel[1]);
        humanJury.castVote(disputeId, HumanJury.VoteChoice.Reject);

        // Cannot expire before deadline
        vm.expectRevert(HumanJury.ReviewDeadlineNotReached.selector);
        humanJury.expireReview(disputeId);

        // Warp past deadline
        vm.warp(block.timestamp + REVIEW_DEADLINE_DURATION + 1);
        humanJury.expireReview(disputeId);

        // Dispute should be rejected (upholding original decision)
        IPactCommerce.Dispute memory dispute = commerce.getDispute(disputeId);
        assertEq(uint8(dispute.status), uint8(IPactCommerce.DisputeStatus.Rejected));

        // Original job status preserved
        IPactCommerce.Job memory job = commerce.getJob(jobId);
        assertEq(uint8(job.status), uint8(IPactCommerce.Status.Completed));
        assertEq(job.attestation, completionAttestation);

        // Jurors can have pending panels released
        (, uint32 pendingPanelsA,,) = humanJury.jurors(panel[0]);
        assertEq(pendingPanelsA, 0);
    }

    function testCannotExpireAlreadyResolvedReview() external {
        uint256 jobId = _createAndFundDirectReviewJob(7 days);
        bytes32 deliverable = keccak256("deliverable:resolved-then-expire");
        bytes32 completionAttestation = keccak256("attestation:completed-resolved-then-expire");

        vm.prank(provider);
        commerce.submit(jobId, deliverable);

        vm.prank(evaluator);
        commerce.complete(jobId, completionAttestation);

        uint256 disputeBond = commerce.disputeBondAmount();

        vm.prank(challenger);
        uint256 disputeId = commerce.raiseDispute(
            jobId,
            keccak256("human-review"),
            keccak256("completion://resolved-then-expire"),
            keccak256("evidence://resolved-then-expire"),
            disputeBond
        );

        commerce.transferOwnership(address(humanJury));

        humanJury.createReview(disputeId, IPactCommerce.Status.Rejected, keccak256("upheld"), keccak256("rejected"));

        address[] memory panel = humanJury.getPanel(disputeId);

        // Reach majority (3 uphold votes)
        vm.prank(panel[0]);
        humanJury.castVote(disputeId, HumanJury.VoteChoice.Uphold);
        vm.prank(panel[1]);
        humanJury.castVote(disputeId, HumanJury.VoteChoice.Uphold);
        vm.prank(panel[2]);
        humanJury.castVote(disputeId, HumanJury.VoteChoice.Uphold);

        // Already resolved, cannot expire
        vm.warp(block.timestamp + REVIEW_DEADLINE_DURATION + 1);
        vm.expectRevert(HumanJury.ReviewAlreadyResolved.selector);
        humanJury.expireReview(disputeId);
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

    function _createAndFundCommitteeJob(uint256 expiryOffset) internal returns (uint256 jobId) {
        vm.prank(client);
        jobId = commerce.createJob(
            provider, address(committeeEvaluator), block.timestamp + expiryOffset, "committee bridge job"
        );

        vm.prank(client);
        commerce.setBudget(jobId, BUDGET);

        vm.prank(client);
        commerce.fund(jobId, BUDGET);
    }

    function _createAndFundDirectReviewJob(uint256 expiryOffset) internal returns (uint256 jobId) {
        vm.prank(client);
        jobId = commerce.createJob(provider, evaluator, block.timestamp + expiryOffset, "direct review job");

        vm.prank(client);
        commerce.setBudget(jobId, BUDGET);

        vm.prank(client);
        commerce.fund(jobId, BUDGET);
    }

    function _contains(address[] memory values, address target) internal pure returns (bool) {
        for (uint256 i = 0; i < values.length; ++i) {
            if (values[i] == target) {
                return true;
            }
        }
        return false;
    }
}
