// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IPactAutoSwap {
    struct SwapRoute {
        address tokenIn;
        uint24 poolFee;
        bool enabled;
    }

    event SwapExecuted(
        address indexed sender, address indexed tokenIn, uint256 amountIn, uint256 amountOut, bytes32 indexed ref
    );
    event RouteConfigured(address indexed token, uint24 poolFee, bool enabled);
    event SlippageUpdated(uint16 oldBps, uint16 newBps);
    event SwapRouterUpdated(address oldRouter, address newRouter);

    error ZeroAddress();
    error InvalidAmount();
    error TokenNotSupported();
    error SlippageExceeded();
    error InvalidSlippage();
    error SwapFailed();

    function swap(address tokenIn, uint256 amountIn, uint256 minAmountOut, bytes32 ref)
        external
        returns (uint256 amountOut);

    function swapToEscrow(address tokenIn, uint256 amountIn, uint256 minAmountOut, uint256 taskId) external;

    function getQuote(address tokenIn, uint256 amountIn) external view returns (uint256 estimatedOut);

    function getRoute(address tokenIn) external view returns (SwapRoute memory);

    function isTokenSupported(address tokenIn) external view returns (bool);
}
