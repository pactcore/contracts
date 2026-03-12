// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IACPHook} from "../interfaces/IACPHook.sol";

abstract contract BaseCommerceHook is IACPHook {
    address public immutable commerce;

    error OnlyCommerce();
    error ZeroAddress();

    constructor(address commerceAddress) {
        if (commerceAddress == address(0)) revert ZeroAddress();
        commerce = commerceAddress;
    }

    modifier onlyCommerce() {
        if (msg.sender != commerce) revert OnlyCommerce();
        _;
    }

    function beforeAction(uint256 jobId, bytes4 selector, bytes calldata data) external onlyCommerce {
        _beforeAction(jobId, selector, data);
    }

    function afterAction(uint256 jobId, bytes4 selector, bytes calldata data) external onlyCommerce {
        _afterAction(jobId, selector, data);
    }

    function _beforeAction(uint256 jobId, bytes4 selector, bytes calldata data) internal virtual;
    function _afterAction(uint256 jobId, bytes4 selector, bytes calldata data) internal virtual;
}
