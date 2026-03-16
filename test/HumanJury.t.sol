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
    address private jurorF = makeAddr("jurorF");
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

    function testCreateReviewRevertsWhenOnlyDisputeParticipantsCanFillPanel() external {
        uint256 jobId = _createAndFundDirectReviewJob(7 days);
        bytes32 deliverable = keccak256("deliverable:participant-jurors");
        bytes32 completionAttestation = keccak256("attestation:participant-jurors");

        vm.prank(provider);
        commerce.submit(jobId, deliverable);

        vm.prank(evaluator);
        commerce.complete(jobId, completionAttestation);

        uint256 disputeBond = commerce.disputeBondAmount();

        vm.prank(challenger);
        uint256 disputeId = commerce.raiseDispute(
            jobId,
            keccak256("human-review"),
            keccak256("completion://participant-jurors"),
            keccak256("evidence://participant-jurors"),
            disputeBond
        );

        humanJury.configureJuror(jurorD, 88, false);
        humanJury.configureJuror(jurorE, 86, false);
        humanJury.configureJuror(client, 99, true);
        humanJury.configureJuror(provider, 98, true);
        humanJury.configureJuror(evaluator, 97, true);
        humanJury.configureJuror(challenger, 96, true);

        vm.expectRevert(abi.encodeWithSelector(HumanJury.InsufficientEligibleJurors.selector, uint256(3), uint256(5)));
        humanJury.createReview(
            disputeId,
            IPactCommerce.Status.Rejected,
            keccak256("unused-upheld-resolution"),
            keccak256("unused-rejected-resolution")
        );
    }

    function testConfigureJurorRejectsOutOfRangeReputation() external {
        vm.expectRevert(abi.encodeWithSelector(HumanJury.InvalidReputation.selector, uint16(101)));
        humanJury.configureJuror(makeAddr("tooReputable"), 101, true);
    }

    function testConstructorRevertsWhenReviewDeadlineMismatchesCommerceDisputeWindow() external {
        uint256 commerceDisputeDeadline = commerce.disputeDeadlineDuration();

        vm.expectRevert(
            abi.encodeWithSelector(
                HumanJury.InvalidReviewDeadlineDuration.selector, commerceDisputeDeadline - 1, commerceDisputeDeadline
            )
        );
        new HumanJury(
            address(commerce), address(usdc), MINIMUM_JUROR_REPUTATION, JURY_PANEL_SIZE, commerceDisputeDeadline - 1
        );
    }

    function testCreateReviewRevertsWhenStartedAfterDisputeDeadline() external {
        uint256 jobId = _createAndFundDirectReviewJob(7 days);
        bytes32 deliverable = keccak256("deliverable:late-review-creation");
        bytes32 completionAttestation = keccak256("attestation:late-review-creation");
        bytes32 reviewResolution = keccak256("rejected-resolution-late-review-creation");

        vm.prank(provider);
        commerce.submit(jobId, deliverable);

        vm.prank(evaluator);
        commerce.complete(jobId, completionAttestation);

        uint256 disputeBond = commerce.disputeBondAmount();

        vm.prank(challenger);
        uint256 disputeId = commerce.raiseDispute(
            jobId,
            keccak256("human-review"),
            keccak256("completion://late-review-creation"),
            keccak256("evidence://late-review-creation"),
            disputeBond
        );

        commerce.transferOwnership(address(humanJury));

        uint256 reviewDeadline = block.timestamp + REVIEW_DEADLINE_DURATION;
        vm.warp(reviewDeadline);

        vm.expectRevert(abi.encodeWithSelector(HumanJury.ReviewDeadlinePassed.selector, reviewDeadline));
        humanJury.createReview(
            disputeId, IPactCommerce.Status.Rejected, keccak256("unused-upheld-resolution"), reviewResolution
        );
    }

    function testHumanJuryRejectsLateVotesAfterDeadline() external {
        uint256 jobId = _createAndFundDirectReviewJob(7 days);
        bytes32 deliverable = keccak256("deliverable:late-jury-vote");
        bytes32 completionAttestation = keccak256("attestation:completed-late-jury-vote");
        bytes32 rejectedResolution = keccak256("rejected-resolution-late-jury-vote");

        vm.prank(provider);
        commerce.submit(jobId, deliverable);

        vm.prank(evaluator);
        commerce.complete(jobId, completionAttestation);

        uint256 disputeBond = commerce.disputeBondAmount();

        vm.prank(challenger);
        uint256 disputeId = commerce.raiseDispute(
            jobId,
            keccak256("human-review"),
            keccak256("completion://late-jury-vote"),
            keccak256("evidence://late-jury-vote"),
            disputeBond
        );

        commerce.transferOwnership(address(humanJury));

        humanJury.createReview(
            disputeId, IPactCommerce.Status.Rejected, keccak256("upheld-resolution-late-jury-vote"), rejectedResolution
        );

        address[] memory panel = humanJury.getPanel(disputeId);
        uint256 deadline = block.timestamp + REVIEW_DEADLINE_DURATION;

        vm.prank(panel[0]);
        humanJury.castVote(disputeId, HumanJury.VoteChoice.Uphold);

        vm.prank(panel[1]);
        humanJury.castVote(disputeId, HumanJury.VoteChoice.Reject);

        vm.warp(deadline);

        vm.expectRevert(abi.encodeWithSelector(HumanJury.ReviewDeadlinePassed.selector, deadline));
        vm.prank(panel[2]);
        humanJury.castVote(disputeId, HumanJury.VoteChoice.Reject);

        humanJury.expireReview(disputeId);

        IPactCommerce.Dispute memory dispute = commerce.getDispute(disputeId);
        assertEq(uint8(dispute.status), uint8(IPactCommerce.DisputeStatus.Rejected));
        assertEq(dispute.resolution, rejectedResolution);

        IPactCommerce.Job memory job = commerce.getJob(jobId);
        assertEq(uint8(job.status), uint8(IPactCommerce.Status.Completed));
        assertEq(job.attestation, completionAttestation);
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
        uint256 challengerBalanceBefore = usdc.balanceOf(challenger);

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

        // Dispute should be rejected (upholding the original decision) without slashing the challenger.
        IPactCommerce.Dispute memory dispute = commerce.getDispute(disputeId);
        assertEq(uint8(dispute.status), uint8(IPactCommerce.DisputeStatus.Rejected));
        assertEq(dispute.resolution, keccak256("rejected-resolution-expired"));
        assertEq(usdc.balanceOf(challenger), challengerBalanceBefore);

        // Original job status preserved
        IPactCommerce.Job memory job = commerce.getJob(jobId);
        assertEq(uint8(job.status), uint8(IPactCommerce.Status.Completed));
        assertEq(job.attestation, completionAttestation);

        // Expired reviews do not pay jurors and release the panel lock.
        (,, uint256 panelZeroRewards,) = humanJury.jurors(panel[0]);
        (, uint32 pendingPanelsA,,) = humanJury.jurors(panel[0]);
        assertEq(panelZeroRewards, 0);
        assertEq(pendingPanelsA, 0);
    }

    function testExpiredReviewTracksNoContestPerformanceForResponsiveJurors() external {
        uint256 jobId = _createAndFundDirectReviewJob(7 days);
        bytes32 deliverable = keccak256("deliverable:no-contest-performance");
        bytes32 completionAttestation = keccak256("attestation:no-contest-performance");
        bytes32 rejectedResolution = keccak256("rejected-resolution-no-contest-performance");

        vm.prank(provider);
        commerce.submit(jobId, deliverable);

        vm.prank(evaluator);
        commerce.complete(jobId, completionAttestation);

        uint256 disputeBond = commerce.disputeBondAmount();
        bytes32 evidenceHash = keccak256("evidence://no-contest-performance");

        vm.prank(challenger);
        uint256 disputeId = commerce.raiseDispute(
            jobId,
            keccak256("human-review"),
            keccak256("completion://no-contest-performance"),
            evidenceHash,
            disputeBond
        );

        commerce.transferOwnership(address(humanJury));

        humanJury.createReview(
            disputeId, IPactCommerce.Status.Rejected, keccak256("unused-upheld-resolution"), rejectedResolution
        );

        address[] memory panel = humanJury.getPanel(disputeId);

        vm.prank(panel[0]);
        humanJury.castVote(disputeId, HumanJury.VoteChoice.Uphold);

        vm.prank(panel[1]);
        humanJury.castVote(disputeId, HumanJury.VoteChoice.Reject);

        vm.warp(block.timestamp + REVIEW_DEADLINE_DURATION + 1);
        humanJury.expireReview(disputeId);

        assertEq(humanJury.jurorAssignments(panel[0]), 1);
        assertEq(humanJury.jurorResponses(panel[0]), 1);
        assertEq(humanJury.jurorResponseScore(panel[0]), 100);

        (uint32 resolvedReviewsA, uint32 alignedReviewsA, uint32 expiredReviewsA) =
            humanJury.jurorPerformances(panel[0]);
        assertEq(resolvedReviewsA, 0);
        assertEq(alignedReviewsA, 0);
        assertEq(expiredReviewsA, 1);

        assertEq(humanJury.jurorAssignments(panel[2]), 1);
        assertEq(humanJury.jurorResponses(panel[2]), 0);
        assertEq(humanJury.jurorResponseScore(panel[2]), 75);

        (uint32 resolvedReviewsC, uint32 alignedReviewsC, uint32 expiredReviewsC) =
            humanJury.jurorPerformances(panel[2]);
        assertEq(resolvedReviewsC, 0);
        assertEq(alignedReviewsC, 0);
        assertEq(expiredReviewsC, 0);
    }

    function testJurorPerformanceFeedsWeightedPanelSelection() external {
        _trainJurorPerformanceForWeightedSelection();

        humanJury.configureJuror(jurorF, 84, true);

        _assertWeightedPanelSelectionAfterPerformanceTraining();
    }

    function testPendingPanelLoadFeedsConcurrentWeightedSelection() external {
        uint256 firstJobId = _createAndFundDirectReviewJob(7 days);
        bytes32 firstDeliverable = keccak256("deliverable:pending-load-first");
        bytes32 firstCompletionAttestation = keccak256("attestation:pending-load-first");
        bytes32 firstEvidenceHash = keccak256("evidence://pending-load-first");
        uint256 baselineJurorAWeight = humanJury.jurorSelectionWeight(jurorA);

        vm.prank(provider);
        commerce.submit(firstJobId, firstDeliverable);

        vm.prank(evaluator);
        commerce.complete(firstJobId, firstCompletionAttestation);

        uint256 disputeBond = commerce.disputeBondAmount();

        vm.prank(challenger);
        uint256 firstDisputeId = commerce.raiseDispute(
            firstJobId,
            keccak256("human-review"),
            keccak256("completion://pending-load-first"),
            firstEvidenceHash,
            disputeBond
        );

        commerce.transferOwnership(address(humanJury));

        humanJury.createReview(
            firstDisputeId,
            IPactCommerce.Status.Rejected,
            keccak256("unused-upheld-resolution"),
            keccak256("rejected-resolution-pending-load-first")
        );

        assertEq(humanJury.jurorAssignments(jurorA), 1);
        assertEq(humanJury.jurorResponses(jurorA), 0);
        assertEq(humanJury.jurorResponseScore(jurorA), 75);
        assertEq(humanJury.jurorLoadScore(jurorA), 50);
        assertLt(humanJury.jurorSelectionWeight(jurorA), baselineJurorAWeight);

        humanJury.configureJuror(jurorF, 84, true);

        uint256 secondJobId = _createAndFundDirectReviewJob(7 days);
        bytes32 secondEvidenceHash = keccak256("evidence://pending-load-second");

        vm.prank(provider);
        commerce.submit(secondJobId, keccak256("deliverable:pending-load-second"));

        vm.prank(evaluator);
        commerce.complete(secondJobId, keccak256("attestation:pending-load-second"));

        vm.prank(challenger);
        uint256 secondDisputeId = commerce.raiseDispute(
            secondJobId,
            keccak256("human-review"),
            keccak256("completion://pending-load-second"),
            secondEvidenceHash,
            disputeBond
        );

        uint256 createTimestamp = block.timestamp;
        address[] memory candidates = _eligibleJurorCandidatesWithJurorF();
        bytes32 selectedRandao;
        address[] memory expectedLoadAwarePanel;
        address[] memory expectedPanelIgnoringLoad;
        bool foundDifferingSeed;

        for (uint256 i = 1; i <= 512; ++i) {
            selectedRandao = bytes32(i);
            vm.prevrandao(selectedRandao);
            expectedLoadAwarePanel =
                _expectedWeightedPanel(secondDisputeId, secondJobId, secondEvidenceHash, createTimestamp, candidates);
            expectedPanelIgnoringLoad = _expectedPanelIgnoringPendingLoad(
                secondDisputeId, secondJobId, secondEvidenceHash, createTimestamp, candidates
            );

            if (_panelsDiffer(expectedLoadAwarePanel, expectedPanelIgnoringLoad)) {
                foundDifferingSeed = true;
                break;
            }
        }

        assertTrue(foundDifferingSeed);

        vm.prevrandao(selectedRandao);
        humanJury.createReview(
            secondDisputeId,
            IPactCommerce.Status.Rejected,
            keccak256("unused-upheld-resolution"),
            keccak256("rejected-resolution-pending-load-second")
        );

        address[] memory secondPanel = humanJury.getPanel(secondDisputeId);
        _assertSamePanel(secondPanel, expectedLoadAwarePanel);
        assertTrue(_panelsDiffer(secondPanel, expectedPanelIgnoringLoad));
        assertTrue(_contains(secondPanel, jurorF));
    }

    function testJurySelectionSnapshotsFreezeDrawMetrics() external {
        uint256 jobId = _createAndFundDirectReviewJob(7 days);
        uint256 disputeBond = commerce.disputeBondAmount();

        vm.prank(provider);
        commerce.submit(jobId, keccak256("deliverable:jury-selection-snapshot"));

        vm.prank(evaluator);
        commerce.complete(jobId, keccak256("attestation:jury-selection-snapshot"));

        vm.prank(challenger);
        uint256 disputeId = commerce.raiseDispute(
            jobId,
            keccak256("human-review"),
            keccak256("completion://jury-selection-snapshot"),
            keccak256("evidence://jury-selection-snapshot"),
            disputeBond
        );

        commerce.transferOwnership(address(humanJury));

        humanJury.createReview(
            disputeId,
            IPactCommerce.Status.Rejected,
            keccak256("unused-upheld-resolution"),
            keccak256("rejected-resolution-jury-selection-snapshot")
        );

        address selectedJuror = humanJury.getPanel(disputeId)[0];
        uint16 selectedJurorReputation = humanJury.jurorReputation(selectedJuror);

        {
            (uint16 reputation, uint16 responseScore, uint16 loadScore, uint256 weight, uint32 pendingPanels) =
                humanJury.getSelectionSnapshot(disputeId, selectedJuror);

            assertEq(reputation, selectedJurorReputation);
            assertEq(responseScore, 100);
            assertEq(loadScore, 100);
            assertEq(weight, uint256(reputation) * 10_000);
            assertEq(pendingPanels, 0);
        }

        assertEq(humanJury.jurorAssignments(selectedJuror), 1);
        assertEq(humanJury.jurorResponseScore(selectedJuror), 75);
        assertEq(humanJury.jurorLoadScore(selectedJuror), 50);

        {
            (
                ,
                uint16 responseScoreAfterSelection,
                uint16 loadScoreAfterSelection,
                uint256 weightAfterSelection,
                uint32 pendingPanelsAfterSelection
            ) = humanJury.getSelectionSnapshot(disputeId, selectedJuror);

            assertEq(responseScoreAfterSelection, 100);
            assertEq(loadScoreAfterSelection, 100);
            assertEq(weightAfterSelection, uint256(selectedJurorReputation) * 10_000);
            assertEq(pendingPanelsAfterSelection, 0);
        }
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

    function _trainJurorPerformanceForWeightedSelection() internal {
        uint256 firstJobId = _createAndFundDirectReviewJob(7 days);

        vm.prank(provider);
        commerce.submit(firstJobId, keccak256("deliverable:weighted-jury-first"));

        vm.prank(evaluator);
        commerce.complete(firstJobId, keccak256("attestation:weighted-jury-first"));

        uint256 disputeBond = commerce.disputeBondAmount();

        vm.prank(challenger);
        uint256 firstDisputeId = commerce.raiseDispute(
            firstJobId,
            keccak256("human-review"),
            keccak256("completion://weighted-jury-first"),
            keccak256("evidence://weighted-jury-first"),
            disputeBond
        );

        commerce.transferOwnership(address(humanJury));

        humanJury.createReview(
            firstDisputeId,
            IPactCommerce.Status.Rejected,
            keccak256("unused-upheld-resolution"),
            keccak256("rejected-resolution-weighted-jury-first")
        );

        address[] memory firstPanel = humanJury.getPanel(firstDisputeId);
        assertEq(firstPanel.length, JURY_PANEL_SIZE);

        vm.prank(firstPanel[0]);
        humanJury.castVote(firstDisputeId, HumanJury.VoteChoice.Reject);

        vm.prank(firstPanel[1]);
        humanJury.castVote(firstDisputeId, HumanJury.VoteChoice.Reject);

        vm.prank(firstPanel[2]);
        humanJury.castVote(firstDisputeId, HumanJury.VoteChoice.Reject);

        assertEq(humanJury.jurorAssignments(firstPanel[0]), 1);
        assertEq(humanJury.jurorResponses(firstPanel[0]), 1);
        assertEq(humanJury.jurorResponseScore(firstPanel[0]), 100);

        (uint32 resolvedReviewsA, uint32 alignedReviewsA, uint32 expiredReviewsA) =
            humanJury.jurorPerformances(firstPanel[0]);
        assertEq(resolvedReviewsA, 1);
        assertEq(alignedReviewsA, 1);
        assertEq(expiredReviewsA, 0);

        assertEq(humanJury.jurorAssignments(firstPanel[4]), 1);
        assertEq(humanJury.jurorResponses(firstPanel[4]), 0);
        assertEq(humanJury.jurorResponseScore(firstPanel[4]), 75);
        assertGt(humanJury.jurorSelectionWeight(firstPanel[0]), humanJury.jurorSelectionWeight(firstPanel[4]));
    }

    function _assertWeightedPanelSelectionAfterPerformanceTraining() internal {
        uint256 secondJobId = _createAndFundDirectReviewJob(7 days);
        bytes32 secondEvidenceHash = keccak256("evidence://weighted-jury-second");

        vm.prank(provider);
        commerce.submit(secondJobId, keccak256("deliverable:weighted-jury-second"));

        vm.prank(evaluator);
        commerce.complete(secondJobId, keccak256("attestation:weighted-jury-second"));

        uint256 disputeBond = commerce.disputeBondAmount();

        vm.prank(challenger);
        uint256 secondDisputeId = commerce.raiseDispute(
            secondJobId,
            keccak256("human-review"),
            keccak256("completion://weighted-jury-second"),
            secondEvidenceHash,
            disputeBond
        );

        vm.prevrandao(bytes32(uint256(0xBEEF)));
        uint256 createTimestamp = block.timestamp;
        address[] memory expectedPanel = _expectedWeightedPanel(
            secondDisputeId, secondJobId, secondEvidenceHash, createTimestamp, _eligibleJurorCandidatesWithJurorF()
        );

        humanJury.createReview(
            secondDisputeId,
            IPactCommerce.Status.Rejected,
            keccak256("unused-upheld-resolution"),
            keccak256("rejected-resolution-weighted-jury-second")
        );

        address[] memory secondPanel = humanJury.getPanel(secondDisputeId);
        _assertSamePanel(secondPanel, expectedPanel);
        assertFalse(_contains(secondPanel, lowReputationJuror));
    }

    function _eligibleJurorCandidatesWithJurorF() internal view returns (address[] memory candidates) {
        candidates = new address[](6);
        candidates[0] = jurorA;
        candidates[1] = jurorB;
        candidates[2] = jurorC;
        candidates[3] = jurorD;
        candidates[4] = jurorE;
        candidates[5] = jurorF;
    }

    function _expectedWeightedPanel(
        uint256 disputeId,
        uint256 jobId,
        bytes32 evidenceHash,
        uint256 createTimestamp,
        address[] memory candidates
    ) internal view returns (address[] memory panel) {
        panel = new address[](JURY_PANEL_SIZE);
        bytes32 selectionSeed =
            keccak256(abi.encode(block.prevrandao, createTimestamp, disputeId, jobId, evidenceHash, JURY_PANEL_SIZE));

        for (uint256 i = 0; i < JURY_PANEL_SIZE; ++i) {
            uint256 remainingWeight;
            for (uint256 j = i; j < candidates.length; ++j) {
                remainingWeight += humanJury.jurorSelectionWeight(candidates[j]);
            }

            uint256 targetWeight = uint256(keccak256(abi.encode(selectionSeed, i))) % remainingWeight;
            uint256 cumulativeWeight;
            uint256 selectedIndex = i;

            for (uint256 j = i; j < candidates.length; ++j) {
                cumulativeWeight += humanJury.jurorSelectionWeight(candidates[j]);
                if (targetWeight < cumulativeWeight) {
                    selectedIndex = j;
                    break;
                }
            }

            (candidates[i], candidates[selectedIndex]) = (candidates[selectedIndex], candidates[i]);
            panel[i] = candidates[i];
        }
    }

    function _expectedPanelIgnoringPendingLoad(
        uint256 disputeId,
        uint256 jobId,
        bytes32 evidenceHash,
        uint256 createTimestamp,
        address[] memory candidates
    ) internal view returns (address[] memory panel) {
        panel = new address[](JURY_PANEL_SIZE);
        bytes32 selectionSeed =
            keccak256(abi.encode(block.prevrandao, createTimestamp, disputeId, jobId, evidenceHash, JURY_PANEL_SIZE));

        for (uint256 i = 0; i < JURY_PANEL_SIZE; ++i) {
            uint256 remainingWeight;
            for (uint256 j = i; j < candidates.length; ++j) {
                remainingWeight += _selectionWeightIgnoringPendingLoad(candidates[j]);
            }

            uint256 targetWeight = uint256(keccak256(abi.encode(selectionSeed, i))) % remainingWeight;
            uint256 cumulativeWeight;
            uint256 selectedIndex = i;

            for (uint256 j = i; j < candidates.length; ++j) {
                cumulativeWeight += _selectionWeightIgnoringPendingLoad(candidates[j]);
                if (targetWeight < cumulativeWeight) {
                    selectedIndex = j;
                    break;
                }
            }

            (candidates[i], candidates[selectedIndex]) = (candidates[selectedIndex], candidates[i]);
            panel[i] = candidates[i];
        }
    }

    function _selectionWeightIgnoringPendingLoad(address juror) internal view returns (uint256) {
        uint256 reputationScore = humanJury.jurorReputation(juror);
        if (reputationScore == 0) {
            reputationScore = 1;
        }
        return reputationScore * uint256(humanJury.jurorResponseScore(juror));
    }

    function _assertSamePanel(address[] memory actual, address[] memory expected) internal pure {
        assertEq(actual.length, expected.length);
        for (uint256 i = 0; i < actual.length; ++i) {
            assertEq(actual[i], expected[i]);
        }
    }

    function _panelsDiffer(address[] memory lhs, address[] memory rhs) internal pure returns (bool) {
        if (lhs.length != rhs.length) {
            return true;
        }

        for (uint256 i = 0; i < lhs.length; ++i) {
            if (lhs[i] != rhs[i]) {
                return true;
            }
        }

        return false;
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
