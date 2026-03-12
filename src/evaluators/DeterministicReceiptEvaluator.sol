// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";

import {IPactCommerce} from "../interfaces/IPactCommerce.sol";

contract DeterministicReceiptEvaluator is Ownable {
    IPactCommerce public immutable commerce;

    event ExpectationConfigured(
        uint256 indexed jobId, bytes32 expectedDeliverable, bytes32 successAttestation, bytes32 failureAttestation
    );
    event ExpectationCleared(uint256 indexed jobId);
    event JobEvaluated(
        uint256 indexed jobId, bool success, bytes32 actualDeliverable, bytes32 expectedDeliverable, bytes32 attestation
    );

    struct Expectation {
        bytes32 expectedDeliverable;
        bytes32 successAttestation;
        bytes32 failureAttestation;
        bool configured;
    }

    mapping(uint256 jobId => Expectation) public expectations;

    error ZeroAddress();
    error ExpectationNotConfigured();

    constructor(address commerceAddress) Ownable(msg.sender) {
        if (commerceAddress == address(0)) revert ZeroAddress();
        commerce = IPactCommerce(commerceAddress);
    }

    function setExpectation(
        uint256 jobId,
        bytes32 expectedDeliverable,
        bytes32 successAttestation,
        bytes32 failureAttestation
    ) external onlyOwner {
        expectations[jobId] = Expectation({
            expectedDeliverable: expectedDeliverable,
            successAttestation: successAttestation,
            failureAttestation: failureAttestation,
            configured: true
        });

        emit ExpectationConfigured(jobId, expectedDeliverable, successAttestation, failureAttestation);
    }

    function clearExpectation(uint256 jobId) external onlyOwner {
        delete expectations[jobId];
        emit ExpectationCleared(jobId);
    }

    function evaluate(uint256 jobId) external {
        _evaluate(jobId, "");
    }

    function evaluate(uint256 jobId, bytes calldata optParams) external {
        _evaluate(jobId, optParams);
    }

    function _evaluate(uint256 jobId, bytes memory optParams) internal {
        Expectation memory expectation = expectations[jobId];
        if (!expectation.configured) revert ExpectationNotConfigured();

        IPactCommerce.Job memory job = commerce.getJob(jobId);
        if (job.deliverable == expectation.expectedDeliverable) {
            commerce.complete(jobId, expectation.successAttestation, optParams);
            emit JobEvaluated(
                jobId, true, job.deliverable, expectation.expectedDeliverable, expectation.successAttestation
            );
            return;
        }

        commerce.reject(jobId, expectation.failureAttestation, optParams);
        emit JobEvaluated(
            jobId, false, job.deliverable, expectation.expectedDeliverable, expectation.failureAttestation
        );
    }
}
