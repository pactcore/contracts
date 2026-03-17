// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {PactAutoSwap, ISwapRouter, IQuoter} from "../src/PactAutoSwap.sol";
import {IPactAutoSwap} from "../src/interfaces/IPactAutoSwap.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

// ── Mock USDC ──────────────────────────────────────────────
contract MockERC20 is IERC20 {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "insufficient");
        require(allowance[from][msg.sender] >= amount, "not approved");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}

// ── Mock Swap Router ───────────────────────────────────────
contract MockSwapRouter is ISwapRouter {
    // Configurable exchange rate: amountOut = amountIn * rate / 1e18
    uint256 public rate = 1e18; // default 1:1
    bool public shouldRevert;

    function setRate(uint256 newRate) external {
        rate = newRate;
    }

    function setRevert(bool flag) external {
        shouldRevert = flag;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external returns (uint256 amountOut) {
        require(!shouldRevert, "mock revert");

        // Pull tokenIn from sender
        IERC20(params.tokenIn).transferFrom(msg.sender, address(this), params.amountIn);

        // Calculate output
        amountOut = (params.amountIn * rate) / 1e18;

        // Mint USDC to recipient (mock: just transfer from our balance)
        MockERC20(params.tokenOut).mint(params.recipient, amountOut);
    }
}

// ── Mock Quoter ─────────────────────────────────────────────
contract MockQuoter is IQuoter {
    uint256 public rate = 1e18;

    function setRate(uint256 newRate) external {
        rate = newRate;
    }

    function quoteExactInputSingle(address, address, uint24, uint256 amountIn, uint160)
        external
        view
        returns (uint256)
    {
        return (amountIn * rate) / 1e18;
    }
}

// ── Tests ───────────────────────────────────────────────────
contract PactAutoSwapTest is Test {
    PactAutoSwap autoSwap;
    MockERC20 usdc;
    MockERC20 weth;
    MockERC20 dai;
    MockSwapRouter router;
    MockQuoter quoter;

    address owner = address(this);
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint24 constant POOL_FEE = 3000; // 0.3%

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        dai = new MockERC20("DAI", "DAI", 18);
        router = new MockSwapRouter();
        quoter = new MockQuoter();

        autoSwap = new PactAutoSwap(address(usdc), address(router), address(quoter), 50); // 0.5% slippage

        // Configure WETH route
        autoSwap.configureRoute(address(weth), POOL_FEE, true);
    }

    // ──────── Constructor ────────

    function test_constructor_setsValues() public view {
        assertEq(address(autoSwap.usdc()), address(usdc));
        assertEq(address(autoSwap.swapRouter()), address(router));
        assertEq(autoSwap.defaultSlippageBps(), 50);
    }

    function test_constructor_revertsZeroUsdc() public {
        vm.expectRevert(IPactAutoSwap.ZeroAddress.selector);
        new PactAutoSwap(address(0), address(router), address(quoter), 50);
    }

    function test_constructor_revertsZeroRouter() public {
        vm.expectRevert(IPactAutoSwap.ZeroAddress.selector);
        new PactAutoSwap(address(usdc), address(0), address(quoter), 50);
    }

    function test_constructor_revertsInvalidSlippage() public {
        vm.expectRevert(IPactAutoSwap.InvalidSlippage.selector);
        new PactAutoSwap(address(usdc), address(router), address(quoter), 2001);
    }

    // ──────── Admin: configureRoute ────────

    function test_configureRoute_basic() public {
        autoSwap.configureRoute(address(dai), 500, true);

        IPactAutoSwap.SwapRoute memory route = autoSwap.getRoute(address(dai));
        assertEq(route.tokenIn, address(dai));
        assertEq(route.poolFee, 500);
        assertTrue(route.enabled);
        assertTrue(autoSwap.isTokenSupported(address(dai)));
    }

    function test_configureRoute_disable() public {
        autoSwap.configureRoute(address(dai), 500, true);
        autoSwap.configureRoute(address(dai), 500, false);

        assertFalse(autoSwap.isTokenSupported(address(dai)));
    }

    function test_configureRoute_revertsZeroAddress() public {
        vm.expectRevert(IPactAutoSwap.ZeroAddress.selector);
        autoSwap.configureRoute(address(0), 500, true);
    }

    function test_configureRoute_revertsNonOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        autoSwap.configureRoute(address(dai), 500, true);
    }

    function test_configureRoute_emitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit IPactAutoSwap.RouteConfigured(address(dai), 500, true);
        autoSwap.configureRoute(address(dai), 500, true);
    }

    // ──────── Admin: setDefaultSlippage ────────

    function test_setDefaultSlippage() public {
        autoSwap.setDefaultSlippage(100);
        assertEq(autoSwap.defaultSlippageBps(), 100);
    }

    function test_setDefaultSlippage_revertsOverMax() public {
        vm.expectRevert(IPactAutoSwap.InvalidSlippage.selector);
        autoSwap.setDefaultSlippage(2001);
    }

    function test_setDefaultSlippage_emitsEvent() public {
        vm.expectEmit(false, false, false, true);
        emit IPactAutoSwap.SlippageUpdated(50, 200);
        autoSwap.setDefaultSlippage(200);
    }

    // ──────── Admin: setSwapRouter ────────

    function test_setSwapRouter() public {
        MockSwapRouter newRouter = new MockSwapRouter();
        autoSwap.setSwapRouter(address(newRouter));
        assertEq(address(autoSwap.swapRouter()), address(newRouter));
    }

    function test_setSwapRouter_revertsZeroAddress() public {
        vm.expectRevert(IPactAutoSwap.ZeroAddress.selector);
        autoSwap.setSwapRouter(address(0));
    }

    function test_setSwapRouter_emitsEvent() public {
        MockSwapRouter newRouter = new MockSwapRouter();
        vm.expectEmit(false, false, false, true);
        emit IPactAutoSwap.SwapRouterUpdated(address(router), address(newRouter));
        autoSwap.setSwapRouter(address(newRouter));
    }

    // ──────── Admin: setEscrow ────────

    function test_setEscrow() public {
        autoSwap.setEscrow(address(0xBEEF));
        assertEq(autoSwap.escrow(), address(0xBEEF));
    }

    // ──────── Swap ────────

    function test_swap_basic() public {
        uint256 amount = 1 ether;
        weth.mint(alice, amount);

        vm.startPrank(alice);
        weth.approve(address(autoSwap), amount);
        uint256 out = autoSwap.swap(address(weth), amount, 0, bytes32("ref1"));
        vm.stopPrank();

        assertEq(out, amount); // 1:1 rate
        assertEq(usdc.balanceOf(alice), amount);
        assertEq(weth.balanceOf(alice), 0);
    }

    function test_swap_withRate() public {
        router.setRate(2e18); // 1 WETH = 2 USDC
        uint256 amount = 1 ether;
        weth.mint(alice, amount);

        vm.startPrank(alice);
        weth.approve(address(autoSwap), amount);
        uint256 out = autoSwap.swap(address(weth), amount, 0, bytes32("rate2"));
        vm.stopPrank();

        assertEq(out, 2 ether);
        assertEq(usdc.balanceOf(alice), 2 ether);
    }

    function test_swap_respectsMinAmountOut() public {
        router.setRate(0.5e18); // 1 WETH = 0.5 USDC
        uint256 amount = 1 ether;
        weth.mint(alice, amount);

        vm.startPrank(alice);
        weth.approve(address(autoSwap), amount);

        // minAmountOut = 0.6 ether, but swap returns 0.5 → revert
        vm.expectRevert(); // Router's own minimum check
        autoSwap.swap(address(weth), amount, 0.6 ether, bytes32("slip"));
        vm.stopPrank();
    }

    function test_swap_revertsZeroAmount() public {
        vm.startPrank(alice);
        vm.expectRevert(IPactAutoSwap.InvalidAmount.selector);
        autoSwap.swap(address(weth), 0, 0, bytes32("zero"));
        vm.stopPrank();
    }

    function test_swap_revertsUnsupportedToken() public {
        vm.startPrank(alice);
        vm.expectRevert(IPactAutoSwap.TokenNotSupported.selector);
        autoSwap.swap(address(dai), 1 ether, 0, bytes32("unsup"));
        vm.stopPrank();
    }

    function test_swap_emitsEvent() public {
        uint256 amount = 1 ether;
        weth.mint(alice, amount);

        vm.startPrank(alice);
        weth.approve(address(autoSwap), amount);

        vm.expectEmit(true, true, true, true);
        emit IPactAutoSwap.SwapExecuted(alice, address(weth), amount, amount, bytes32("evt1"));
        autoSwap.swap(address(weth), amount, 0, bytes32("evt1"));
        vm.stopPrank();
    }

    // ──────── SwapToEscrow ────────

    function test_swapToEscrow_basic() public {
        autoSwap.setEscrow(address(0xBEEF));

        uint256 amount = 1 ether;
        weth.mint(alice, amount);

        vm.startPrank(alice);
        weth.approve(address(autoSwap), amount);
        autoSwap.swapToEscrow(address(weth), amount, 0, 42);
        vm.stopPrank();

        // USDC transferred to alice (for subsequent escrow deposit)
        assertEq(usdc.balanceOf(alice), amount);
    }

    function test_swapToEscrow_revertsNoEscrow() public {
        uint256 amount = 1 ether;
        weth.mint(alice, amount);

        vm.startPrank(alice);
        weth.approve(address(autoSwap), amount);
        vm.expectRevert(IPactAutoSwap.ZeroAddress.selector);
        autoSwap.swapToEscrow(address(weth), amount, 0, 42);
        vm.stopPrank();
    }

    function test_swapToEscrow_emitsEvent() public {
        autoSwap.setEscrow(address(0xBEEF));
        uint256 amount = 2 ether;
        weth.mint(alice, amount);

        vm.startPrank(alice);
        weth.approve(address(autoSwap), amount);

        vm.expectEmit(true, true, true, true);
        emit IPactAutoSwap.SwapExecuted(alice, address(weth), amount, amount, bytes32(uint256(99)));
        autoSwap.swapToEscrow(address(weth), amount, 0, 99);
        vm.stopPrank();
    }

    // ──────── Views ────────

    function test_getQuote_basic() public view {
        uint256 quote = autoSwap.getQuote(address(weth), 1 ether);
        assertEq(quote, 1 ether); // placeholder 1:1
    }

    function test_getQuote_revertsUnsupported() public {
        vm.expectRevert(IPactAutoSwap.TokenNotSupported.selector);
        autoSwap.getQuote(address(dai), 1 ether);
    }

    function test_getQuote_revertsZeroAmount() public {
        vm.expectRevert(IPactAutoSwap.InvalidAmount.selector);
        autoSwap.getQuote(address(weth), 0);
    }

    function test_isTokenSupported_true() public view {
        assertTrue(autoSwap.isTokenSupported(address(weth)));
    }

    function test_isTokenSupported_false() public view {
        assertFalse(autoSwap.isTokenSupported(address(dai)));
    }

    function test_getSupportedTokens() public {
        autoSwap.configureRoute(address(dai), 500, true);

        address[] memory tokens = autoSwap.getSupportedTokens();
        assertEq(tokens.length, 2);
        assertEq(tokens[0], address(weth));
        assertEq(tokens[1], address(dai));
    }

    function test_getRoute_unconfigured() public view {
        IPactAutoSwap.SwapRoute memory route = autoSwap.getRoute(address(dai));
        assertEq(route.tokenIn, address(0));
        assertFalse(route.enabled);
    }

    // ──────── Multiple token routes ────────

    function test_multipleRoutes() public {
        autoSwap.configureRoute(address(dai), 100, true);

        uint256 wethAmount = 1 ether;
        uint256 daiAmount = 500 ether;

        weth.mint(alice, wethAmount);
        dai.mint(alice, daiAmount);

        vm.startPrank(alice);
        weth.approve(address(autoSwap), wethAmount);
        dai.approve(address(autoSwap), daiAmount);

        uint256 out1 = autoSwap.swap(address(weth), wethAmount, 0, bytes32("multi1"));
        uint256 out2 = autoSwap.swap(address(dai), daiAmount, 0, bytes32("multi2"));
        vm.stopPrank();

        assertEq(out1, wethAmount);
        assertEq(out2, daiAmount);
        assertEq(usdc.balanceOf(alice), wethAmount + daiAmount);
    }

    // ──────── Disabled route ────────

    function test_swap_revertsDisabledRoute() public {
        autoSwap.configureRoute(address(weth), POOL_FEE, false);

        weth.mint(alice, 1 ether);
        vm.startPrank(alice);
        weth.approve(address(autoSwap), 1 ether);

        vm.expectRevert(IPactAutoSwap.TokenNotSupported.selector);
        autoSwap.swap(address(weth), 1 ether, 0, bytes32("disabled"));
        vm.stopPrank();
    }

    // ──────── Re-enable route ────────

    function test_configureRoute_reEnable() public {
        autoSwap.configureRoute(address(weth), POOL_FEE, false);
        assertFalse(autoSwap.isTokenSupported(address(weth)));

        autoSwap.configureRoute(address(weth), 500, true); // new fee
        assertTrue(autoSwap.isTokenSupported(address(weth)));

        IPactAutoSwap.SwapRoute memory route = autoSwap.getRoute(address(weth));
        assertEq(route.poolFee, 500);
    }

    // ──────── Edge: max slippage boundary ────────

    function test_setDefaultSlippage_maxAllowed() public {
        autoSwap.setDefaultSlippage(2000); // exactly 20%
        assertEq(autoSwap.defaultSlippageBps(), 2000);
    }

    function test_setDefaultSlippage_zero() public {
        autoSwap.setDefaultSlippage(0); // 0% slippage = exact output required
        assertEq(autoSwap.defaultSlippageBps(), 0);
    }
}
