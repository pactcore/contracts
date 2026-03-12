// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IGovernanceEvaluator {
    function executeDecision(uint256 jobId, bool approve, bytes32 reason, bytes calldata optParams) external;
}
