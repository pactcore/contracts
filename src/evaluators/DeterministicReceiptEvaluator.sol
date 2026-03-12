// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";

import {IPactCommerce} from "../interfaces/IPactCommerce.sol";

contract DeterministicReceiptEvaluator is Ownable {
    IPactCommerce public immutable commerce;

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
    }

    function evaluate(uint256 jobId) external {
        Expectation memory expectation = expectations[jobId];
        if (!expectation.configured) revert ExpectationNotConfigured();

        IPactCommerce.Job memory job = commerce.getJob(jobId);
        if (job.deliverable == expectation.expectedDeliverable) {
            commerce.complete(jobId, expectation.successAttestation, abi.encode(job.deliverable));
            return;
        }

        commerce.reject(jobId, expectation.failureAttestation, abi.encode(job.deliverable, expectation.expectedDeliverable));
    }
}
