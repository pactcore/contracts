// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

import {IACPHook} from "./interfaces/IACPHook.sol";
import {IEvaluatorSettlementRecipient} from "./interfaces/IEvaluatorSettlementRecipient.sol";
import {IPactCommerce} from "./interfaces/IPactCommerce.sol";

contract PactCommerce is IPactCommerce, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant HOOK_GAS_LIMIT = 500_000;
    uint256 public constant DEFAULT_DISPUTE_BOND_AMOUNT = 100e6;
    uint256 public constant DEFAULT_DISPUTE_DEADLINE_DURATION = 7 days;
    uint16 public constant BPS_DENOMINATOR = 10_000;
    uint16 public constant DEFAULT_UPHELD_DISPUTE_PENALTY_BPS = 1_000;
    uint16 public constant DEFAULT_VALIDATOR_REWARD_BPS = 500;
    uint16 public constant DEFAULT_ISSUER_REBATE_BPS = 500;

    bytes4 public constant SET_PROVIDER_SELECTOR = bytes4(keccak256("setProvider(uint256,address,bytes)"));
    bytes4 public constant SET_EVALUATOR_SELECTOR = bytes4(keccak256("setEvaluator(uint256,address,bytes)"));
    bytes4 public constant SET_BUDGET_SELECTOR = bytes4(keccak256("setBudget(uint256,uint256,bytes)"));
    bytes4 public constant FUND_SELECTOR = bytes4(keccak256("fund(uint256,uint256,bytes)"));
    bytes4 public constant SUBMIT_SELECTOR = bytes4(keccak256("submit(uint256,bytes32,bytes)"));
    bytes4 public constant COMPLETE_SELECTOR = bytes4(keccak256("complete(uint256,bytes32,bytes)"));
    bytes4 public constant REJECT_SELECTOR = bytes4(keccak256("reject(uint256,bytes32,bytes)"));

    IERC20 public immutable paymentToken;
    address public immutable treasury;
    uint16 public immutable platformFeeBps;
    uint16 public immutable upheldDisputePenaltyBps;
    uint256 public immutable disputeBondAmount;
    uint256 public immutable disputeDeadlineDuration;

    uint256 private nextJobId = 1;
    uint256 private nextDisputeId = 1;

    mapping(uint256 jobId => Job) private jobs;
    mapping(uint256 disputeId => Dispute) private disputes;
    mapping(uint256 jobId => uint256 disputeId) private disputeForJob;

    event JobCreated(
        uint256 indexed jobId,
        address indexed client,
        address indexed provider,
        address evaluator,
        uint256 expiredAt,
        address hook,
        string description
    );
    event ProviderSet(uint256 indexed jobId, address indexed provider);
    event EvaluatorSet(uint256 indexed jobId, address indexed evaluator);
    event BudgetSet(uint256 indexed jobId, uint256 amount);
    event JobFunded(uint256 indexed jobId, address indexed client, uint256 amount);
    event JobSubmitted(uint256 indexed jobId, address indexed provider, bytes32 deliverable);
    event JobCompleted(uint256 indexed jobId, address indexed evaluator, bytes32 attestation);
    event JobRejected(uint256 indexed jobId, address indexed rejector, bytes32 reason);
    event JobExpired(uint256 indexed jobId);
    event PaymentReleased(uint256 indexed jobId, address indexed provider, uint256 amount, uint256 feeAmount);
    event SettlementDistributed(
        uint256 indexed jobId,
        address indexed provider,
        address indexed validatorRecipient,
        address issuerRecipient,
        uint256 providerAmount,
        uint256 validatorAmount,
        uint256 treasuryAmount,
        uint256 issuerAmount
    );
    event Refunded(uint256 indexed jobId, address indexed client, uint256 amount);
    event DisputeRaised(
        uint256 indexed disputeId,
        uint256 indexed jobId,
        address indexed challenger,
        bytes32 subjectType,
        bytes32 subjectRef,
        bytes32 evidenceHash,
        uint256 bondAmount
    );
    event DisputeResolved(
        uint256 indexed disputeId,
        uint256 indexed jobId,
        bool upheld,
        Status finalStatus,
        bytes32 resolution,
        address resolver,
        address juryRecipient,
        address protocolRecipient,
        uint256 challengerRefundAmount,
        uint256 juryAmount,
        uint256 protocolAmount
    );

    error ZeroAddress();
    error InvalidExpiry();
    error InvalidFeeBps();
    error JobNotFound();
    error InvalidStatus();
    error UnauthorizedCaller();
    error ProviderAlreadySet();
    error ProviderRequired();
    error EvaluatorRequired();
    error InvalidBudget();
    error BudgetMismatch();
    error JobNotExpired();
    error HookCallFailed(address hook, bytes4 selector, bool beforePhase);
    error DisputeNotFound();
    error DisputeAlreadyExists();
    error DisputeNotOpen();
    error DisputeDeadlineNotReached();
    error InvalidDisputeBond();
    error InvalidDisputeResolutionStatus();

    constructor(address paymentTokenAddress, address treasuryAddress, uint16 feeBps) Ownable(msg.sender) {
        if (paymentTokenAddress == address(0)) revert ZeroAddress();
        if (feeBps + DEFAULT_VALIDATOR_REWARD_BPS + DEFAULT_ISSUER_REBATE_BPS > 10_000) revert InvalidFeeBps();
        if (feeBps > 0 && treasuryAddress == address(0)) revert ZeroAddress();

        paymentToken = IERC20(paymentTokenAddress);
        treasury = treasuryAddress;
        platformFeeBps = feeBps;
        upheldDisputePenaltyBps = DEFAULT_UPHELD_DISPUTE_PENALTY_BPS;
        disputeBondAmount = DEFAULT_DISPUTE_BOND_AMOUNT;
        disputeDeadlineDuration = DEFAULT_DISPUTE_DEADLINE_DURATION;
    }

    function createJob(address provider, address evaluator, uint256 expiredAt, string calldata description)
        external
        returns (uint256 jobId)
    {
        return createJob(provider, evaluator, expiredAt, description, address(0));
    }

    function createJob(
        address provider,
        address evaluator,
        uint256 expiredAt,
        string calldata description,
        address hook
    ) public returns (uint256 jobId) {
        if (expiredAt <= block.timestamp) revert InvalidExpiry();

        jobId = nextJobId;
        nextJobId++;

        jobs[jobId] = Job({
            client: msg.sender,
            provider: provider,
            evaluator: evaluator,
            hook: hook,
            budget: 0,
            expiredAt: expiredAt,
            status: Status.Open,
            deliverable: bytes32(0),
            attestation: bytes32(0),
            description: description
        });

        emit JobCreated(jobId, msg.sender, provider, evaluator, expiredAt, hook, description);
    }

    function setProvider(uint256 jobId, address provider) external {
        _setProvider(jobId, provider, "");
    }

    function setProvider(uint256 jobId, address provider, bytes calldata optParams) public nonReentrant {
        _setProvider(jobId, provider, optParams);
    }

    function _setProvider(uint256 jobId, address provider, bytes memory optParams) internal {
        Job storage job = _getJob(jobId);
        if (job.status != Status.Open) revert InvalidStatus();
        if (msg.sender != job.client) revert UnauthorizedCaller();
        if (job.provider != address(0)) revert ProviderAlreadySet();
        if (provider == address(0)) revert ZeroAddress();

        bytes memory hookData = abi.encode(provider, optParams);
        _beforeAction(job, jobId, SET_PROVIDER_SELECTOR, hookData);

        job.provider = provider;

        emit ProviderSet(jobId, provider);
        _afterAction(job, jobId, SET_PROVIDER_SELECTOR, hookData);
    }

    function setEvaluator(uint256 jobId, address evaluator) external {
        _setEvaluator(jobId, evaluator, "");
    }

    function setEvaluator(uint256 jobId, address evaluator, bytes calldata optParams) public nonReentrant {
        _setEvaluator(jobId, evaluator, optParams);
    }

    function _setEvaluator(uint256 jobId, address evaluator, bytes memory optParams) internal {
        Job storage job = _getJob(jobId);
        if (job.status != Status.Open) revert InvalidStatus();
        if (msg.sender != job.client) revert UnauthorizedCaller();
        if (evaluator == address(0)) revert ZeroAddress();

        bytes memory hookData = abi.encode(evaluator, optParams);
        _beforeAction(job, jobId, SET_EVALUATOR_SELECTOR, hookData);

        job.evaluator = evaluator;

        emit EvaluatorSet(jobId, evaluator);
        _afterAction(job, jobId, SET_EVALUATOR_SELECTOR, hookData);
    }

    function setBudget(uint256 jobId, uint256 amount) external {
        _setBudget(jobId, amount, "");
    }

    function setBudget(uint256 jobId, uint256 amount, bytes calldata optParams) public nonReentrant {
        _setBudget(jobId, amount, optParams);
    }

    function _setBudget(uint256 jobId, uint256 amount, bytes memory optParams) internal {
        Job storage job = _getJob(jobId);
        if (job.status != Status.Open) revert InvalidStatus();
        if (msg.sender != job.client && msg.sender != job.provider) revert UnauthorizedCaller();

        bytes memory hookData = abi.encode(amount, optParams);
        _beforeAction(job, jobId, SET_BUDGET_SELECTOR, hookData);

        job.budget = amount;

        emit BudgetSet(jobId, amount);
        _afterAction(job, jobId, SET_BUDGET_SELECTOR, hookData);
    }

    function fund(uint256 jobId, uint256 expectedBudget) external {
        _fund(jobId, expectedBudget, "");
    }

    function fund(uint256 jobId, uint256 expectedBudget, bytes calldata optParams) public nonReentrant {
        _fund(jobId, expectedBudget, optParams);
    }

    function _fund(uint256 jobId, uint256 expectedBudget, bytes memory optParams) internal {
        Job storage job = _getJob(jobId);
        if (job.status != Status.Open) revert InvalidStatus();
        if (msg.sender != job.client) revert UnauthorizedCaller();
        if (job.provider == address(0)) revert ProviderRequired();
        if (job.evaluator == address(0)) revert EvaluatorRequired();
        if (job.budget == 0) revert InvalidBudget();
        if (job.budget != expectedBudget) revert BudgetMismatch();

        _beforeAction(job, jobId, FUND_SELECTOR, optParams);

        job.status = Status.Funded;
        paymentToken.safeTransferFrom(job.client, address(this), job.budget);

        emit JobFunded(jobId, job.client, job.budget);
        _afterAction(job, jobId, FUND_SELECTOR, optParams);
    }

    function submit(uint256 jobId, bytes32 deliverable) external {
        _submit(jobId, deliverable, "");
    }

    function submit(uint256 jobId, bytes32 deliverable, bytes calldata optParams) public nonReentrant {
        _submit(jobId, deliverable, optParams);
    }

    function _submit(uint256 jobId, bytes32 deliverable, bytes memory optParams) internal {
        Job storage job = _getJob(jobId);
        if (job.status != Status.Funded) revert InvalidStatus();
        if (msg.sender != job.provider) revert UnauthorizedCaller();

        bytes memory hookData = abi.encode(deliverable, optParams);
        _beforeAction(job, jobId, SUBMIT_SELECTOR, hookData);

        job.status = Status.Submitted;
        job.deliverable = deliverable;

        emit JobSubmitted(jobId, msg.sender, deliverable);
        _afterAction(job, jobId, SUBMIT_SELECTOR, hookData);
    }

    function complete(uint256 jobId, bytes32 reason) external {
        _complete(jobId, reason, "");
    }

    function complete(uint256 jobId, bytes32 reason, bytes calldata optParams) public nonReentrant {
        _complete(jobId, reason, optParams);
    }

    function _complete(uint256 jobId, bytes32 reason, bytes memory optParams) internal {
        Job storage job = _getJob(jobId);
        if (job.status != Status.Submitted) revert InvalidStatus();
        if (msg.sender != job.evaluator) revert UnauthorizedCaller();

        bytes memory hookData = abi.encode(reason, optParams);
        _beforeAction(job, jobId, COMPLETE_SELECTOR, hookData);

        job.status = Status.Completed;
        job.attestation = reason;

        (
            address validatorRecipient,
            uint256 providerAmount,
            uint256 validatorAmount,
            uint256 treasuryAmount,
            uint256 issuerAmount
        ) = _previewSettlement(job);
        uint256 withheldAmount = validatorAmount + treasuryAmount + issuerAmount;

        if (treasuryAmount > 0) {
            paymentToken.safeTransfer(treasury, treasuryAmount);
        }
        if (validatorAmount > 0) {
            paymentToken.safeTransfer(validatorRecipient, validatorAmount);
        }
        if (issuerAmount > 0) {
            paymentToken.safeTransfer(job.client, issuerAmount);
        }
        paymentToken.safeTransfer(job.provider, providerAmount);

        emit JobCompleted(jobId, msg.sender, reason);
        emit PaymentReleased(jobId, job.provider, providerAmount, withheldAmount);
        emit SettlementDistributed(
            jobId,
            job.provider,
            validatorRecipient,
            job.client,
            providerAmount,
            validatorAmount,
            treasuryAmount,
            issuerAmount
        );
        _afterAction(job, jobId, COMPLETE_SELECTOR, hookData);
    }

    function reject(uint256 jobId, bytes32 reason) external {
        _reject(jobId, reason, "");
    }

    function reject(uint256 jobId, bytes32 reason, bytes calldata optParams) public nonReentrant {
        _reject(jobId, reason, optParams);
    }

    function _reject(uint256 jobId, bytes32 reason, bytes memory optParams) internal {
        Job storage job = _getJob(jobId);
        Status currentStatus = job.status;
        if (currentStatus == Status.Open) {
            if (msg.sender != job.client) revert UnauthorizedCaller();
        } else if (currentStatus == Status.Funded || currentStatus == Status.Submitted) {
            if (msg.sender != job.evaluator) revert UnauthorizedCaller();
        } else {
            revert InvalidStatus();
        }

        bytes memory hookData = abi.encode(reason, optParams);
        _beforeAction(job, jobId, REJECT_SELECTOR, hookData);

        job.status = Status.Rejected;
        job.attestation = reason;

        emit JobRejected(jobId, msg.sender, reason);

        if (currentStatus == Status.Funded || currentStatus == Status.Submitted) {
            paymentToken.safeTransfer(job.client, job.budget);
            emit Refunded(jobId, job.client, job.budget);
        }

        _afterAction(job, jobId, REJECT_SELECTOR, hookData);
    }

    function raiseDispute(
        uint256 jobId,
        bytes32 subjectType,
        bytes32 subjectRef,
        bytes32 evidenceHash,
        uint256 expectedBondAmount
    ) external nonReentrant returns (uint256 disputeId) {
        Job storage job = _getJob(jobId);
        if (job.status != Status.Completed && job.status != Status.Rejected && job.status != Status.Expired) {
            revert InvalidStatus();
        }
        if (disputeForJob[jobId] != 0) revert DisputeAlreadyExists();
        if (expectedBondAmount != disputeBondAmount) revert InvalidDisputeBond();

        disputeId = nextDisputeId;
        nextDisputeId++;

        disputes[disputeId] = Dispute({
            jobId: jobId,
            challenger: msg.sender,
            subjectType: subjectType,
            subjectRef: subjectRef,
            evidenceHash: evidenceHash,
            bondAmount: expectedBondAmount,
            openedAt: uint64(block.timestamp),
            status: DisputeStatus.Open,
            resolution: bytes32(0)
        });
        disputeForJob[jobId] = disputeId;

        paymentToken.safeTransferFrom(msg.sender, address(this), expectedBondAmount);

        emit DisputeRaised(disputeId, jobId, msg.sender, subjectType, subjectRef, evidenceHash, expectedBondAmount);
    }

    function resolveDispute(uint256 disputeId, bool upheld, Status finalStatus, bytes32 resolution)
        external
        nonReentrant
    {
        if (msg.sender != owner()) revert UnauthorizedCaller();

        Dispute storage dispute = _getDispute(disputeId);
        if (dispute.status != DisputeStatus.Open) revert DisputeNotOpen();

        Job storage job = _getJob(dispute.jobId);

        dispute.status = upheld ? DisputeStatus.Upheld : DisputeStatus.Rejected;
        dispute.resolution = resolution;

        address juryRecipient = owner();
        address protocolRecipient = treasury == address(0) ? juryRecipient : treasury;
        uint256 challengerRefundAmount;
        uint256 juryAmount;
        uint256 protocolAmount;

        if (upheld) {
            if (finalStatus != Status.Completed && finalStatus != Status.Rejected && finalStatus != Status.Expired) {
                revert InvalidDisputeResolutionStatus();
            }

            uint256 penaltyAmount = (dispute.bondAmount * upheldDisputePenaltyBps) / BPS_DENOMINATOR;
            challengerRefundAmount = dispute.bondAmount - penaltyAmount;
            juryAmount = penaltyAmount / 2;
            protocolAmount = penaltyAmount - juryAmount;

            if (challengerRefundAmount > 0) {
                paymentToken.safeTransfer(dispute.challenger, challengerRefundAmount);
            }

            job.status = finalStatus;
            job.attestation = resolution;
        } else {
            juryAmount = dispute.bondAmount / 2;
            protocolAmount = dispute.bondAmount - juryAmount;
            finalStatus = job.status;
        }

        if (juryAmount > 0) {
            paymentToken.safeTransfer(juryRecipient, juryAmount);
        }
        if (protocolAmount > 0) {
            paymentToken.safeTransfer(protocolRecipient, protocolAmount);
        }

        emit DisputeResolved(
            disputeId,
            dispute.jobId,
            upheld,
            finalStatus,
            resolution,
            msg.sender,
            juryRecipient,
            protocolRecipient,
            challengerRefundAmount,
            juryAmount,
            protocolAmount
        );
    }

    /// @notice Expire an open dispute, returning the bond to the challenger.
    /// Treats the dispute as rejected (original decision upheld). Anyone may call this after the liveness deadline.
    function expireDispute(uint256 disputeId, bytes32 resolution) external nonReentrant {
        Dispute storage dispute = _getDispute(disputeId);
        if (dispute.status != DisputeStatus.Open) revert DisputeNotOpen();
        if (block.timestamp < uint256(dispute.openedAt) + disputeDeadlineDuration) {
            revert DisputeDeadlineNotReached();
        }

        dispute.status = DisputeStatus.Rejected;
        dispute.resolution = resolution;

        // Return full bond to challenger on expiry (no penalty for liveness failure)
        if (dispute.bondAmount > 0) {
            paymentToken.safeTransfer(dispute.challenger, dispute.bondAmount);
        }

        Job storage job = _getJob(dispute.jobId);

        emit DisputeResolved(
            disputeId,
            dispute.jobId,
            false,
            job.status,
            resolution,
            msg.sender,
            address(0),
            address(0),
            dispute.bondAmount,
            0,
            0
        );
    }

    function claimRefund(uint256 jobId) external nonReentrant {
        Job storage job = _getJob(jobId);
        if (job.status != Status.Funded && job.status != Status.Submitted) revert InvalidStatus();
        if (block.timestamp < job.expiredAt) revert JobNotExpired();

        job.status = Status.Expired;
        paymentToken.safeTransfer(job.client, job.budget);

        emit JobExpired(jobId);
        emit Refunded(jobId, job.client, job.budget);
    }

    function getJob(uint256 jobId) external view returns (Job memory) {
        Job storage job = _getJob(jobId);
        return job;
    }

    function getDispute(uint256 disputeId) external view returns (Dispute memory) {
        Dispute storage dispute = _getDispute(disputeId);
        return dispute;
    }

    function getDisputeForJob(uint256 jobId) external view returns (uint256 disputeId) {
        _getJob(jobId);
        return disputeForJob[jobId];
    }

    function getNextJobId() external view returns (uint256) {
        return nextJobId;
    }

    function getNextDisputeId() external view returns (uint256) {
        return nextDisputeId;
    }

    function previewPayout(uint256 jobId) external view returns (uint256 providerAmount, uint256 withheldAmount) {
        Job storage job = _getJob(jobId);
        uint256 validatorAmount;
        uint256 treasuryAmount;
        uint256 issuerAmount;
        (, providerAmount, validatorAmount, treasuryAmount, issuerAmount) = _previewSettlement(job);
        withheldAmount = validatorAmount + treasuryAmount + issuerAmount;
    }

    function previewSettlement(uint256 jobId)
        external
        view
        returns (uint256 providerAmount, uint256 validatorAmount, uint256 treasuryAmount, uint256 issuerAmount)
    {
        Job storage job = _getJob(jobId);
        (, providerAmount, validatorAmount, treasuryAmount, issuerAmount) = _previewSettlement(job);
    }

    function _beforeAction(Job storage job, uint256 jobId, bytes4 selector, bytes memory data) internal {
        if (job.hook == address(0)) return;
        _callHook(job.hook, true, jobId, selector, data);
    }

    function _afterAction(Job storage job, uint256 jobId, bytes4 selector, bytes memory data) internal {
        if (job.hook == address(0)) return;
        _callHook(job.hook, false, jobId, selector, data);
    }

    function _callHook(address hook, bool beforePhase, uint256 jobId, bytes4 selector, bytes memory data) internal {
        bytes memory payload = beforePhase
            ? abi.encodeCall(IACPHook.beforeAction, (jobId, selector, data))
            : abi.encodeCall(IACPHook.afterAction, (jobId, selector, data));

        (bool success, bytes memory returnData) = hook.call{gas: HOOK_GAS_LIMIT}(payload);
        if (success) return;

        if (returnData.length == 0) revert HookCallFailed(hook, selector, beforePhase);

        assembly {
            revert(add(returnData, 0x20), mload(returnData))
        }
    }

    function _previewSettlement(Job storage job)
        internal
        view
        returns (
            address validatorRecipient,
            uint256 providerAmount,
            uint256 validatorAmount,
            uint256 treasuryAmount,
            uint256 issuerAmount
        )
    {
        validatorRecipient = _resolveValidatorRecipient(job.evaluator);
        validatorAmount = (job.budget * DEFAULT_VALIDATOR_REWARD_BPS) / BPS_DENOMINATOR;
        treasuryAmount = (job.budget * platformFeeBps) / BPS_DENOMINATOR;
        issuerAmount = (job.budget * DEFAULT_ISSUER_REBATE_BPS) / BPS_DENOMINATOR;
        providerAmount = job.budget - validatorAmount - treasuryAmount - issuerAmount;
    }

    function _resolveValidatorRecipient(address evaluator) internal view returns (address recipient) {
        recipient = evaluator;
        if (evaluator.code.length == 0) return recipient;

        (bool success, bytes memory returnData) =
            evaluator.staticcall(abi.encodeCall(IEvaluatorSettlementRecipient.settlementRecipient, ()));
        if (!success || returnData.length < 32) return recipient;

        address configuredRecipient = abi.decode(returnData, (address));
        if (configuredRecipient != address(0)) {
            recipient = configuredRecipient;
        }
    }

    function _getJob(uint256 jobId) internal view returns (Job storage job) {
        job = jobs[jobId];
        if (job.client == address(0)) revert JobNotFound();
    }

    function _getDispute(uint256 disputeId) internal view returns (Dispute storage dispute) {
        dispute = disputes[disputeId];
        if (dispute.challenger == address(0)) revert DisputeNotFound();
    }
}
