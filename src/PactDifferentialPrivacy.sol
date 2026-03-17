// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {IPactDifferentialPrivacy} from "./interfaces/IPactDifferentialPrivacy.sol";

/// @title PactDifferentialPrivacy
/// @notice On-chain privacy budget accounting for PACT data marketplace (§5.4).
///         Noise is applied off-chain; this contract enforces budgets, records queries,
///         and supports sequential composition theorem tracking.
contract PactDifferentialPrivacy is Ownable, IPactDifferentialPrivacy {
    uint256 public constant SCALE = 1e18;

    uint256 private nextDatasetId = 1;

    mapping(uint256 datasetId => DatasetConfig) private datasets;
    mapping(uint256 datasetId => QueryRecord[]) private queryHistory;
    mapping(uint256 datasetId => mapping(address querier => uint256)) private querierBudget;

    constructor() Ownable(msg.sender) {}

    // ─── Dataset Management ────────────────────────────────

    /// @notice Register a dataset with a total privacy budget (epsilon * 1e18).
    function registerDataset(uint256 maxBudget) external returns (uint256 datasetId) {
        if (maxBudget == 0) revert InvalidBudget();

        datasetId = nextDatasetId;
        nextDatasetId++;

        datasets[datasetId] =
            DatasetConfig({maxBudget: maxBudget, usedBudget: 0, queryCount: 0, owner: msg.sender, active: true});

        emit DatasetRegistered(datasetId, msg.sender, maxBudget);
    }

    /// @notice Deactivate a dataset. Only owner or contract owner.
    function deactivateDataset(uint256 datasetId) external {
        DatasetConfig storage ds = datasets[datasetId];
        if (ds.owner == address(0)) revert DatasetNotFound();
        if (msg.sender != ds.owner && msg.sender != owner()) revert Unauthorized();

        ds.active = false;
        emit DatasetDeactivated(datasetId);
    }

    /// @notice Update the max privacy budget. Only dataset owner.
    ///         New budget must be >= used budget.
    function updateBudget(uint256 datasetId, uint256 newMaxBudget) external {
        DatasetConfig storage ds = datasets[datasetId];
        if (ds.owner == address(0)) revert DatasetNotFound();
        if (msg.sender != ds.owner) revert Unauthorized();
        if (newMaxBudget < ds.usedBudget) revert InvalidBudget();

        ds.maxBudget = newMaxBudget;
        emit BudgetUpdated(datasetId, newMaxBudget);
    }

    // ─── Query Recording ───────────────────────────────────

    /// @notice Record a privacy-consuming query. Caller must be dataset owner (off-chain oracle/gateway).
    ///         Reverts if the dataset budget would be exceeded (composition theorem).
    /// @param datasetId The dataset being queried
    /// @param querier The address performing the query
    /// @param epsilon Privacy cost of this query (scaled by 1e18)
    /// @param mechanism The noise mechanism used off-chain
    function recordQuery(uint256 datasetId, address querier, uint256 epsilon, Mechanism mechanism) external {
        if (querier == address(0)) revert ZeroAddress();
        if (epsilon == 0) revert InvalidEpsilon();

        DatasetConfig storage ds = datasets[datasetId];
        if (ds.owner == address(0)) revert DatasetNotFound();
        if (!ds.active) revert DatasetInactive();
        if (msg.sender != ds.owner && msg.sender != owner()) revert Unauthorized();

        uint256 newUsed = ds.usedBudget + epsilon;
        uint256 remaining = ds.maxBudget - ds.usedBudget;
        if (newUsed > ds.maxBudget) revert BudgetExceeded(epsilon, remaining);

        // Update state
        ds.usedBudget = newUsed;
        ds.queryCount++;
        querierBudget[datasetId][querier] += epsilon;

        queryHistory[datasetId].push(
            QueryRecord({
                datasetId: datasetId,
                querier: querier,
                epsilon: epsilon,
                mechanism: mechanism,
                timestamp: uint64(block.timestamp)
            })
        );

        uint256 newRemaining = ds.maxBudget - newUsed;
        emit QueryRecorded(datasetId, querier, epsilon, mechanism, newRemaining);

        if (newUsed == ds.maxBudget) {
            emit BudgetExhausted(datasetId);
        }
    }

    // ─── Views ─────────────────────────────────────────────

    /// @notice Get dataset configuration.
    function getDataset(uint256 datasetId) external view returns (DatasetConfig memory) {
        return datasets[datasetId];
    }

    /// @notice Get remaining privacy budget for a dataset.
    function remainingBudget(uint256 datasetId) external view returns (uint256) {
        DatasetConfig storage ds = datasets[datasetId];
        if (ds.owner == address(0)) revert DatasetNotFound();
        return ds.maxBudget - ds.usedBudget;
    }

    /// @notice Get total epsilon consumed by a specific querier on a dataset.
    function querierUsedBudget(uint256 datasetId, address querier) external view returns (uint256) {
        return querierBudget[datasetId][querier];
    }

    /// @notice Get query history for a dataset.
    function getQueryHistory(uint256 datasetId) external view returns (QueryRecord[] memory) {
        return queryHistory[datasetId];
    }

    /// @notice Get total query count for a dataset.
    function getQueryCount(uint256 datasetId) external view returns (uint256) {
        DatasetConfig storage ds = datasets[datasetId];
        if (ds.owner == address(0)) revert DatasetNotFound();
        return ds.queryCount;
    }

    /// @notice Compute sequential composition: sum of all epsilons for a dataset.
    ///         Should equal ds.usedBudget, but can be verified via query history.
    function computeComposition(uint256 datasetId) external view returns (uint256 totalEpsilon) {
        QueryRecord[] storage history = queryHistory[datasetId];
        for (uint256 i = 0; i < history.length; i++) {
            totalEpsilon += history[i].epsilon;
        }
    }

    /// @notice Get next dataset ID (for off-chain indexing).
    function getNextDatasetId() external view returns (uint256) {
        return nextDatasetId;
    }
}
