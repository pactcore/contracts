// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPactCommerce} from "../interfaces/IPactCommerce.sol";

contract GovernanceReviewEvaluator {
    IPactCommerce public immutable commerce;
    address public immutable governance;

    event GovernanceDecisionExecuted(
        uint256 indexed jobId, bool indexed approve, bytes32 indexed reason, bytes32 optParamsHash
    );

    error ZeroAddress();
    error OnlyGovernance();

    constructor(address commerceAddress, address governanceAddress) {
        if (commerceAddress == address(0) || governanceAddress == address(0)) revert ZeroAddress();

        commerce = IPactCommerce(commerceAddress);
        governance = governanceAddress;
    }

    function executeDecision(uint256 jobId, bool approve, bytes32 reason, bytes calldata optParams) external {
        if (msg.sender != governance) revert OnlyGovernance();

        if (approve) {
            commerce.complete(jobId, reason, optParams);
        } else {
            commerce.reject(jobId, reason, optParams);
        }

        emit GovernanceDecisionExecuted(jobId, approve, reason, keccak256(optParams));
    }
}
