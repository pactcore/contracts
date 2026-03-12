// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseCommerceHook} from "../../src/hooks/BaseCommerceHook.sol";

contract MockFailingCommerceHook is BaseCommerceHook {
    bytes4 public failSelector;
    bool public failBefore;
    bool public failAfter;

    error HookFailure(bytes4 selector, bool beforePhase);

    constructor(address commerceAddress) BaseCommerceHook(commerceAddress) {}

    function setFailure(bytes4 selector, bool shouldFailBefore, bool shouldFailAfter) external {
        failSelector = selector;
        failBefore = shouldFailBefore;
        failAfter = shouldFailAfter;
    }

    function _beforeAction(uint256, bytes4 selector, bytes calldata) internal view override {
        if (failBefore && selector == failSelector) {
            revert HookFailure(selector, true);
        }
    }

    function _afterAction(uint256, bytes4 selector, bytes calldata) internal view override {
        if (failAfter && selector == failSelector) {
            revert HookFailure(selector, false);
        }
    }
}
