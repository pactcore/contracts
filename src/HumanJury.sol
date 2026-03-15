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

    struct ReviewConfig {
        IPactCommerce.Status proposedFinalStatus;
        bytes32 upheldResolution;
        bytes32 rejectedResolution;
        uint64 createdAt;
        uint64 resolvedAt;
        uint8 majorityThreshold;
        bool resolved;
        bool upheld;
    }

    struct ReviewTally {
        uint8 upholdCount;
        uint8 rejectCount;
    }

    IPactCommerce public immutable commerce;
    IERC20 public immutable settlementToken;
    uint16 public immutable minimumJurorReputation;
    uint8 public immutable panelSize;
    uint256 public immutable reviewDeadlineDuration;

    mapping(address juror => JurorAccount) public jurors;
    mapping(uint256 disputeId => ReviewConfig) public reviews;
    mapping(uint256 disputeId => ReviewTally) public tallies;
    mapping(uint256 disputeId => mapping(address juror => VoteChoice choice)) public votes;

    address[] private jurorRegistry;
    mapping(address juror => bool knownJuror) private isKnownJuror;
    mapping(uint256 disputeId => address[]) private reviewPanels;
    mapping(uint256 disputeId => mapping(address juror => bool selected)) private isSelectedJuror;

    event JurorConfigured(address indexed juror, uint16 reputation, bool active, uint32 pendingPanels);
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
        uint8 panelSize,
        uint8 majorityThreshold
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

    error ZeroAddress();
    error InvalidConfig();
    error ReviewAlreadyExists();
    error ReviewNotFound();
    error ReviewNotOpen();
    error ReviewAlreadyResolved();
    error InvalidVote();
    error JurorNotSelected();
    error AlreadyVoted();
    error InvalidAmount();
    error InsufficientEligibleJurors(uint256 eligible, uint256 required);
    error ReviewDeadlineNotReached();
    error ReviewDeadlinePassed(uint256 deadline);

    event ReviewExpired(uint256 indexed disputeId, uint64 deadline, uint8 upholdCount, uint8 rejectCount);

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
        if (reviewDeadlineDurationSeconds == 0) revert InvalidConfig();

        commerce = IPactCommerce(commerceAddress);
        settlementToken = IERC20(settlementTokenAddress);
        minimumJurorReputation = minimumJurorReputationValue;
        panelSize = panelSizeValue;
        reviewDeadlineDuration = reviewDeadlineDurationSeconds;
    }

    function configureJuror(address juror, uint16 reputation, bool active) external onlyOwner {
        if (juror == address(0)) revert ZeroAddress();

        if (!isKnownJuror[juror]) {
            isKnownJuror[juror] = true;
            jurorRegistry.push(juror);
        }

        JurorAccount storage account = jurors[juror];
        account.reputation = reputation;
        account.active = active;

        emit JurorConfigured(juror, reputation, active, account.pendingPanels);
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

        IPactCommerce.Job memory job = commerce.getJob(dispute.jobId);
        selectedJurors = _selectJurors(disputeId, dispute.jobId, dispute.evidenceHash, job, dispute.challenger);
        uint8 majorityThreshold = uint8(panelSize / 2) + 1;

        review.proposedFinalStatus = proposedFinalStatus;
        review.upheldResolution = upheldResolution;
        review.rejectedResolution = rejectedResolution;
        review.createdAt = uint64(block.timestamp);
        review.majorityThreshold = majorityThreshold;

        for (uint256 i = 0; i < selectedJurors.length; ++i) {
            address juror = selectedJurors[i];
            reviewPanels[disputeId].push(juror);
            isSelectedJuror[disputeId][juror] = true;
            jurors[juror].pendingPanels += 1;
        }

        emit ReviewCreated(
            disputeId,
            dispute.jobId,
            proposedFinalStatus,
            upheldResolution,
            rejectedResolution,
            panelSize,
            majorityThreshold
        );
    }

    function castVote(uint256 disputeId, VoteChoice choice) external nonReentrant {
        if (choice == VoteChoice.None) revert InvalidVote();

        ReviewConfig storage review = reviews[disputeId];
        if (review.createdAt == 0) revert ReviewNotFound();
        if (review.resolved) revert ReviewAlreadyResolved();

        uint64 deadline = uint64(review.createdAt + reviewDeadlineDuration);
        if (block.timestamp >= deadline) revert ReviewDeadlinePassed(deadline);

        if (!isSelectedJuror[disputeId][msg.sender]) revert JurorNotSelected();
        if (votes[disputeId][msg.sender] != VoteChoice.None) revert AlreadyVoted();

        votes[disputeId][msg.sender] = choice;

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

        uint64 deadline = uint64(review.createdAt + reviewDeadlineDuration);
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

        _releasePendingPanels(disputeId);

        emit ReviewResolved(disputeId, false, job.status, review.rejectedResolution, 0, 0);
    }

    function getPanel(uint256 disputeId) external view returns (address[] memory) {
        return reviewPanels[disputeId];
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

        uint256 alignedJurorCount =
            _allocateRewards(disputeId, upheld ? VoteChoice.Uphold : VoteChoice.Reject, rewardAmount);
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
        uint256 eligibleCount;
        for (uint256 i = 0; i < jurorRegistry.length; ++i) {
            address jurorAddress = jurorRegistry[i];
            JurorAccount storage juror = jurors[jurorAddress];
            if (
                juror.active && juror.reputation >= minimumJurorReputation
                    && !_isReviewParticipant(jurorAddress, job, challenger)
            ) {
                eligibleCount += 1;
            }
        }

        if (eligibleCount < panelSize) {
            revert InsufficientEligibleJurors(eligibleCount, panelSize);
        }

        address[] memory eligibleJurors = new address[](eligibleCount);
        uint256 cursor;
        for (uint256 i = 0; i < jurorRegistry.length; ++i) {
            address jurorAddress = jurorRegistry[i];
            JurorAccount storage juror = jurors[jurorAddress];
            if (
                juror.active && juror.reputation >= minimumJurorReputation
                    && !_isReviewParticipant(jurorAddress, job, challenger)
            ) {
                eligibleJurors[cursor] = jurorAddress;
                cursor += 1;
            }
        }

        selectedJurors = new address[](panelSize);
        for (uint256 i = 0; i < panelSize; ++i) {
            uint256 remaining = eligibleCount - i;
            uint256 index =
                uint256(keccak256(abi.encode(block.prevrandao, disputeId, jobId, evidenceHash, i))) % remaining;
            selectedJurors[i] = eligibleJurors[index];
            eligibleJurors[index] = eligibleJurors[remaining - 1];
        }
    }

    function _isReviewParticipant(address account, IPactCommerce.Job memory job, address challenger)
        internal
        pure
        returns (bool)
    {
        return account == job.client || account == job.provider || account == job.evaluator || account == challenger;
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
