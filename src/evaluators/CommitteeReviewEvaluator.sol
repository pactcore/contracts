// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

import {IEvaluatorSettlementRecipient} from "../interfaces/IEvaluatorSettlementRecipient.sol";
import {IPactCommerce} from "../interfaces/IPactCommerce.sol";

contract CommitteeReviewEvaluator is IEvaluatorSettlementRecipient, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum VoteChoice {
        None,
        Approve,
        Reject,
        Uncertain
    }

    struct ValidatorAccount {
        uint256 stake;
        uint256 accruedRewards;
        uint8 consecutiveDeviations;
        uint32 pendingAccountings;
        bool active;
    }

    struct JobConfig {
        bytes32 successAttestation;
        bytes32 failureAttestation;
        bytes32 expectedOptParamsHash;
        uint64 reviewDeadline;
        uint32 approvalThreshold;
        uint32 rejectionThreshold;
        bool requireOptParamsHash;
        bool resolved;
    }

    struct VoteTally {
        uint32 approveCount;
        uint32 rejectCount;
        uint32 uncertainCount;
    }

    struct JobResolution {
        VoteChoice committeeOutcome;
        bytes32 attestation;
        bytes32 optParamsHash;
        uint64 resolvedAt;
        uint256 rewardAmount;
        bool accountingFinalized;
    }

    IPactCommerce public immutable commerce;
    IERC20 public immutable settlementToken;
    address public immutable slashRecipient;
    uint256 public immutable minimumStake;
    uint256 public immutable disputeWindow;
    uint256 public immutable reviewPeriod;
    uint16 public immutable slashingBps;
    uint8 public immutable slashAfterDisagreements;

    mapping(address validator => ValidatorAccount) public validators;
    mapping(uint256 jobId => JobConfig) public jobConfigs;
    mapping(uint256 jobId => JobResolution) public jobResolutions;
    mapping(uint256 jobId => VoteTally) public tallies;
    mapping(uint256 jobId => mapping(address validator => VoteChoice choice)) public votes;
    mapping(uint256 jobId => address[]) private jobVoters;

    event ValidatorStaked(address indexed validator, uint256 amount, uint256 newStake, bool active);
    event ValidatorUnstaked(address indexed validator, uint256 amount, uint256 newStake, bool active);
    event RewardsClaimed(address indexed validator, uint256 amount);
    event JobConfigured(
        uint256 indexed jobId,
        bytes32 successAttestation,
        bytes32 failureAttestation,
        uint64 reviewDeadline,
        uint32 approvalThreshold,
        uint32 rejectionThreshold,
        bool requireOptParamsHash,
        bytes32 expectedOptParamsHash
    );
    event VoteCast(
        uint256 indexed jobId,
        address indexed validator,
        VoteChoice indexed choice,
        bytes32 optParamsHash,
        uint32 approveCount,
        uint32 rejectCount,
        uint32 uncertainCount
    );
    event JobResolved(
        uint256 indexed jobId,
        VoteChoice indexed outcome,
        bytes32 indexed attestation,
        uint256 rewardAmount,
        uint256 alignedValidatorCount,
        bytes32 optParamsHash
    );
    event JobAccountingFinalized(
        uint256 indexed jobId,
        VoteChoice indexed finalOutcome,
        bool disputed,
        uint256 rewardAmount,
        uint256 alignedValidatorCount,
        bytes32 resolution
    );
    event ValidatorSlashed(
        uint256 indexed jobId,
        address indexed validator,
        uint256 amount,
        uint8 consecutiveDeviations,
        VoteChoice finalOutcome
    );
    event ValidatorDeviationRecorded(
        uint256 indexed jobId,
        address indexed validator,
        uint8 consecutiveDeviations,
        VoteChoice validatorChoice,
        VoteChoice finalOutcome
    );

    error ZeroAddress();
    error InvalidConfig();
    error InvalidAmount();
    error ValidatorInactive();
    error InsufficientStake();
    error PendingAccounting(uint256 pendingAccountings);
    error JobNotConfigured();
    error JobAlreadyResolved();
    error JobNotResolved();
    error JobAccountingAlreadyFinalized();
    error JobAccountingNotReady();
    error ReviewDeadlineNotReached(uint256 reviewDeadline);
    error InvalidVote();
    error AlreadyVoted();
    error InvalidJobStatus();
    error InvalidOptParamsHash(bytes32 actual, bytes32 expected);

    constructor(
        address commerceAddress,
        address settlementTokenAddress,
        uint256 minimumStakeAmount,
        uint256 disputeWindowSeconds,
        uint256 reviewPeriodSeconds,
        uint16 slashingBpsValue,
        uint8 slashAfterDisagreementsValue,
        address slashRecipientAddress
    ) Ownable(msg.sender) {
        if (
            commerceAddress == address(0) || settlementTokenAddress == address(0) || slashRecipientAddress == address(0)
        ) {
            revert ZeroAddress();
        }
        if (
            minimumStakeAmount == 0 || disputeWindowSeconds == 0 || reviewPeriodSeconds == 0 || slashingBpsValue == 0
                || slashingBpsValue > 10_000 || slashAfterDisagreementsValue == 0
        ) {
            revert InvalidConfig();
        }

        commerce = IPactCommerce(commerceAddress);
        settlementToken = IERC20(settlementTokenAddress);
        minimumStake = minimumStakeAmount;
        disputeWindow = disputeWindowSeconds;
        reviewPeriod = reviewPeriodSeconds;
        slashingBps = slashingBpsValue;
        slashAfterDisagreements = slashAfterDisagreementsValue;
        slashRecipient = slashRecipientAddress;
    }

    function stake(uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidAmount();

        ValidatorAccount storage validator = validators[msg.sender];
        settlementToken.safeTransferFrom(msg.sender, address(this), amount);

        validator.stake += amount;
        validator.active = validator.stake >= minimumStake;

        emit ValidatorStaked(msg.sender, amount, validator.stake, validator.active);
    }

    function unstake(uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidAmount();

        ValidatorAccount storage validator = validators[msg.sender];
        if (validator.pendingAccountings != 0) revert PendingAccounting(validator.pendingAccountings);
        if (amount > validator.stake) revert InsufficientStake();

        validator.stake -= amount;
        validator.active = validator.stake >= minimumStake;
        settlementToken.safeTransfer(msg.sender, amount);

        emit ValidatorUnstaked(msg.sender, amount, validator.stake, validator.active);
    }

    function claimRewards() external nonReentrant {
        ValidatorAccount storage validator = validators[msg.sender];
        uint256 amount = validator.accruedRewards;
        if (amount == 0) revert InvalidAmount();

        validator.accruedRewards = 0;
        settlementToken.safeTransfer(msg.sender, amount);

        emit RewardsClaimed(msg.sender, amount);
    }

    function configureJob(
        uint256 jobId,
        bytes32 successAttestation,
        bytes32 failureAttestation,
        uint32 approvalThreshold,
        uint32 rejectionThreshold
    ) external onlyOwner {
        _configureJob(
            jobId, successAttestation, failureAttestation, approvalThreshold, rejectionThreshold, bytes32(0), false
        );
    }

    function configureJobWithOptParamsHash(
        uint256 jobId,
        bytes32 successAttestation,
        bytes32 failureAttestation,
        uint32 approvalThreshold,
        uint32 rejectionThreshold,
        bytes32 expectedOptParamsHash
    ) external onlyOwner {
        _configureJob(
            jobId,
            successAttestation,
            failureAttestation,
            approvalThreshold,
            rejectionThreshold,
            expectedOptParamsHash,
            true
        );
    }

    function castVote(uint256 jobId, VoteChoice choice) external {
        _castVote(jobId, choice, "");
    }

    function castVote(uint256 jobId, VoteChoice choice, bytes calldata optParams) external {
        _castVote(jobId, choice, optParams);
    }

    function finalizeDeadlockedJob(uint256 jobId) external nonReentrant {
        JobConfig storage config = jobConfigs[jobId];
        if (config.approvalThreshold == 0 || config.rejectionThreshold == 0) revert JobNotConfigured();
        if (config.resolved) revert JobAlreadyResolved();
        if (block.timestamp < config.reviewDeadline) revert ReviewDeadlineNotReached(config.reviewDeadline);

        IPactCommerce.Job memory job = commerce.getJob(jobId);
        if (job.status != IPactCommerce.Status.Submitted) revert InvalidJobStatus();

        _resolve(jobId, VoteChoice.Reject, config.failureAttestation, "", keccak256(""));
    }

    function finalizeJobAccounting(uint256 jobId) external nonReentrant {
        JobResolution storage resolution = jobResolutions[jobId];
        if (resolution.resolvedAt == 0) revert JobNotResolved();
        if (resolution.accountingFinalized) revert JobAccountingAlreadyFinalized();

        (VoteChoice finalOutcome, bytes32 finalResolution, bool disputed) = _resolveFinalOutcome(jobId, resolution);

        resolution.accountingFinalized = true;

        uint256 alignedValidatorCount = _settleValidatorAccounting(jobId, finalOutcome);
        _releasePendingAccountings(jobId);

        uint256 rewardAmount = resolution.rewardAmount;
        if (rewardAmount > 0) {
            if (alignedValidatorCount > 0) {
                _allocateRewards(jobId, finalOutcome, rewardAmount, alignedValidatorCount);
            } else {
                settlementToken.safeTransfer(slashRecipient, rewardAmount);
            }
        }

        emit JobAccountingFinalized(jobId, finalOutcome, disputed, rewardAmount, alignedValidatorCount, finalResolution);
    }

    function getVoters(uint256 jobId) external view returns (address[] memory) {
        return jobVoters[jobId];
    }

    function settlementRecipient() external view returns (address) {
        return address(this);
    }

    function _configureJob(
        uint256 jobId,
        bytes32 successAttestation,
        bytes32 failureAttestation,
        uint32 approvalThreshold,
        uint32 rejectionThreshold,
        bytes32 expectedOptParamsHash,
        bool requireOptParamsHash
    ) internal {
        if (approvalThreshold == 0 || rejectionThreshold == 0) revert InvalidConfig();

        JobConfig storage config = jobConfigs[jobId];
        if (config.resolved) revert JobAlreadyResolved();

        address[] storage votersForJob = jobVoters[jobId];
        for (uint256 i = 0; i < votersForJob.length; ++i) {
            address validatorAddress = votersForJob[i];
            if (votes[jobId][validatorAddress] != VoteChoice.None) {
                ValidatorAccount storage validator = validators[validatorAddress];
                if (validator.pendingAccountings > 0) {
                    validator.pendingAccountings -= 1;
                }
                delete votes[jobId][validatorAddress];
            }
        }

        config.successAttestation = successAttestation;
        config.failureAttestation = failureAttestation;
        config.expectedOptParamsHash = expectedOptParamsHash;
        config.reviewDeadline = uint64(block.timestamp + reviewPeriod);
        config.approvalThreshold = approvalThreshold;
        config.rejectionThreshold = rejectionThreshold;
        config.requireOptParamsHash = requireOptParamsHash;
        config.resolved = false;

        delete tallies[jobId];
        delete jobVoters[jobId];
        delete jobResolutions[jobId];

        emit JobConfigured(
            jobId,
            successAttestation,
            failureAttestation,
            config.reviewDeadline,
            approvalThreshold,
            rejectionThreshold,
            requireOptParamsHash,
            expectedOptParamsHash
        );
    }

    function _castVote(uint256 jobId, VoteChoice choice, bytes memory optParams) internal nonReentrant {
        if (choice == VoteChoice.None) revert InvalidVote();

        ValidatorAccount storage validator = validators[msg.sender];
        if (!validator.active) revert ValidatorInactive();

        JobConfig storage config = jobConfigs[jobId];
        if (config.approvalThreshold == 0 || config.rejectionThreshold == 0) revert JobNotConfigured();
        if (config.resolved) revert JobAlreadyResolved();
        if (votes[jobId][msg.sender] != VoteChoice.None) revert AlreadyVoted();

        IPactCommerce.Job memory job = commerce.getJob(jobId);
        if (job.status != IPactCommerce.Status.Submitted) revert InvalidJobStatus();

        bytes32 optParamsHash = keccak256(optParams);
        if (config.requireOptParamsHash && optParamsHash != config.expectedOptParamsHash) {
            revert InvalidOptParamsHash(optParamsHash, config.expectedOptParamsHash);
        }

        votes[jobId][msg.sender] = choice;
        jobVoters[jobId].push(msg.sender);
        validator.pendingAccountings += 1;

        VoteTally storage tally = tallies[jobId];
        if (choice == VoteChoice.Approve) {
            tally.approveCount += 1;
        } else if (choice == VoteChoice.Reject) {
            tally.rejectCount += 1;
        } else {
            tally.uncertainCount += 1;
        }

        emit VoteCast(
            jobId, msg.sender, choice, optParamsHash, tally.approveCount, tally.rejectCount, tally.uncertainCount
        );

        if (tally.approveCount >= config.approvalThreshold) {
            _resolve(jobId, VoteChoice.Approve, config.successAttestation, optParams, optParamsHash);
            return;
        }
        if (tally.rejectCount >= config.rejectionThreshold) {
            _resolve(jobId, VoteChoice.Reject, config.failureAttestation, optParams, optParamsHash);
        }
    }

    function _resolve(
        uint256 jobId,
        VoteChoice outcome,
        bytes32 attestation,
        bytes memory optParams,
        bytes32 optParamsHash
    ) internal {
        JobConfig storage config = jobConfigs[jobId];
        config.resolved = true;

        uint256 balanceBefore = settlementToken.balanceOf(address(this));
        if (outcome == VoteChoice.Approve) {
            commerce.complete(jobId, attestation, optParams);
        } else {
            commerce.reject(jobId, attestation, optParams);
        }
        uint256 rewardAmount = settlementToken.balanceOf(address(this)) - balanceBefore;

        jobResolutions[jobId] = JobResolution({
            committeeOutcome: outcome,
            attestation: attestation,
            optParamsHash: optParamsHash,
            resolvedAt: uint64(block.timestamp),
            rewardAmount: rewardAmount,
            accountingFinalized: false
        });

        emit JobResolved(jobId, outcome, attestation, rewardAmount, 0, optParamsHash);
    }

    function _resolveFinalOutcome(uint256 jobId, JobResolution storage resolution)
        internal
        view
        returns (VoteChoice finalOutcome, bytes32 finalResolution, bool disputed)
    {
        uint256 disputeId = commerce.getDisputeForJob(jobId);
        if (disputeId == 0) {
            if (block.timestamp < uint256(resolution.resolvedAt) + disputeWindow) {
                revert JobAccountingNotReady();
            }

            return (resolution.committeeOutcome, resolution.attestation, false);
        }

        IPactCommerce.Dispute memory dispute = commerce.getDispute(disputeId);
        if (dispute.status == IPactCommerce.DisputeStatus.Open) revert JobAccountingNotReady();

        if (dispute.status == IPactCommerce.DisputeStatus.Rejected) {
            return (resolution.committeeOutcome, resolution.attestation, true);
        }

        IPactCommerce.Job memory job = commerce.getJob(jobId);
        if (job.status == IPactCommerce.Status.Completed) {
            return (VoteChoice.Approve, job.attestation, true);
        }
        if (job.status == IPactCommerce.Status.Rejected) {
            return (VoteChoice.Reject, job.attestation, true);
        }
        if (job.status == IPactCommerce.Status.Expired) {
            return (VoteChoice.None, job.attestation, true);
        }

        revert InvalidJobStatus();
    }

    function _settleValidatorAccounting(uint256 jobId, VoteChoice outcome)
        internal
        returns (uint256 alignedValidatorCount)
    {
        address[] storage votersForJob = jobVoters[jobId];
        uint256 voterCount = votersForJob.length;

        for (uint256 i = 0; i < voterCount; ++i) {
            address validatorAddress = votersForJob[i];
            VoteChoice validatorChoice = votes[jobId][validatorAddress];
            ValidatorAccount storage validator = validators[validatorAddress];

            if (validatorChoice == outcome) {
                validator.consecutiveDeviations = 0;
                alignedValidatorCount += 1;
                continue;
            }

            validator.consecutiveDeviations += 1;
            emit ValidatorDeviationRecorded(
                jobId, validatorAddress, validator.consecutiveDeviations, validatorChoice, outcome
            );

            if (validator.consecutiveDeviations < slashAfterDisagreements) {
                continue;
            }

            uint256 slashAmount = (validator.stake * slashingBps) / 10_000;
            validator.consecutiveDeviations = 0;

            if (slashAmount == 0) {
                continue;
            }

            validator.stake -= slashAmount;
            validator.active = validator.stake >= minimumStake;
            settlementToken.safeTransfer(slashRecipient, slashAmount);

            emit ValidatorSlashed(jobId, validatorAddress, slashAmount, slashAfterDisagreements, outcome);
        }
    }

    function _releasePendingAccountings(uint256 jobId) internal {
        address[] storage votersForJob = jobVoters[jobId];
        uint256 voterCount = votersForJob.length;

        for (uint256 i = 0; i < voterCount; ++i) {
            ValidatorAccount storage validator = validators[votersForJob[i]];
            if (validator.pendingAccountings > 0) {
                validator.pendingAccountings -= 1;
            }
        }
    }

    function _allocateRewards(uint256 jobId, VoteChoice outcome, uint256 rewardAmount, uint256 alignedValidatorCount)
        internal
    {
        address[] storage votersForJob = jobVoters[jobId];
        uint256 rewardPerValidator = rewardAmount / alignedValidatorCount;
        uint256 remainder = rewardAmount % alignedValidatorCount;
        address remainderRecipient;

        for (uint256 i = 0; i < votersForJob.length; ++i) {
            address validatorAddress = votersForJob[i];
            if (votes[jobId][validatorAddress] != outcome) {
                continue;
            }

            validators[validatorAddress].accruedRewards += rewardPerValidator;
            if (remainderRecipient == address(0)) {
                remainderRecipient = validatorAddress;
            }
        }

        if (remainder > 0 && remainderRecipient != address(0)) {
            validators[remainderRecipient].accruedRewards += remainder;
        }
    }
}
