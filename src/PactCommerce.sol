// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

import {IACPHook} from "./interfaces/IACPHook.sol";
import {IPactCommerce} from "./interfaces/IPactCommerce.sol";

contract PactCommerce is IPactCommerce, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant HOOK_GAS_LIMIT = 500_000;

    bytes4 public constant SET_PROVIDER_SELECTOR = bytes4(keccak256("setProvider(uint256,address,bytes)"));
    bytes4 public constant SET_BUDGET_SELECTOR = bytes4(keccak256("setBudget(uint256,uint256,bytes)"));
    bytes4 public constant FUND_SELECTOR = bytes4(keccak256("fund(uint256,uint256,bytes)"));
    bytes4 public constant SUBMIT_SELECTOR = bytes4(keccak256("submit(uint256,bytes32,bytes)"));
    bytes4 public constant COMPLETE_SELECTOR = bytes4(keccak256("complete(uint256,bytes32,bytes)"));
    bytes4 public constant REJECT_SELECTOR = bytes4(keccak256("reject(uint256,bytes32,bytes)"));

    IERC20 public immutable paymentToken;
    address public immutable treasury;
    uint16 public immutable platformFeeBps;

    uint256 private nextJobId = 1;

    mapping(uint256 jobId => Job) private jobs;

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
    event BudgetSet(uint256 indexed jobId, uint256 amount);
    event JobFunded(uint256 indexed jobId, address indexed client, uint256 amount);
    event JobSubmitted(uint256 indexed jobId, address indexed provider, bytes32 deliverable);
    event JobCompleted(uint256 indexed jobId, address indexed evaluator, bytes32 attestation);
    event JobRejected(uint256 indexed jobId, address indexed rejector, bytes32 reason);
    event JobExpired(uint256 indexed jobId);
    event PaymentReleased(uint256 indexed jobId, address indexed provider, uint256 amount, uint256 feeAmount);
    event Refunded(uint256 indexed jobId, address indexed client, uint256 amount);

    error ZeroAddress();
    error InvalidExpiry();
    error InvalidFeeBps();
    error JobNotFound();
    error InvalidStatus();
    error UnauthorizedCaller();
    error ProviderAlreadySet();
    error ProviderRequired();
    error InvalidBudget();
    error BudgetMismatch();
    error JobNotExpired();
    error HookCallFailed(address hook, bytes4 selector, bool beforePhase);

    constructor(address paymentTokenAddress, address treasuryAddress, uint16 feeBps) Ownable(msg.sender) {
        if (paymentTokenAddress == address(0)) revert ZeroAddress();
        if (feeBps > 10_000) revert InvalidFeeBps();
        if (feeBps > 0 && treasuryAddress == address(0)) revert ZeroAddress();

        paymentToken = IERC20(paymentTokenAddress);
        treasury = treasuryAddress;
        platformFeeBps = feeBps;
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
        if (evaluator == address(0)) revert ZeroAddress();
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

        uint256 feeAmount = (job.budget * platformFeeBps) / 10_000;
        uint256 providerAmount = job.budget - feeAmount;

        if (feeAmount > 0) {
            paymentToken.safeTransfer(treasury, feeAmount);
        }
        paymentToken.safeTransfer(job.provider, providerAmount);

        emit JobCompleted(jobId, msg.sender, reason);
        emit PaymentReleased(jobId, job.provider, providerAmount, feeAmount);
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

    function getNextJobId() external view returns (uint256) {
        return nextJobId;
    }

    function previewPayout(uint256 jobId) external view returns (uint256 providerAmount, uint256 feeAmount) {
        Job storage job = _getJob(jobId);

        feeAmount = (job.budget * platformFeeBps) / 10_000;
        providerAmount = job.budget - feeAmount;
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

    function _getJob(uint256 jobId) internal view returns (Job storage job) {
        job = jobs[jobId];
        if (job.client == address(0)) revert JobNotFound();
    }
}
