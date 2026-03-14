// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";

import {IEvaluatorSettlementRecipient} from "../interfaces/IEvaluatorSettlementRecipient.sol";
import {IPactCommerce} from "../interfaces/IPactCommerce.sol";

contract DeterministicReceiptEvaluator is IEvaluatorSettlementRecipient, Ownable {
    IPactCommerce public immutable commerce;

    event ExpectationConfigured(
        uint256 indexed jobId, bytes32 expectedDeliverable, bytes32 successAttestation, bytes32 failureAttestation
    );
    event OptParamsHashConfigured(uint256 indexed jobId, bytes32 indexed expectedOptParamsHash);
    event ExpectationCleared(uint256 indexed jobId);
    event JobEvaluated(
        uint256 indexed jobId,
        bool success,
        bytes32 actualDeliverable,
        bytes32 expectedDeliverable,
        bytes32 attestation,
        bytes32 optParamsHash,
        bool optParamsHashMatched
    );

    struct Expectation {
        bytes32 expectedDeliverable;
        bytes32 successAttestation;
        bytes32 failureAttestation;
        bytes32 expectedOptParamsHash;
        bool requireOptParamsHash;
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
        _setExpectation(jobId, expectedDeliverable, successAttestation, failureAttestation, bytes32(0), false);
    }

    function setExpectationWithOptParamsHash(
        uint256 jobId,
        bytes32 expectedDeliverable,
        bytes32 successAttestation,
        bytes32 failureAttestation,
        bytes32 expectedOptParamsHash
    ) external onlyOwner {
        _setExpectation(jobId, expectedDeliverable, successAttestation, failureAttestation, expectedOptParamsHash, true);
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

    function _setExpectation(
        uint256 jobId,
        bytes32 expectedDeliverable,
        bytes32 successAttestation,
        bytes32 failureAttestation,
        bytes32 expectedOptParamsHash,
        bool requireOptParamsHash
    ) internal {
        expectations[jobId] = Expectation({
            expectedDeliverable: expectedDeliverable,
            successAttestation: successAttestation,
            failureAttestation: failureAttestation,
            expectedOptParamsHash: expectedOptParamsHash,
            requireOptParamsHash: requireOptParamsHash,
            configured: true
        });

        emit ExpectationConfigured(jobId, expectedDeliverable, successAttestation, failureAttestation);
        if (requireOptParamsHash) {
            emit OptParamsHashConfigured(jobId, expectedOptParamsHash);
        }
    }

    function _evaluate(uint256 jobId, bytes memory optParams) internal {
        Expectation memory expectation = expectations[jobId];
        if (!expectation.configured) revert ExpectationNotConfigured();

        IPactCommerce.Job memory job = commerce.getJob(jobId);
        bytes32 optParamsHash = keccak256(optParams);
        bool optParamsHashMatched =
            !expectation.requireOptParamsHash || optParamsHash == expectation.expectedOptParamsHash;
        bool success = job.deliverable == expectation.expectedDeliverable && optParamsHashMatched;

        delete expectations[jobId];
        emit ExpectationCleared(jobId);

        if (success) {
            commerce.complete(jobId, expectation.successAttestation, optParams);
            emit JobEvaluated(
                jobId,
                true,
                job.deliverable,
                expectation.expectedDeliverable,
                expectation.successAttestation,
                optParamsHash,
                optParamsHashMatched
            );
            return;
        }

        commerce.reject(jobId, expectation.failureAttestation, optParams);
        emit JobEvaluated(
            jobId,
            false,
            job.deliverable,
            expectation.expectedDeliverable,
            expectation.failureAttestation,
            optParamsHash,
            optParamsHashMatched
        );
    }

    function settlementRecipient() external view returns (address) {
        return owner();
    }
}
