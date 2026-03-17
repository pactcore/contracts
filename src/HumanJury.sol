// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

import {IPactCommerce} from "./interfaces/IPactCommerce.sol";

contract HumanJury is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum VoteChoice {
        None,
        Uphold,
        Reject
    }

    struct JurorAccount {
        uint16 reputation;
        uint32 pendingPanels;
        uint256 accruedRewards;
        bool active;
    }

    struct JurorPerformance {
        uint32 resolvedReviews;
        uint32 alignedReviews;
        uint32 expiredReviews;
    }

    struct ReviewConfig {
        IPactCommerce.Status proposedFinalStatus;
        bytes32 upheldResolution;
        bytes32 rejectedResolution;
        uint64 createdAt;
        uint64 deadlineAt;
        uint64 resolvedAt;
        uint8 majorityThreshold;
        bool resolved;
        bool upheld;
    }

    struct ReviewTally {
        uint8 upholdCount;
        uint8 rejectCount;
    }

    struct SelectionSnapshot {
        uint16 reputation;
        uint16 responseScore;
        uint16 loadScore;
        uint256 weight;
        uint32 pendingPanels;
    }

    IPactCommerce public immutable commerce;
    IERC20 public immutable settlementToken;
    uint16 public constant MAX_JUROR_REPUTATION = 100;
    uint256 private constant REPUTATION_PRIOR_WEIGHT = 4;
    uint256 private constant RESPONSE_PRIOR_WEIGHT = 3;

    uint16 public immutable minimumJurorReputation;
    uint8 public immutable panelSize;
    uint256 public immutable reviewDeadlineDuration;
    uint256 public immutable commerceDisputeDeadline;

    mapping(address juror => JurorAccount) public jurors;
    mapping(address juror => JurorPerformance performance) public jurorPerformances;
    mapping(address juror => uint32 assignments) public jurorAssignments;
    mapping(address juror => uint32 responses) public jurorResponses;
    mapping(uint256 disputeId => ReviewConfig) public reviews;
    mapping(uint256 disputeId => ReviewTally) public tallies;
    mapping(uint256 disputeId => mapping(address juror => VoteChoice choice)) public votes;

    address[] private jurorRegistry;
    mapping(address juror => bool knownJuror) private isKnownJuror;
    mapping(uint256 disputeId => address[]) private reviewPanels;
    mapping(uint256 disputeId => mapping(address juror => bool selected)) private isSelectedJuror;
    mapping(uint256 disputeId => mapping(address juror => SelectionSnapshot snapshot)) private reviewSelectionSnapshots;

    event JurorConfigured(address indexed juror, uint16 reputation, bool active, uint32 pendingPanels);
    event JurorPerformanceUpdated(
        uint256 indexed disputeId,
        address indexed juror,
        VoteChoice indexed jurorChoice,
        VoteChoice finalOutcome,
        uint16 reputation,
        uint32 resolvedReviews,
        uint32 alignedReviews,
        uint32 expiredReviews
    );
    event VoteCast(
        uint256 indexed disputeId,
        address indexed juror,
        VoteChoice indexed choice,
        uint8 upholdCount,
        uint8 rejectCount
    );
    event ReviewCreated(
        uint256 indexed disputeId,
        uint256 indexed jobId,
        IPactCommerce.Status proposedFinalStatus,
        bytes32 upheldResolution,
        bytes32 rejectedResolution,
        uint64 deadlineAt,
        uint8 panelSize,
        uint8 majorityThreshold
    );
    event JurorSelected(
        uint256 indexed disputeId,
        address indexed juror,
        uint16 reputation,
        uint16 responseScore,
        uint16 loadScore,
        uint256 weight,
        uint32 pendingPanels
    );
    event ReviewResolved(
        uint256 indexed disputeId,
        bool indexed upheld,
        IPactCommerce.Status finalStatus,
        bytes32 resolution,
        uint256 rewardAmount,
        uint256 alignedJurorCount
    );
    event RewardsClaimed(address indexed juror, uint256 amount);
    event ReviewExpired(uint256 indexed disputeId, uint64 deadline, uint8 upholdCount, uint8 rejectCount);

    error ZeroAddress();
    error InvalidConfig();
    error ReviewAlreadyExists();
    error ReviewNotFound();
    error ReviewNotOpen();
    error ReviewAlreadyResolved();
    error InvalidReputation(uint16 reputation);
    error InvalidReviewDeadlineDuration(uint256 reviewDeadlineDuration, uint256 disputeDeadlineDuration);
    error InvalidVote();
    error JurorNotSelected();
    error AlreadyVoted();
    error InvalidAmount();
    error InsufficientEligibleJurors(uint256 eligible, uint256 required);
    error ReviewDeadlineNotReached();
    error ReviewDeadlinePassed(uint256 deadline);

    constructor(
        address commerceAddress,
        address settlementTokenAddress,
        uint16 minimumJurorReputationValue,
        uint8 panelSizeValue,
        uint256 reviewDeadlineDurationSeconds
    ) Ownable(msg.sender) {
        if (commerceAddress == address(0) || settlementTokenAddress == address(0)) {
            revert ZeroAddress();
        }
        if (panelSizeValue < 5 || panelSizeValue > 11 || panelSizeValue % 2 == 0) revert InvalidConfig();
        if (minimumJurorReputationValue > MAX_JUROR_REPUTATION || reviewDeadlineDurationSeconds == 0) {
            revert InvalidConfig();
        }

        commerce = IPactCommerce(commerceAddress);
        settlementToken = IERC20(settlementTokenAddress);
        minimumJurorReputation = minimumJurorReputationValue;
        panelSize = panelSizeValue;
        reviewDeadlineDuration = reviewDeadlineDurationSeconds;
        commerceDisputeDeadline = commerce.disputeDeadlineDuration();

        if (reviewDeadlineDurationSeconds != commerceDisputeDeadline) {
            revert InvalidReviewDeadlineDuration(reviewDeadlineDurationSeconds, commerceDisputeDeadline);
        }
    }

    function configureJuror(address juror, uint16 reputation, bool active) external onlyOwner {
        if (juror == address(0)) revert ZeroAddress();
        if (reputation > MAX_JUROR_REPUTATION) revert InvalidReputation(reputation);

        if (!isKnownJuror[juror]) {
            isKnownJuror[juror] = true;
            jurorRegistry.push(juror);
        }

        JurorAccount storage account = jurors[juror];
        account.reputation = reputation;
        account.active = active;

        emit JurorConfigured(juror, reputation, active, account.pendingPanels);
    }

    function jurorReputation(address juror) public view returns (uint16) {
        uint16 baseline = jurors[juror].reputation;
        JurorPerformance storage performance = jurorPerformances[juror];
        if (performance.resolvedReviews == 0) {
            return baseline;
        }

        uint256 derivedReputation =
            (uint256(baseline) * REPUTATION_PRIOR_WEIGHT + uint256(MAX_JUROR_REPUTATION) * performance.alignedReviews)
                / (REPUTATION_PRIOR_WEIGHT + performance.resolvedReviews);
        if (derivedReputation == 0) {
            return 1;
        }

        // forge-lint: disable-next-line(unsafe-typecast)
        return uint16(derivedReputation);
    }

    function jurorResponseScore(address juror) public view returns (uint16) {
        uint256 assignments = jurorAssignments[juror];
        if (assignments == 0) {
            return MAX_JUROR_REPUTATION;
        }

        uint256 derivedResponseScore =
            (uint256(MAX_JUROR_REPUTATION) * (uint256(jurorResponses[juror]) + RESPONSE_PRIOR_WEIGHT))
                / (assignments + RESPONSE_PRIOR_WEIGHT);
        if (derivedResponseScore == 0) {
            return 1;
        }

        // forge-lint: disable-next-line(unsafe-typecast)
        return uint16(derivedResponseScore);
    }

    function jurorLoadScore(address juror) public view returns (uint16) {
        uint256 pendingPanels = jurors[juror].pendingPanels;
        if (pendingPanels == 0) {
            return MAX_JUROR_REPUTATION;
        }

        uint256 derivedLoadScore = uint256(MAX_JUROR_REPUTATION) / (pendingPanels + 1);
        if (derivedLoadScore == 0) {
            return 1;
        }

        // forge-lint: disable-next-line(unsafe-typecast)
        return uint16(derivedLoadScore);
    }

    function jurorSelectionWeight(address juror) public view returns (uint256) {
        return _selectionSnapshot(juror).weight;
    }

    function _selectionSnapshot(address juror) internal view returns (SelectionSnapshot memory snapshot) {
        snapshot.reputation = jurorReputation(juror);
        if (snapshot.reputation == 0) {
            snapshot.reputation = 1;
        }
        snapshot.responseScore = jurorResponseScore(juror);
        snapshot.loadScore = jurorLoadScore(juror);
        snapshot.weight = uint256(snapshot.reputation) * uint256(snapshot.responseScore) * uint256(snapshot.loadScore);
        snapshot.pendingPanels = jurors[juror].pendingPanels;
    }

    /// @notice Create a jury review panel for an open dispute.
    /// @dev Trust assumption: The owner/operator is trusted for jury selection timing in v1.
    /// Juror selection uses block.prevrandao as entropy, which means the review creator
    /// (owner) could theoretically wait for a favorable block before calling this function.
    /// This is acceptable because owner == governance in the current trust model.
    /// Future versions should use commit/reveal or VRF-based randomness for stronger guarantees.
    function createReview(
        uint256 disputeId,
        IPactCommerce.Status proposedFinalStatus,
        bytes32 upheldResolution,
        bytes32 rejectedResolution
    ) external onlyOwner returns (address[] memory selectedJurors) {
        if (
            proposedFinalStatus != IPactCommerce.Status.Completed
                && proposedFinalStatus != IPactCommerce.Status.Rejected
                && proposedFinalStatus != IPactCommerce.Status.Expired
        ) {
            revert InvalidConfig();
        }

        ReviewConfig storage review = reviews[disputeId];
        if (review.createdAt != 0) revert ReviewAlreadyExists();

        IPactCommerce.Dispute memory dispute = commerce.getDispute(disputeId);
        if (dispute.status != IPactCommerce.DisputeStatus.Open) revert ReviewNotOpen();

        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 deadlineAt = uint64(uint256(dispute.openedAt) + reviewDeadlineDuration);
        if (block.timestamp >= deadlineAt) revert ReviewDeadlinePassed(deadlineAt);

        IPactCommerce.Job memory job = commerce.getJob(dispute.jobId);
        selectedJurors = _selectJurors(disputeId, dispute.jobId, dispute.evidenceHash, job, dispute.challenger);
        uint8 majorityThreshold = uint8(panelSize / 2) + 1;

        review.proposedFinalStatus = proposedFinalStatus;
        review.upheldResolution = upheldResolution;
        review.rejectedResolution = rejectedResolution;
        review.createdAt = uint64(block.timestamp);
        review.deadlineAt = deadlineAt;
        review.majorityThreshold = majorityThreshold;

        for (uint256 i = 0; i < selectedJurors.length; ++i) {
            address juror = selectedJurors[i];
            reviewPanels[disputeId].push(juror);
            isSelectedJuror[disputeId][juror] = true;

            SelectionSnapshot memory snapshot = _selectionSnapshot(juror);
            reviewSelectionSnapshots[disputeId][juror] = snapshot;

            jurors[juror].pendingPanels += 1;
            jurorAssignments[juror] += 1;

            emit JurorSelected(
                disputeId,
                juror,
                snapshot.reputation,
                snapshot.responseScore,
                snapshot.loadScore,
                snapshot.weight,
                snapshot.pendingPanels
            );
        }

        emit ReviewCreated(
            disputeId,
            dispute.jobId,
            proposedFinalStatus,
            upheldResolution,
            rejectedResolution,
            deadlineAt,
            panelSize,
            majorityThreshold
        );
    }

    function castVote(uint256 disputeId, VoteChoice choice) external nonReentrant {
        if (choice == VoteChoice.None) revert InvalidVote();

        ReviewConfig storage review = reviews[disputeId];
        if (review.createdAt == 0) revert ReviewNotFound();
        if (review.resolved) revert ReviewAlreadyResolved();

        uint64 deadline = review.deadlineAt;
        if (block.timestamp >= deadline) revert ReviewDeadlinePassed(deadline);

        if (!isSelectedJuror[disputeId][msg.sender]) revert JurorNotSelected();
        if (votes[disputeId][msg.sender] != VoteChoice.None) revert AlreadyVoted();

        votes[disputeId][msg.sender] = choice;
        jurorResponses[msg.sender] += 1;

        ReviewTally storage tally = tallies[disputeId];
        if (choice == VoteChoice.Uphold) {
            tally.upholdCount += 1;
        } else {
            tally.rejectCount += 1;
        }

        emit VoteCast(disputeId, msg.sender, choice, tally.upholdCount, tally.rejectCount);

        if (tally.upholdCount >= review.majorityThreshold) {
            _resolveReview(disputeId, true);
            return;
        }
        if (tally.rejectCount >= review.majorityThreshold) {
            _resolveReview(disputeId, false);
        }
    }

    function claimRewards() external nonReentrant {
        JurorAccount storage juror = jurors[msg.sender];
        uint256 amount = juror.accruedRewards;
        if (amount == 0) revert InvalidAmount();

        juror.accruedRewards = 0;
        settlementToken.safeTransfer(msg.sender, amount);

        emit RewardsClaimed(msg.sender, amount);
    }

    /// @notice Expire a review that has passed its deadline without reaching majority.
    /// Routes through PactCommerce dispute expiry so stalled jury review returns the full bond.
    /// Anyone may call this after the deadline.
    function expireReview(uint256 disputeId) external nonReentrant {
        ReviewConfig storage review = reviews[disputeId];
        if (review.createdAt == 0) revert ReviewNotFound();
        if (review.resolved) revert ReviewAlreadyResolved();

        uint64 deadline = review.deadlineAt;
        if (block.timestamp < deadline) revert ReviewDeadlineNotReached();

        ReviewTally storage tally = tallies[disputeId];
        emit ReviewExpired(disputeId, deadline, tally.upholdCount, tally.rejectCount);

        review.resolved = true;
        review.upheld = false;
        review.resolvedAt = uint64(block.timestamp);

        IPactCommerce.Dispute memory dispute = commerce.getDispute(disputeId);
        IPactCommerce.Job memory job = commerce.getJob(dispute.jobId);

        // Preserve the original terminal job state and refund the full bond when jury liveness fails.
        commerce.expireDispute(disputeId, review.rejectedResolution);

        _recordExpiredOutcome(disputeId);
        _releasePendingPanels(disputeId);

        emit ReviewResolved(disputeId, false, job.status, review.rejectedResolution, 0, 0);
    }

    function getPanel(uint256 disputeId) external view returns (address[] memory) {
        return reviewPanels[disputeId];
    }

    function getSelectionSnapshot(uint256 disputeId, address juror)
        external
        view
        returns (uint16 reputation, uint16 responseScore, uint16 loadScore, uint256 weight, uint32 pendingPanels)
    {
        SelectionSnapshot memory snapshot = reviewSelectionSnapshots[disputeId][juror];
        return
            (snapshot.reputation, snapshot.responseScore, snapshot.loadScore, snapshot.weight, snapshot.pendingPanels);
    }

    function _resolveReview(uint256 disputeId, bool upheld) internal {
        ReviewConfig storage review = reviews[disputeId];
        review.resolved = true;
        review.upheld = upheld;
        review.resolvedAt = uint64(block.timestamp);

        IPactCommerce.Dispute memory dispute = commerce.getDispute(disputeId);

        IPactCommerce.Status finalStatus;
        bytes32 resolution;
        if (upheld) {
            finalStatus = review.proposedFinalStatus;
            resolution = review.upheldResolution;
        } else {
            finalStatus = commerce.getJob(dispute.jobId).status;
            resolution = review.rejectedResolution;
        }

        uint256 balanceBefore = settlementToken.balanceOf(address(this));
        commerce.resolveDispute(disputeId, upheld, finalStatus, resolution);
        uint256 rewardAmount = settlementToken.balanceOf(address(this)) - balanceBefore;

        VoteChoice outcome = upheld ? VoteChoice.Uphold : VoteChoice.Reject;
        uint256 alignedJurorCount = _allocateRewards(disputeId, outcome, rewardAmount);
        _recordResolvedOutcome(disputeId, outcome);
        _releasePendingPanels(disputeId);

        emit ReviewResolved(disputeId, upheld, finalStatus, resolution, rewardAmount, alignedJurorCount);
    }

    function _selectJurors(
        uint256 disputeId,
        uint256 jobId,
        bytes32 evidenceHash,
        IPactCommerce.Job memory job,
        address challenger
    ) internal view returns (address[] memory selectedJurors) {
        address[] memory eligibleJurors = _eligibleJurors(job, challenger);
        uint256 eligibleCount = eligibleJurors.length;
        if (eligibleCount < panelSize) {
            revert InsufficientEligibleJurors(eligibleCount, panelSize);
        }

        bytes32 selectionSeed =
            keccak256(abi.encode(block.prevrandao, block.timestamp, disputeId, jobId, evidenceHash, panelSize));

        selectedJurors = new address[](panelSize);
        for (uint256 i = 0; i < panelSize; ++i) {
            uint256 remainingWeight;
            for (uint256 j = i; j < eligibleJurors.length; ++j) {
                remainingWeight += _selectionWeight(eligibleJurors[j]);
            }

            uint256 targetWeight = uint256(keccak256(abi.encode(selectionSeed, i))) % remainingWeight;
            uint256 cumulativeWeight;
            uint256 selectedIndex = i;

            for (uint256 j = i; j < eligibleJurors.length; ++j) {
                cumulativeWeight += _selectionWeight(eligibleJurors[j]);
                if (targetWeight < cumulativeWeight) {
                    selectedIndex = j;
                    break;
                }
            }

            (eligibleJurors[i], eligibleJurors[selectedIndex]) = (eligibleJurors[selectedIndex], eligibleJurors[i]);
            selectedJurors[i] = eligibleJurors[i];
        }
    }

    function _eligibleJurors(IPactCommerce.Job memory job, address challenger)
        internal
        view
        returns (address[] memory eligibleJurors)
    {
        uint256 eligibleCount;
        for (uint256 i = 0; i < jurorRegistry.length; ++i) {
            if (_isEligibleJuror(jurorRegistry[i], job, challenger)) {
                eligibleCount += 1;
            }
        }

        eligibleJurors = new address[](eligibleCount);
        uint256 cursor;
        for (uint256 i = 0; i < jurorRegistry.length; ++i) {
            address juror = jurorRegistry[i];
            if (!_isEligibleJuror(juror, job, challenger)) {
                continue;
            }

            eligibleJurors[cursor] = juror;
            cursor += 1;
        }
    }

    function _isEligibleJuror(address account, IPactCommerce.Job memory job, address challenger)
        internal
        view
        returns (bool)
    {
        JurorAccount storage juror = jurors[account];
        return
            juror.active && juror.reputation >= minimumJurorReputation
                && !_isReviewParticipant(account, job, challenger);
    }

    function _isReviewParticipant(address account, IPactCommerce.Job memory job, address challenger)
        internal
        pure
        returns (bool)
    {
        return account == job.client || account == job.provider || account == job.evaluator || account == challenger;
    }

    function _selectionWeight(address juror) internal view returns (uint256) {
        return jurorSelectionWeight(juror);
    }

    function _releasePendingPanels(uint256 disputeId) internal {
        address[] storage panel = reviewPanels[disputeId];
        for (uint256 i = 0; i < panel.length; ++i) {
            JurorAccount storage juror = jurors[panel[i]];
            if (juror.pendingPanels > 0) {
                juror.pendingPanels -= 1;
            }
        }
    }

    function _recordResolvedOutcome(uint256 disputeId, VoteChoice finalOutcome) internal {
        address[] storage panel = reviewPanels[disputeId];
        for (uint256 i = 0; i < panel.length; ++i) {
            address juror = panel[i];
            VoteChoice jurorChoice = votes[disputeId][juror];
            if (jurorChoice == VoteChoice.None) {
                continue;
            }

            JurorPerformance storage performance = jurorPerformances[juror];
            performance.resolvedReviews += 1;
            if (jurorChoice == finalOutcome) {
                performance.alignedReviews += 1;
            }

            emit JurorPerformanceUpdated(
                disputeId,
                juror,
                jurorChoice,
                finalOutcome,
                jurorReputation(juror),
                performance.resolvedReviews,
                performance.alignedReviews,
                performance.expiredReviews
            );
        }
    }

    function _recordExpiredOutcome(uint256 disputeId) internal {
        address[] storage panel = reviewPanels[disputeId];
        for (uint256 i = 0; i < panel.length; ++i) {
            address juror = panel[i];
            VoteChoice jurorChoice = votes[disputeId][juror];
            if (jurorChoice == VoteChoice.None) {
                continue;
            }

            JurorPerformance storage performance = jurorPerformances[juror];
            performance.expiredReviews += 1;

            emit JurorPerformanceUpdated(
                disputeId,
                juror,
                jurorChoice,
                VoteChoice.None,
                jurorReputation(juror),
                performance.resolvedReviews,
                performance.alignedReviews,
                performance.expiredReviews
            );
        }
    }

    function _allocateRewards(uint256 disputeId, VoteChoice outcome, uint256 rewardAmount)
        internal
        returns (uint256 alignedJurorCount)
    {
        if (rewardAmount == 0) {
            return 0;
        }

        address[] storage panel = reviewPanels[disputeId];
        for (uint256 i = 0; i < panel.length; ++i) {
            if (votes[disputeId][panel[i]] == outcome) {
                alignedJurorCount += 1;
            }
        }

        if (alignedJurorCount == 0) {
            return 0;
        }

        uint256 rewardPerJuror = rewardAmount / alignedJurorCount;
        uint256 remainder = rewardAmount % alignedJurorCount;
        address remainderRecipient;

        for (uint256 i = 0; i < panel.length; ++i) {
            address jurorAddress = panel[i];
            if (votes[disputeId][jurorAddress] != outcome) {
                continue;
            }

            jurors[jurorAddress].accruedRewards += rewardPerJuror;
            if (remainderRecipient == address(0)) {
                remainderRecipient = jurorAddress;
            }
        }

        if (remainder > 0 && remainderRecipient != address(0)) {
            jurors[remainderRecipient].accruedRewards += remainder;
        }
    }
}
