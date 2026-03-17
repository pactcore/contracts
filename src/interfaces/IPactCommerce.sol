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

    /// @notice Task classification per whitepaper §5.1
    enum TaskType {
        Physical, // Location-dependent tasks requiring physical presence
        Digital, // Online/remote tasks (code, design, data labeling)
        Verification, // Validation/review tasks
        Micro // Small, quick tasks (surveys, clicks, simple labels)
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
        TaskType taskType;
    }

    struct Dispute {
        uint256 jobId;
        address challenger;
        bytes32 subjectType;
        bytes32 subjectRef;
        bytes32 evidenceHash;
        uint256 bondAmount;
        uint64 openedAt;
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

    function createJob(
        address provider,
        address evaluator,
        uint256 expiredAt,
        string calldata description,
        address hook,
        TaskType taskType
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

    function resolveDispute(uint256 disputeId, bool upheld, Status finalStatus, bytes32 resolution) external;
    function expireDispute(uint256 disputeId, bytes32 resolution) external;

    function claimRefund(uint256 jobId) external;
    function getJob(uint256 jobId) external view returns (Job memory);
    function getJobTaskType(uint256 jobId) external view returns (TaskType);
    function getDispute(uint256 disputeId) external view returns (Dispute memory);
    function getDisputeForJob(uint256 jobId) external view returns (uint256 disputeId);
    function disputeBondAmount() external view returns (uint256);
    function disputeDeadlineDuration() external view returns (uint256);
    function getNextJobId() external view returns (uint256);
    function getNextDisputeId() external view returns (uint256);
    function previewPayout(uint256 jobId) external view returns (uint256 providerAmount, uint256 withheldAmount);
    function previewSettlement(uint256 jobId)
        external
        view
        returns (uint256 providerAmount, uint256 validatorAmount, uint256 treasuryAmount, uint256 issuerAmount);
}
