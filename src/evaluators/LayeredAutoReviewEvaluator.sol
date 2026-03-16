// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";

import {IEvaluatorSettlementRecipient} from "../interfaces/IEvaluatorSettlementRecipient.sol";
import {IPactCommerce} from "../interfaces/IPactCommerce.sol";

contract LayeredAutoReviewEvaluator is IEvaluatorSettlementRecipient, Ownable {
    IPactCommerce public immutable commerce;

    struct Rule {
        bytes32 expectedDeliverable;
        bytes32 successAttestation;
        bytes32 failureAttestation;
        bytes32 expectedEvidenceHash;
        address reviewAuthority;
        bool requireEvidenceHash;
        bool configured;
    }

    mapping(uint256 jobId => Rule rule) public rules;
    mapping(uint256 jobId => bool pending) public manualReviewPending;
    mapping(uint256 jobId => bytes32 evidenceHash) public pendingEvidenceHashes;

    event RuleConfigured(
        uint256 indexed jobId,
        bytes32 expectedDeliverable,
        bytes32 successAttestation,
        bytes32 failureAttestation,
        address indexed reviewAuthority,
        bool requireEvidenceHash,
        bytes32 expectedEvidenceHash
    );
    event RuleCleared(uint256 indexed jobId);
    event AutoValidationResolved(
        uint256 indexed jobId,
        bool indexed approved,
        bytes32 actualDeliverable,
        bytes32 expectedDeliverable,
        bytes32 evidenceHash,
        bool evidenceHashMatched
    );
    event ManualReviewRequested(
        uint256 indexed jobId,
        address indexed reviewAuthority,
        bytes32 actualDeliverable,
        bytes32 expectedDeliverable,
        bytes32 evidenceHash,
        bool deliverableMatched,
        bool evidenceHashMatched
    );
    event ManualReviewResolved(
        uint256 indexed jobId,
        address indexed reviewAuthority,
        bool indexed approve,
        bytes32 reason,
        bytes32 optParamsHash
    );

    error ZeroAddress();
    error RuleNotConfigured();
    error ManualReviewAlreadyPending();
    error NoManualReviewPending();
    error OnlyReviewAuthority(address caller, address reviewAuthority);

    constructor(address commerceAddress) Ownable(msg.sender) {
        if (commerceAddress == address(0)) revert ZeroAddress();
        commerce = IPactCommerce(commerceAddress);
    }

    function setRule(
        uint256 jobId,
        bytes32 expectedDeliverable,
        bytes32 successAttestation,
        bytes32 failureAttestation,
        address reviewAuthority
    ) external onlyOwner {
        _setRule(jobId, expectedDeliverable, successAttestation, failureAttestation, reviewAuthority, bytes32(0), false);
    }

    function setRuleWithEvidenceHash(
        uint256 jobId,
        bytes32 expectedDeliverable,
        bytes32 successAttestation,
        bytes32 failureAttestation,
        address reviewAuthority,
        bytes32 expectedEvidenceHash
    ) external onlyOwner {
        _setRule(
            jobId,
            expectedDeliverable,
            successAttestation,
            failureAttestation,
            reviewAuthority,
            expectedEvidenceHash,
            true
        );
    }

    function clearRule(uint256 jobId) external onlyOwner {
        _clearReviewState(jobId);
    }

    function evaluate(uint256 jobId) external {
        _evaluate(jobId, "");
    }

    function evaluate(uint256 jobId, bytes calldata optParams) external {
        _evaluate(jobId, optParams);
    }

    function resolveManualReview(uint256 jobId, bool approve, bytes32 reason, bytes calldata optParams) external {
        Rule memory rule = rules[jobId];
        if (!rule.configured) revert RuleNotConfigured();
        if (msg.sender != rule.reviewAuthority) revert OnlyReviewAuthority(msg.sender, rule.reviewAuthority);
        if (!manualReviewPending[jobId]) revert NoManualReviewPending();

        _clearReviewState(jobId);

        if (approve) {
            commerce.complete(jobId, reason, optParams);
        } else {
            commerce.reject(jobId, reason, optParams);
        }

        emit ManualReviewResolved(jobId, msg.sender, approve, reason, keccak256(optParams));
    }

    function _setRule(
        uint256 jobId,
        bytes32 expectedDeliverable,
        bytes32 successAttestation,
        bytes32 failureAttestation,
        address reviewAuthority,
        bytes32 expectedEvidenceHash,
        bool requireEvidenceHash
    ) internal {
        rules[jobId] = Rule({
            expectedDeliverable: expectedDeliverable,
            successAttestation: successAttestation,
            failureAttestation: failureAttestation,
            expectedEvidenceHash: expectedEvidenceHash,
            reviewAuthority: reviewAuthority,
            requireEvidenceHash: requireEvidenceHash,
            configured: true
        });
        delete manualReviewPending[jobId];
        delete pendingEvidenceHashes[jobId];

        emit RuleConfigured(
            jobId,
            expectedDeliverable,
            successAttestation,
            failureAttestation,
            reviewAuthority,
            requireEvidenceHash,
            expectedEvidenceHash
        );
    }

    function _evaluate(uint256 jobId, bytes memory optParams) internal {
        Rule memory rule = rules[jobId];
        if (!rule.configured) revert RuleNotConfigured();
        if (manualReviewPending[jobId]) revert ManualReviewAlreadyPending();

        IPactCommerce.Job memory job = commerce.getJob(jobId);
        bytes32 evidenceHash = keccak256(optParams);
        bool evidenceHashMatched = !rule.requireEvidenceHash || evidenceHash == rule.expectedEvidenceHash;
        bool deliverableMatched = job.deliverable == rule.expectedDeliverable;

        if (deliverableMatched && evidenceHashMatched) {
            _clearReviewState(jobId);
            commerce.complete(jobId, rule.successAttestation, optParams);

            emit AutoValidationResolved(
                jobId, true, job.deliverable, rule.expectedDeliverable, evidenceHash, evidenceHashMatched
            );
            return;
        }

        if (rule.reviewAuthority == address(0)) {
            _clearReviewState(jobId);
            commerce.reject(jobId, rule.failureAttestation, optParams);

            emit AutoValidationResolved(
                jobId, false, job.deliverable, rule.expectedDeliverable, evidenceHash, evidenceHashMatched
            );
            return;
        }

        // Keep the evaluator address fixed while handing uncertain evidence to a Layer-2 reviewer.
        manualReviewPending[jobId] = true;
        pendingEvidenceHashes[jobId] = evidenceHash;

        emit ManualReviewRequested(
            jobId,
            rule.reviewAuthority,
            job.deliverable,
            rule.expectedDeliverable,
            evidenceHash,
            deliverableMatched,
            evidenceHashMatched
        );
    }

    function _clearReviewState(uint256 jobId) internal {
        delete rules[jobId];
        delete manualReviewPending[jobId];
        delete pendingEvidenceHashes[jobId];

        emit RuleCleared(jobId);
    }

    function settlementRecipient() external view returns (address) {
        return owner();
    }
}
