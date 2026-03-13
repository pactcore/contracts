// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";

import {BaseCommerceHook} from "./BaseCommerceHook.sol";
import {IPactCommerce} from "../interfaces/IPactCommerce.sol";

contract CounterpartyPolicyHook is BaseCommerceHook, Ownable {
    bytes4 public constant SET_PROVIDER_SELECTOR = bytes4(keccak256("setProvider(uint256,address,bytes)"));
    bytes4 public constant SET_EVALUATOR_SELECTOR = bytes4(keccak256("setEvaluator(uint256,address,bytes)"));
    bytes4 public constant FUND_SELECTOR = bytes4(keccak256("fund(uint256,uint256,bytes)"));

    uint256 public immutable minimumProviderScore;

    event ProviderScoreUpdated(address indexed provider, uint256 score);
    event EvaluatorApprovalUpdated(address indexed evaluator, bool approved);
    event ProviderScoreVerified(
        uint256 indexed jobId, bytes4 indexed selector, address indexed provider, uint256 score, uint256 minimumScore
    );
    event EvaluatorVerified(uint256 indexed jobId, bytes4 indexed selector, address indexed evaluator, bool approved);

    bytes4 public lastBeforeSelector;
    bytes4 public lastAfterSelector;
    bytes32 public lastBeforeDataHash;
    bytes32 public lastAfterDataHash;
    uint256 public lastBeforeJobId;
    uint256 public lastAfterJobId;
    address public lastCheckedProvider;
    uint256 public lastCheckedScore;
    uint256 public lastRequiredScore;
    address public lastCheckedEvaluator;
    bool public lastCheckedApproval;

    mapping(address provider => uint256 score) public providerScores;
    mapping(address evaluator => bool approved) public approvedEvaluators;

    error ProviderScoreTooLow(address provider, uint256 score, uint256 minimumScore);
    error EvaluatorNotApproved(address evaluator);

    constructor(address commerceAddress, uint256 minimumScore) BaseCommerceHook(commerceAddress) Ownable(msg.sender) {
        minimumProviderScore = minimumScore;
    }

    function setProviderScore(address provider, uint256 score) external onlyOwner {
        providerScores[provider] = score;
        emit ProviderScoreUpdated(provider, score);
    }

    function setEvaluatorApproval(address evaluator, bool approved) external onlyOwner {
        if (evaluator == address(0)) revert ZeroAddress();

        approvedEvaluators[evaluator] = approved;
        emit EvaluatorApprovalUpdated(evaluator, approved);
    }

    function _beforeAction(uint256 jobId, bytes4 selector, bytes calldata data) internal override {
        lastBeforeSelector = selector;
        lastBeforeDataHash = keccak256(data);
        lastBeforeJobId = jobId;

        if (selector == SET_PROVIDER_SELECTOR) {
            (address provider,) = abi.decode(data, (address, bytes));
            _checkProvider(jobId, selector, provider);
            return;
        }

        if (selector == SET_EVALUATOR_SELECTOR) {
            (address evaluator,) = abi.decode(data, (address, bytes));
            _checkEvaluator(jobId, selector, evaluator);
            return;
        }

        if (selector == FUND_SELECTOR) {
            IPactCommerce.Job memory job = IPactCommerce(commerce).getJob(jobId);
            _checkProvider(jobId, selector, job.provider);
            _checkEvaluator(jobId, selector, job.evaluator);
        }
    }

    function _afterAction(uint256 jobId, bytes4 selector, bytes calldata data) internal override {
        lastAfterSelector = selector;
        lastAfterDataHash = keccak256(data);
        lastAfterJobId = jobId;
    }

    function _checkProvider(uint256 jobId, bytes4 selector, address provider) internal {
        uint256 score = providerScores[provider];
        lastCheckedProvider = provider;
        lastCheckedScore = score;
        lastRequiredScore = minimumProviderScore;

        emit ProviderScoreVerified(jobId, selector, provider, score, minimumProviderScore);

        if (score < minimumProviderScore) {
            revert ProviderScoreTooLow(provider, score, minimumProviderScore);
        }
    }

    function _checkEvaluator(uint256 jobId, bytes4 selector, address evaluator) internal {
        bool approved = approvedEvaluators[evaluator];
        lastCheckedEvaluator = evaluator;
        lastCheckedApproval = approved;

        emit EvaluatorVerified(jobId, selector, evaluator, approved);

        if (!approved) {
            revert EvaluatorNotApproved(evaluator);
        }
    }
}
