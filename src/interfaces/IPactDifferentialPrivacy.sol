// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IPactDifferentialPrivacy
/// @notice Interface for on-chain differential privacy budget tracking (§5.4).
interface IPactDifferentialPrivacy {
    enum Mechanism {
        Laplace,
        Gaussian,
        Exponential
    }

    struct DatasetConfig {
        uint256 maxBudget; // scaled by 1e18
        uint256 usedBudget; // scaled by 1e18
        uint256 queryCount;
        address owner;
        bool active;
    }

    struct QueryRecord {
        uint256 datasetId;
        address querier;
        uint256 epsilon; // scaled by 1e18
        Mechanism mechanism;
        uint64 timestamp;
    }

    event DatasetRegistered(uint256 indexed datasetId, address indexed owner, uint256 maxBudget);
    event DatasetDeactivated(uint256 indexed datasetId);
    event BudgetUpdated(uint256 indexed datasetId, uint256 newMaxBudget);
    event QueryRecorded(
        uint256 indexed datasetId,
        address indexed querier,
        uint256 epsilon,
        Mechanism mechanism,
        uint256 remainingBudget
    );
    event BudgetExhausted(uint256 indexed datasetId);

    error ZeroAddress();
    error InvalidEpsilon();
    error InvalidBudget();
    error DatasetNotFound();
    error DatasetInactive();
    error BudgetExceeded(uint256 requested, uint256 remaining);
    error Unauthorized();
}
