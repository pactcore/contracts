// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";

import {BaseCommerceHook} from "./BaseCommerceHook.sol";
import {IPactCommerce} from "../interfaces/IPactCommerce.sol";

contract ReputationGateHook is BaseCommerceHook, Ownable {
    bytes4 public constant SET_PROVIDER_SELECTOR = bytes4(keccak256("setProvider(uint256,address,bytes)"));
    bytes4 public constant FUND_SELECTOR = bytes4(keccak256("fund(uint256,uint256,bytes)"));

    uint256 public immutable minimumProviderScore;

    bytes4 public lastBeforeSelector;
    bytes4 public lastAfterSelector;
    bytes32 public lastBeforeDataHash;
    bytes32 public lastAfterDataHash;
    uint256 public lastBeforeJobId;
    uint256 public lastAfterJobId;

    mapping(address provider => uint256 score) public providerScores;

    error ProviderScoreTooLow(address provider, uint256 score, uint256 minimumScore);

    constructor(address commerceAddress, uint256 minimumScore) BaseCommerceHook(commerceAddress) Ownable(msg.sender) {
        minimumProviderScore = minimumScore;
    }

    function setProviderScore(address provider, uint256 score) external onlyOwner {
        providerScores[provider] = score;
    }

    function _beforeAction(uint256 jobId, bytes4 selector, bytes calldata data) internal override {
        lastBeforeSelector = selector;
        lastBeforeDataHash = keccak256(data);
        lastBeforeJobId = jobId;

        if (selector == SET_PROVIDER_SELECTOR) {
            (address provider,) = abi.decode(data, (address, bytes));
            _checkProvider(provider);
            return;
        }

        if (selector == FUND_SELECTOR) {
            IPactCommerce.Job memory job = IPactCommerce(commerce).getJob(jobId);
            _checkProvider(job.provider);
        }
    }

    function _afterAction(uint256 jobId, bytes4 selector, bytes calldata data) internal override {
        lastAfterSelector = selector;
        lastAfterDataHash = keccak256(data);
        lastAfterJobId = jobId;
    }

    function _checkProvider(address provider) internal view {
        uint256 score = providerScores[provider];
        if (score < minimumProviderScore) {
            revert ProviderScoreTooLow(provider, score, minimumProviderScore);
        }
    }
}
