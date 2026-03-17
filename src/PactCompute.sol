// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {IPactCompute} from "./interfaces/IPactCompute.sol";

/// @title PactCompute
/// @notice On-chain compute marketplace with resource pricing and X402 billing (§5.5).
///         Providers register capacity; requesters deposit USDC, providers complete jobs,
///         and settlement pays provider + treasury. Integrates with PactX402Gateway for
///         gasless job submission via signed intents.
contract PactCompute is IPactCompute, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ── Revenue split ────────────────────────────────────────────────
    uint16 public constant PROVIDER_BPS = 9000; // 90%
    uint16 public constant TREASURY_BPS = 1000; // 10%
    uint16 private constant BPS_DENOMINATOR = 10_000;

    // ── State ────────────────────────────────────────────────────────
    IERC20 public immutable usdc;
    address public treasury;
    address public x402Gateway; // PactX402Gateway, may relay job creation

    uint256 private nextProviderId = 1;
    uint256 private nextJobId = 1;

    mapping(uint256 providerId => Provider) private providers;
    mapping(uint256 jobId => Job) private jobs;
    /// @dev Track total escrowed USDC not yet settled/refunded.
    uint256 public totalEscrowed;

    // ── Errors ───────────────────────────────────────────────────────
    error ZeroAddress();
    error InvalidAmount();
    error InvalidDuration();
    error ProviderNotFound();
    error ProviderInactive();
    error JobNotFound();
    error InvalidJobStatus();
    error Unauthorized();
    error InsufficientDeposit();

    // ── Constructor ──────────────────────────────────────────────────
    constructor(address usdcAddress, address treasuryAddress) Ownable(msg.sender) {
        if (usdcAddress == address(0) || treasuryAddress == address(0)) revert ZeroAddress();
        usdc = IERC20(usdcAddress);
        treasury = treasuryAddress;
    }

    // ══════════════════════════════════════════════════════════════════
    //  Admin
    // ══════════════════════════════════════════════════════════════════

    /// @notice Set the X402 gateway address for meta-tx relayed job creation.
    function setX402Gateway(address gateway) external onlyOwner {
        x402Gateway = gateway;
    }

    /// @notice Update the treasury address.
    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert ZeroAddress();
        treasury = newTreasury;
    }

    // ══════════════════════════════════════════════════════════════════
    //  Provider Management
    // ══════════════════════════════════════════════════════════════════

    /// @notice Register a compute provider with pricing.
    function registerProvider(
        uint256 cpuCores,
        uint256 memoryMB,
        uint256 gpuCount,
        uint256 pricePerHourCents,
        ResourceType resourceType
    ) external returns (uint256 providerId) {
        if (pricePerHourCents == 0) revert InvalidAmount();

        providerId = nextProviderId++;
        providers[providerId] = Provider({
            owner: msg.sender,
            cpuCores: cpuCores,
            memoryMB: memoryMB,
            gpuCount: gpuCount,
            pricePerHourCents: pricePerHourCents,
            resourceType: resourceType,
            active: true
        });

        emit ProviderRegistered(providerId, msg.sender, resourceType);
    }

    /// @notice Deactivate a provider. Only the provider owner or contract owner can call.
    function deactivateProvider(uint256 providerId) external {
        Provider storage p = providers[providerId];
        if (p.owner == address(0)) revert ProviderNotFound();
        if (msg.sender != p.owner && msg.sender != owner()) revert Unauthorized();

        p.active = false;
        emit ProviderDeactivated(providerId);
    }

    // ══════════════════════════════════════════════════════════════════
    //  Pricing Helpers
    // ══════════════════════════════════════════════════════════════════

    /// @notice Compute the cost in USDC-cents for a given provider and duration.
    function quoteCost(uint256 providerId, uint256 durationSeconds) external view returns (uint256 costCents) {
        Provider storage p = providers[providerId];
        if (p.owner == address(0)) revert ProviderNotFound();
        costCents = _computeCost(p.pricePerHourCents, durationSeconds);
    }

    /// @notice Convert USDC-cents to USDC atomic units (6 decimals).
    function centsToUsdc(uint256 cents) public pure returns (uint256) {
        // 1 cent = 0.01 USDC = 10_000 atomic units (10^4)
        return cents * 10_000;
    }

    // ══════════════════════════════════════════════════════════════════
    //  Job Lifecycle
    // ══════════════════════════════════════════════════════════════════

    /// @notice Create a compute job with an upfront USDC deposit covering max duration.
    ///         Can be called directly or via the X402 gateway (gasless).
    function createJob(
        uint256 providerId,
        bytes32 imageHash,
        bytes32 commandHash,
        uint256 maxDurationSeconds,
        address requester
    ) external nonReentrant returns (uint256 jobId) {
        if (maxDurationSeconds == 0) revert InvalidDuration();

        Provider storage p = providers[providerId];
        if (p.owner == address(0)) revert ProviderNotFound();
        if (!p.active) revert ProviderInactive();

        // Resolve who is actually requesting
        address actualRequester = requester;
        if (msg.sender != requester) {
            // Only the X402 gateway may relay on behalf of another address
            if (msg.sender != x402Gateway) revert Unauthorized();
        }

        uint256 costCents = _computeCost(p.pricePerHourCents, maxDurationSeconds);
        uint256 depositUsdc = centsToUsdc(costCents);
        if (depositUsdc == 0) revert InsufficientDeposit();

        jobId = nextJobId++;
        jobs[jobId] = Job({
            providerId: providerId,
            requester: actualRequester,
            imageHash: imageHash,
            commandHash: commandHash,
            maxDurationSeconds: maxDurationSeconds,
            depositAmount: depositUsdc,
            startedAt: 0,
            completedAt: 0,
            status: JobStatus.Pending
        });

        totalEscrowed += depositUsdc;

        // Pull deposit from requester
        usdc.safeTransferFrom(actualRequester, address(this), depositUsdc);

        emit JobCreated(jobId, providerId, actualRequester, depositUsdc);
    }

    /// @notice Provider marks a job as started.
    function startJob(uint256 jobId) external {
        Job storage job = jobs[jobId];
        if (job.requester == address(0)) revert JobNotFound();
        if (job.status != JobStatus.Pending) revert InvalidJobStatus();

        Provider storage p = providers[job.providerId];
        if (msg.sender != p.owner) revert Unauthorized();

        job.status = JobStatus.Running;
        job.startedAt = block.timestamp;

        emit JobStarted(jobId, block.timestamp);
    }

    /// @notice Provider marks a job as completed. Settlement pays provider + treasury;
    ///         any remaining deposit is refunded to the requester.
    function completeJob(uint256 jobId, uint256 actualDurationSeconds) external nonReentrant {
        Job storage job = jobs[jobId];
        if (job.requester == address(0)) revert JobNotFound();
        if (job.status != JobStatus.Running) revert InvalidJobStatus();

        Provider storage p = providers[job.providerId];
        if (msg.sender != p.owner) revert Unauthorized();

        uint256 costCents = _computeCost(p.pricePerHourCents, actualDurationSeconds);
        uint256 costUsdc = centsToUsdc(costCents);

        // Cap at deposit
        if (costUsdc > job.depositAmount) {
            costUsdc = job.depositAmount;
        }

        uint256 refund = job.depositAmount - costUsdc;

        // Effects
        job.status = JobStatus.Completed;
        job.completedAt = block.timestamp;
        totalEscrowed -= job.depositAmount;

        // Interactions — split cost to provider + treasury
        if (costUsdc > 0) {
            uint256 treasuryAmount = (costUsdc * TREASURY_BPS) / BPS_DENOMINATOR;
            uint256 providerAmount = costUsdc - treasuryAmount;

            usdc.safeTransfer(p.owner, providerAmount);
            usdc.safeTransfer(treasury, treasuryAmount);
        }

        if (refund > 0) {
            usdc.safeTransfer(job.requester, refund);
        }

        emit JobCompleted(jobId, costCents, refund);
    }

    /// @notice Provider reports a job failure. Full deposit is refunded.
    function failJob(uint256 jobId, string calldata reason) external nonReentrant {
        Job storage job = jobs[jobId];
        if (job.requester == address(0)) revert JobNotFound();
        if (job.status != JobStatus.Pending && job.status != JobStatus.Running) revert InvalidJobStatus();

        Provider storage p = providers[job.providerId];
        if (msg.sender != p.owner) revert Unauthorized();

        job.status = JobStatus.Failed;
        job.completedAt = block.timestamp;
        totalEscrowed -= job.depositAmount;

        usdc.safeTransfer(job.requester, job.depositAmount);

        emit JobFailed(jobId, reason);
    }

    /// @notice Requester cancels a pending job. Full refund.
    function cancelJob(uint256 jobId) external nonReentrant {
        Job storage job = jobs[jobId];
        if (job.requester == address(0)) revert JobNotFound();
        if (job.status != JobStatus.Pending) revert InvalidJobStatus();
        if (msg.sender != job.requester) revert Unauthorized();

        job.status = JobStatus.Cancelled;
        job.completedAt = block.timestamp;
        totalEscrowed -= job.depositAmount;

        usdc.safeTransfer(job.requester, job.depositAmount);

        emit JobCancelled(jobId, job.depositAmount);
    }

    // ══════════════════════════════════════════════════════════════════
    //  View Helpers
    // ══════════════════════════════════════════════════════════════════

    function getProvider(uint256 providerId) external view returns (Provider memory) {
        return providers[providerId];
    }

    function getJob(uint256 jobId) external view returns (Job memory) {
        return jobs[jobId];
    }

    function getNextProviderId() external view returns (uint256) {
        return nextProviderId;
    }

    function getNextJobId() external view returns (uint256) {
        return nextJobId;
    }

    // ══════════════════════════════════════════════════════════════════
    //  Internal
    // ══════════════════════════════════════════════════════════════════

    function _computeCost(uint256 pricePerHourCents, uint256 durationSeconds) internal pure returns (uint256) {
        // (pricePerHourCents * durationSeconds) / 3600, round up
        return (pricePerHourCents * durationSeconds + 3599) / 3600;
    }
}
