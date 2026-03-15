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

    enum DisputeStatus {
        None,
        Open,
        Upheld,
        Rejected
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

    struct Dispute {
        uint256 jobId;
        address challenger;
        bytes32 subjectType;
        bytes32 subjectRef;
        bytes32 evidenceHash;
        uint256 bondAmount;
        DisputeStatus status;
        bytes32 resolution;
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

    function setEvaluator(uint256 jobId, address evaluator) external;
    function setEvaluator(uint256 jobId, address evaluator, bytes calldata optParams) external;

    function setBudget(uint256 jobId, uint256 amount) external;
    function setBudget(uint256 jobId, uint256 amount, bytes calldata optParams) external;

    function fund(uint256 jobId, uint256 expectedBudget) external;
    function fund(uint256 jobId, uint256 expectedBudget, bytes calldata optParams) external;

    function submit(uint256 jobId, bytes32 deliverable) external;
    function submit(uint256 jobId, bytes32 deliverable, bytes calldata optParams) external;

    function complete(uint256 jobId, bytes32 reason) external;
    function complete(uint256 jobId, bytes32 reason, bytes calldata optParams) external;

    function reject(uint256 jobId, bytes32 reason) external;
    function reject(uint256 jobId, bytes32 reason, bytes calldata optParams) external;

    function raiseDispute(
        uint256 jobId,
        bytes32 subjectType,
        bytes32 subjectRef,
        bytes32 evidenceHash,
        uint256 expectedBondAmount
    ) external returns (uint256 disputeId);

    function resolveDispute(uint256 disputeId, bool upheld, bytes32 resolution) external;

    function claimRefund(uint256 jobId) external;
    function getJob(uint256 jobId) external view returns (Job memory);
    function getDispute(uint256 disputeId) external view returns (Dispute memory);
    function getDisputeForJob(uint256 jobId) external view returns (uint256 disputeId);
    function disputeBondAmount() external view returns (uint256);
    function getNextJobId() external view returns (uint256);
    function getNextDisputeId() external view returns (uint256);
    function previewPayout(uint256 jobId) external view returns (uint256 providerAmount, uint256 feeAmount);
}
