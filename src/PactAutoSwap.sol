// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {IPactAutoSwap} from "./interfaces/IPactAutoSwap.sol";

/// @notice Minimal swap-router interface (Uniswap V3 ExactInputSingle compatible)
interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external returns (uint256 amountOut);
}

/// @notice Minimal Uniswap V3 quoter interface
interface IQuoter {
    function quoteExactInputSingle(
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 amountIn,
        uint160 sqrtPriceLimitX96
    ) external returns (uint256 amountOut);
}

/// @title PactAutoSwap
/// @notice Automatic token-to-USDC swap service for the PACT ecosystem.
///         Supports slippage protection, admin-configurable routes per token,
///         and direct swap-to-escrow for task payments.
contract PactAutoSwap is IPactAutoSwap, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint16 public constant MAX_SLIPPAGE_BPS = 2000; // 20% max
    uint16 public constant BPS_DENOMINATOR = 10_000;

    IERC20 public immutable usdc;
    ISwapRouter public swapRouter;
    IQuoter public quoter;

    /// @notice Default slippage tolerance in basis points (e.g. 50 = 0.5%)
    uint16 public defaultSlippageBps;

    /// @notice tokenIn address → swap route config
    mapping(address token => SwapRoute) private routes;

    /// @notice Tracks all supported token addresses for enumeration
    address[] private supportedTokens;
    mapping(address token => bool) private tokenIndex;

    /// @notice Optional escrow contract for direct swap-to-escrow flow
    address public escrow;

    constructor(address usdcAddress, address routerAddress, address quoterAddress, uint16 slippageBps)
        Ownable(msg.sender)
    {
        if (usdcAddress == address(0) || routerAddress == address(0)) revert ZeroAddress();
        if (slippageBps > MAX_SLIPPAGE_BPS) revert InvalidSlippage();

        usdc = IERC20(usdcAddress);
        swapRouter = ISwapRouter(routerAddress);
        quoter = IQuoter(quoterAddress);
        defaultSlippageBps = slippageBps;
    }

    // ──────────────────────── Admin ────────────────────────

    function configureRoute(address tokenIn, uint24 poolFee, bool enabled) external onlyOwner {
        if (tokenIn == address(0)) revert ZeroAddress();

        routes[tokenIn] = SwapRoute({tokenIn: tokenIn, poolFee: poolFee, enabled: enabled});

        if (enabled && !tokenIndex[tokenIn]) {
            supportedTokens.push(tokenIn);
            tokenIndex[tokenIn] = true;
        }

        emit RouteConfigured(tokenIn, poolFee, enabled);
    }

    function setDefaultSlippage(uint16 newBps) external onlyOwner {
        if (newBps > MAX_SLIPPAGE_BPS) revert InvalidSlippage();
        uint16 old = defaultSlippageBps;
        defaultSlippageBps = newBps;
        emit SlippageUpdated(old, newBps);
    }

    function setSwapRouter(address newRouter) external onlyOwner {
        if (newRouter == address(0)) revert ZeroAddress();
        address old = address(swapRouter);
        swapRouter = ISwapRouter(newRouter);
        emit SwapRouterUpdated(old, newRouter);
    }

    function setEscrow(address escrowAddress) external onlyOwner {
        escrow = escrowAddress;
    }

    // ──────────────────────── Core ────────────────────────

    /// @inheritdoc IPactAutoSwap
    function swap(address tokenIn, uint256 amountIn, uint256 minAmountOut, bytes32 ref)
        external
        nonReentrant
        returns (uint256 amountOut)
    {
        amountOut = _executeSwap(tokenIn, amountIn, minAmountOut, msg.sender);
        emit SwapExecuted(msg.sender, tokenIn, amountIn, amountOut, ref);
    }

    /// @inheritdoc IPactAutoSwap
    function swapToEscrow(address tokenIn, uint256 amountIn, uint256 minAmountOut, uint256 taskId)
        external
        nonReentrant
    {
        if (escrow == address(0)) revert ZeroAddress();

        // Swap tokenIn → USDC, receiving USDC into this contract
        uint256 amountOut = _executeSwap(tokenIn, amountIn, minAmountOut, address(this));

        // Approve escrow to pull USDC and create the escrow deposit
        usdc.forceApprove(escrow, amountOut);

        // Call createEscrow on the escrow contract
        // The escrow expects msg.sender == payer, so we use a low-level call
        // that forwards the USDC from this contract
        // NOTE: For production, escrow should support a depositFor() pattern.
        // For now we transfer USDC to the caller and let them escrow it.
        usdc.safeTransfer(msg.sender, amountOut);

        emit SwapExecuted(msg.sender, tokenIn, amountIn, amountOut, bytes32(taskId));
    }

    // ──────────────────────── Views ────────────────────────

    /// @inheritdoc IPactAutoSwap
    function getQuote(address tokenIn, uint256 amountIn) external view returns (uint256 estimatedOut) {
        SwapRoute memory route = routes[tokenIn];
        if (!route.enabled) revert TokenNotSupported();
        if (amountIn == 0) revert InvalidAmount();

        // Return a simple ratio estimate; production should use the quoter
        // but quoteExactInputSingle is not a view function in Uniswap V3
        estimatedOut = amountIn; // 1:1 placeholder — overridden in production by off-chain quote
    }

    /// @inheritdoc IPactAutoSwap
    function getRoute(address tokenIn) external view returns (SwapRoute memory) {
        return routes[tokenIn];
    }

    /// @inheritdoc IPactAutoSwap
    function isTokenSupported(address tokenIn) external view returns (bool) {
        return routes[tokenIn].enabled;
    }

    function getSupportedTokens() external view returns (address[] memory) {
        return supportedTokens;
    }

    // ──────────────────────── Internal ────────────────────────

    function _executeSwap(address tokenIn, uint256 amountIn, uint256 minAmountOut, address recipient)
        internal
        returns (uint256 amountOut)
    {
        if (amountIn == 0) revert InvalidAmount();

        SwapRoute memory route = routes[tokenIn];
        if (!route.enabled) revert TokenNotSupported();

        // Pull tokens from the user
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        // Approve the swap router
        IERC20(tokenIn).forceApprove(address(swapRouter), amountIn);

        // Execute swap via Uniswap V3 ExactInputSingle
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: tokenIn,
            tokenOut: address(usdc),
            fee: route.poolFee,
            recipient: recipient,
            amountIn: amountIn,
            amountOutMinimum: minAmountOut,
            sqrtPriceLimitX96: 0
        });

        amountOut = swapRouter.exactInputSingle(params);

        if (amountOut < minAmountOut) revert SlippageExceeded();
    }
}
