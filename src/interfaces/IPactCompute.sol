// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IPactCompute
/// @notice Interface for the PACT Compute Marketplace (§5.5).
interface IPactCompute {
    enum ResourceType {
        Serverless,
        Container,
        VM,
        GPU
    }

    enum JobStatus {
        Pending,
        Running,
        Completed,
        Failed,
        Cancelled
    }

    struct Provider {
        address owner;
        uint256 cpuCores;
        uint256 memoryMB;
        uint256 gpuCount;
        uint256 pricePerHourCents; // USDC cents
        ResourceType resourceType;
        bool active;
    }

    struct Job {
        uint256 providerId;
        address requester;
        bytes32 imageHash;
        bytes32 commandHash;
        uint256 maxDurationSeconds;
        uint256 depositAmount;
        uint256 startedAt;
        uint256 completedAt;
        JobStatus status;
    }

    event ProviderRegistered(uint256 indexed providerId, address indexed owner, ResourceType resourceType);
    event ProviderDeactivated(uint256 indexed providerId);
    event JobCreated(uint256 indexed jobId, uint256 indexed providerId, address indexed requester, uint256 deposit);
    event JobStarted(uint256 indexed jobId, uint256 startedAt);
    event JobCompleted(uint256 indexed jobId, uint256 actualCostCents, uint256 refund);
    event JobFailed(uint256 indexed jobId, string reason);
    event JobCancelled(uint256 indexed jobId, uint256 refund);
}
