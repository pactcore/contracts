// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IPactCommerce {
    enum Status {
        Open,
        Funded,
        Submitted,
        Completed,
        Rejected,
        Expired
    }

    struct Job {
        address client;
        address provider;
        address evaluator;
        address hook;
        uint256 budget;
        uint256 expiredAt;
        Status status;
        bytes32 deliverable;
        bytes32 attestation;
        string description;
    }

    function createJob(address provider, address evaluator, uint256 expiredAt, string calldata description)
        external
        returns (uint256 jobId);

    function createJob(
        address provider,
        address evaluator,
        uint256 expiredAt,
        string calldata description,
        address hook
    ) external returns (uint256 jobId);

    function setProvider(uint256 jobId, address provider) external;
    function setProvider(uint256 jobId, address provider, bytes calldata optParams) external;

    function setBudget(uint256 jobId, uint256 amount) external;
    function setBudget(uint256 jobId, uint256 amount, bytes calldata optParams) external;

    function fund(uint256 jobId, uint256 expectedBudget) external;
    function fund(uint256 jobId, uint256 expectedBudget, bytes calldata optParams) external;

    function submit(uint256 jobId, bytes32 deliverable) external;
    function submit(uint256 jobId, bytes32 deliverable, bytes calldata optParams) external;

    function complete(uint256 jobId, bytes32 reason) external;
    function getJob(uint256 jobId) external view returns (Job memory);
    function getNextJobId() external view returns (uint256);

    function complete(uint256 jobId, bytes32 reason, bytes calldata optParams) external;

    function reject(uint256 jobId, bytes32 reason) external;
    function reject(uint256 jobId, bytes32 reason, bytes calldata optParams) external;

    function claimRefund(uint256 jobId) external;
}
