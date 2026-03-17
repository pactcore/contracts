// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PactDev} from "../src/PactDev.sol";
import {IPactDev} from "../src/interfaces/IPactDev.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

contract PactDevTest is Test {
    PactDev public dev;
    MockUSDC public usdc;

    address owner = address(this);
    address treasury = makeAddr("treasury");
    address developer1 = makeAddr("developer1");
    address developer2 = makeAddr("developer2");
    address buyer1 = makeAddr("buyer1");
    address buyer2 = makeAddr("buyer2");
    address nobody = makeAddr("nobody");

    uint256 constant INITIAL_BALANCE = 1_000_000e6; // 1M USDC
    uint256 constant PLUGIN_PRICE = 100e6; // 100 USDC
    bytes32 constant META_HASH = keccak256("ipfs://QmPlugin1");
    bytes32 constant META_HASH_2 = keccak256("ipfs://QmPlugin2");

    function setUp() public {
        usdc = new MockUSDC();
        dev = new PactDev(address(usdc), treasury);

        usdc.mint(buyer1, INITIAL_BALANCE);
        usdc.mint(buyer2, INITIAL_BALANCE);

        vm.prank(buyer1);
        usdc.approve(address(dev), type(uint256).max);
        vm.prank(buyer2);
        usdc.approve(address(dev), type(uint256).max);
    }

    // ═══════════════════════════════════════════════════════════════
    //  Constructor
    // ═══════════════════════════════════════════════════════════════

    function test_constructor_sets_state() public view {
        assertEq(address(dev.usdc()), address(usdc));
        assertEq(dev.treasury(), treasury);
    }

    function test_constructor_reverts_zero_usdc() public {
        vm.expectRevert(PactDev.ZeroAddress.selector);
        new PactDev(address(0), treasury);
    }

    function test_constructor_reverts_zero_treasury() public {
        vm.expectRevert(PactDev.ZeroAddress.selector);
        new PactDev(address(usdc), address(0));
    }

    // ═══════════════════════════════════════════════════════════════
    //  Admin — setTreasury
    // ═══════════════════════════════════════════════════════════════

    function test_setTreasury() public {
        address newTreasury = makeAddr("newTreasury");
        dev.setTreasury(newTreasury);
        assertEq(dev.treasury(), newTreasury);
    }

    function test_setTreasury_reverts_zero() public {
        vm.expectRevert(PactDev.ZeroAddress.selector);
        dev.setTreasury(address(0));
    }

    function test_setTreasury_onlyOwner() public {
        vm.prank(nobody);
        vm.expectRevert();
        dev.setTreasury(makeAddr("t"));
    }

    // ═══════════════════════════════════════════════════════════════
    //  Plugin Registration
    // ═══════════════════════════════════════════════════════════════

    function test_registerPlugin() public {
        vm.prank(developer1);
        uint256 id = dev.registerPlugin("MyPlugin", META_HASH);
        assertEq(id, 1);

        IPactDev.Plugin memory p = dev.getPlugin(id);
        assertEq(p.developer, developer1);
        assertEq(p.metadataHash, META_HASH);
        assertEq(p.name, "MyPlugin");
        assertEq(p.price, 0);
        assertTrue(p.status == IPactDev.PluginStatus.Draft);
        assertEq(p.totalInstalls, 0);
        assertEq(p.totalRevenue, 0);
    }

    function test_registerPlugin_emits_event() public {
        vm.prank(developer1);
        vm.expectEmit(true, true, false, true);
        emit IPactDev.PluginRegistered(1, developer1, "MyPlugin", META_HASH);
        dev.registerPlugin("MyPlugin", META_HASH);
    }

    function test_registerPlugin_increments_id() public {
        vm.startPrank(developer1);
        uint256 id1 = dev.registerPlugin("Plugin1", META_HASH);
        uint256 id2 = dev.registerPlugin("Plugin2", META_HASH_2);
        vm.stopPrank();
        assertEq(id1, 1);
        assertEq(id2, 2);
    }

    function test_registerPlugin_reverts_empty_name() public {
        vm.prank(developer1);
        vm.expectRevert(PactDev.EmptyName.selector);
        dev.registerPlugin("", META_HASH);
    }

    // ═══════════════════════════════════════════════════════════════
    //  Publish Plugin
    // ═══════════════════════════════════════════════════════════════

    function test_publishPlugin() public {
        vm.startPrank(developer1);
        uint256 id = dev.registerPlugin("MyPlugin", META_HASH);
        dev.publishPlugin(id, PLUGIN_PRICE);
        vm.stopPrank();

        IPactDev.Plugin memory p = dev.getPlugin(id);
        assertEq(p.price, PLUGIN_PRICE);
        assertTrue(p.status == IPactDev.PluginStatus.Published);
    }

    function test_publishPlugin_free() public {
        vm.startPrank(developer1);
        uint256 id = dev.registerPlugin("FreeTool", META_HASH);
        dev.publishPlugin(id, 0); // free plugin
        vm.stopPrank();

        IPactDev.Plugin memory p = dev.getPlugin(id);
        assertEq(p.price, 0);
        assertTrue(p.status == IPactDev.PluginStatus.Published);
    }

    function test_publishPlugin_emits_event() public {
        vm.startPrank(developer1);
        uint256 id = dev.registerPlugin("MyPlugin", META_HASH);
        vm.expectEmit(true, false, false, true);
        emit IPactDev.PluginPublished(id, PLUGIN_PRICE);
        dev.publishPlugin(id, PLUGIN_PRICE);
        vm.stopPrank();
    }

    function test_publishPlugin_reverts_not_developer() public {
        vm.prank(developer1);
        uint256 id = dev.registerPlugin("MyPlugin", META_HASH);

        vm.prank(developer2);
        vm.expectRevert(PactDev.Unauthorized.selector);
        dev.publishPlugin(id, PLUGIN_PRICE);
    }

    function test_publishPlugin_reverts_already_published() public {
        vm.startPrank(developer1);
        uint256 id = dev.registerPlugin("MyPlugin", META_HASH);
        dev.publishPlugin(id, PLUGIN_PRICE);

        vm.expectRevert(PactDev.NotDraft.selector);
        dev.publishPlugin(id, PLUGIN_PRICE);
        vm.stopPrank();
    }

    function test_publishPlugin_reverts_not_found() public {
        vm.prank(developer1);
        vm.expectRevert(PactDev.PluginNotFound.selector);
        dev.publishPlugin(999, PLUGIN_PRICE);
    }

    // ═══════════════════════════════════════════════════════════════
    //  Update Plugin
    // ═══════════════════════════════════════════════════════════════

    function test_updatePlugin_draft() public {
        vm.startPrank(developer1);
        uint256 id = dev.registerPlugin("MyPlugin", META_HASH);
        dev.updatePlugin(id, META_HASH_2, 50e6);
        vm.stopPrank();

        IPactDev.Plugin memory p = dev.getPlugin(id);
        assertEq(p.metadataHash, META_HASH_2);
        assertEq(p.price, 50e6);
    }

    function test_updatePlugin_published() public {
        vm.startPrank(developer1);
        uint256 id = dev.registerPlugin("MyPlugin", META_HASH);
        dev.publishPlugin(id, PLUGIN_PRICE);
        dev.updatePlugin(id, META_HASH_2, 200e6);
        vm.stopPrank();

        IPactDev.Plugin memory p = dev.getPlugin(id);
        assertEq(p.metadataHash, META_HASH_2);
        assertEq(p.price, 200e6);
    }

    function test_updatePlugin_emits_event() public {
        vm.startPrank(developer1);
        uint256 id = dev.registerPlugin("MyPlugin", META_HASH);
        vm.expectEmit(true, false, false, true);
        emit IPactDev.PluginUpdated(id, META_HASH_2, 50e6);
        dev.updatePlugin(id, META_HASH_2, 50e6);
        vm.stopPrank();
    }

    function test_updatePlugin_reverts_deprecated() public {
        vm.startPrank(developer1);
        uint256 id = dev.registerPlugin("MyPlugin", META_HASH);
        dev.publishPlugin(id, PLUGIN_PRICE);
        dev.deprecatePlugin(id);

        vm.expectRevert(PactDev.PluginDeprecatedError.selector);
        dev.updatePlugin(id, META_HASH_2, 50e6);
        vm.stopPrank();
    }

    function test_updatePlugin_reverts_not_developer() public {
        vm.prank(developer1);
        uint256 id = dev.registerPlugin("MyPlugin", META_HASH);

        vm.prank(developer2);
        vm.expectRevert(PactDev.Unauthorized.selector);
        dev.updatePlugin(id, META_HASH_2, 50e6);
    }

    // ═══════════════════════════════════════════════════════════════
    //  Deprecate Plugin
    // ═══════════════════════════════════════════════════════════════

    function test_deprecatePlugin() public {
        vm.startPrank(developer1);
        uint256 id = dev.registerPlugin("MyPlugin", META_HASH);
        dev.publishPlugin(id, PLUGIN_PRICE);
        dev.deprecatePlugin(id);
        vm.stopPrank();

        IPactDev.Plugin memory p = dev.getPlugin(id);
        assertTrue(p.status == IPactDev.PluginStatus.Deprecated);
    }

    function test_deprecatePlugin_emits_event() public {
        vm.startPrank(developer1);
        uint256 id = dev.registerPlugin("MyPlugin", META_HASH);
        vm.expectEmit(true, false, false, false);
        emit IPactDev.PluginDeprecated(id);
        dev.deprecatePlugin(id);
        vm.stopPrank();
    }

    function test_deprecatePlugin_reverts_not_developer() public {
        vm.prank(developer1);
        uint256 id = dev.registerPlugin("MyPlugin", META_HASH);

        vm.prank(nobody);
        vm.expectRevert(PactDev.Unauthorized.selector);
        dev.deprecatePlugin(id);
    }

    // ═══════════════════════════════════════════════════════════════
    //  Purchase — Paid Plugin
    // ═══════════════════════════════════════════════════════════════

    function test_purchasePlugin_paid() public {
        vm.startPrank(developer1);
        uint256 id = dev.registerPlugin("PaidPlugin", META_HASH);
        dev.publishPlugin(id, PLUGIN_PRICE);
        vm.stopPrank();

        uint256 devBalBefore = usdc.balanceOf(developer1);
        uint256 treasuryBalBefore = usdc.balanceOf(treasury);
        uint256 buyerBalBefore = usdc.balanceOf(buyer1);

        vm.prank(buyer1);
        dev.purchasePlugin(id);

        // 80/20 split of 100 USDC
        uint256 expectedDev = (PLUGIN_PRICE * 8000) / 10_000; // 80 USDC
        uint256 expectedProtocol = PLUGIN_PRICE - expectedDev; // 20 USDC

        assertEq(usdc.balanceOf(developer1), devBalBefore + expectedDev);
        assertEq(usdc.balanceOf(treasury), treasuryBalBefore + expectedProtocol);
        assertEq(usdc.balanceOf(buyer1), buyerBalBefore - PLUGIN_PRICE);

        assertTrue(dev.hasPurchased(id, buyer1));

        IPactDev.Plugin memory p = dev.getPlugin(id);
        assertEq(p.totalInstalls, 1);
        assertEq(p.totalRevenue, PLUGIN_PRICE);
        assertEq(dev.developerEarnings(developer1), expectedDev);
    }

    function test_purchasePlugin_emits_event() public {
        vm.startPrank(developer1);
        uint256 id = dev.registerPlugin("PaidPlugin", META_HASH);
        dev.publishPlugin(id, PLUGIN_PRICE);
        vm.stopPrank();

        uint256 expectedDev = (PLUGIN_PRICE * 8000) / 10_000;
        uint256 expectedProtocol = PLUGIN_PRICE - expectedDev;

        vm.prank(buyer1);
        vm.expectEmit(true, true, false, true);
        emit IPactDev.PluginPurchased(id, buyer1, PLUGIN_PRICE, expectedDev, expectedProtocol);
        dev.purchasePlugin(id);
    }

    function test_purchasePlugin_multiple_buyers() public {
        vm.startPrank(developer1);
        uint256 id = dev.registerPlugin("MultiPlugin", META_HASH);
        dev.publishPlugin(id, PLUGIN_PRICE);
        vm.stopPrank();

        vm.prank(buyer1);
        dev.purchasePlugin(id);

        vm.prank(buyer2);
        dev.purchasePlugin(id);

        IPactDev.Plugin memory p = dev.getPlugin(id);
        assertEq(p.totalInstalls, 2);
        assertEq(p.totalRevenue, PLUGIN_PRICE * 2);
    }

    // ═══════════════════════════════════════════════════════════════
    //  Purchase — Free Plugin
    // ═══════════════════════════════════════════════════════════════

    function test_purchasePlugin_free() public {
        vm.startPrank(developer1);
        uint256 id = dev.registerPlugin("FreePlugin", META_HASH);
        dev.publishPlugin(id, 0);
        vm.stopPrank();

        uint256 buyerBalBefore = usdc.balanceOf(buyer1);

        vm.prank(buyer1);
        dev.purchasePlugin(id);

        // No USDC transferred
        assertEq(usdc.balanceOf(buyer1), buyerBalBefore);
        assertTrue(dev.hasPurchased(id, buyer1));

        IPactDev.Plugin memory p = dev.getPlugin(id);
        assertEq(p.totalInstalls, 1);
        assertEq(p.totalRevenue, 0);
    }

    // ═══════════════════════════════════════════════════════════════
    //  Purchase — Reverts
    // ═══════════════════════════════════════════════════════════════

    function test_purchasePlugin_reverts_not_published() public {
        vm.prank(developer1);
        uint256 id = dev.registerPlugin("DraftPlugin", META_HASH);

        vm.prank(buyer1);
        vm.expectRevert(PactDev.PluginNotPublished.selector);
        dev.purchasePlugin(id);
    }

    function test_purchasePlugin_reverts_deprecated() public {
        vm.startPrank(developer1);
        uint256 id = dev.registerPlugin("DepPlugin", META_HASH);
        dev.publishPlugin(id, PLUGIN_PRICE);
        dev.deprecatePlugin(id);
        vm.stopPrank();

        vm.prank(buyer1);
        vm.expectRevert(PactDev.PluginNotPublished.selector);
        dev.purchasePlugin(id);
    }

    function test_purchasePlugin_reverts_already_purchased() public {
        vm.startPrank(developer1);
        uint256 id = dev.registerPlugin("PaidPlugin", META_HASH);
        dev.publishPlugin(id, PLUGIN_PRICE);
        vm.stopPrank();

        vm.prank(buyer1);
        dev.purchasePlugin(id);

        vm.prank(buyer1);
        vm.expectRevert(PactDev.AlreadyPurchased.selector);
        dev.purchasePlugin(id);
    }

    function test_purchasePlugin_reverts_not_found() public {
        vm.prank(buyer1);
        vm.expectRevert(PactDev.PluginNotFound.selector);
        dev.purchasePlugin(999);
    }

    // ═══════════════════════════════════════════════════════════════
    //  Views
    // ═══════════════════════════════════════════════════════════════

    function test_hasPurchased_false_initially() public view {
        assertFalse(dev.hasPurchased(1, buyer1));
    }

    function test_developerEarnings_zero_initially() public view {
        assertEq(dev.developerEarnings(developer1), 0);
    }

    function test_getPlugin_reverts_not_found() public {
        vm.expectRevert(PactDev.PluginNotFound.selector);
        dev.getPlugin(999);
    }

    // ═══════════════════════════════════════════════════════════════
    //  Revenue Split Accuracy
    // ═══════════════════════════════════════════════════════════════

    function test_revenue_split_odd_amount() public {
        // Use a price that doesn't split evenly
        uint256 oddPrice = 99e6; // 99 USDC
        vm.startPrank(developer1);
        uint256 id = dev.registerPlugin("OddPlugin", META_HASH);
        dev.publishPlugin(id, oddPrice);
        vm.stopPrank();

        uint256 devBalBefore = usdc.balanceOf(developer1);
        uint256 treasuryBalBefore = usdc.balanceOf(treasury);

        vm.prank(buyer1);
        dev.purchasePlugin(id);

        uint256 expectedDev = (oddPrice * 8000) / 10_000; // 79.2 USDC = 79200000
        uint256 expectedProtocol = oddPrice - expectedDev; // 19.8 USDC = 19800000

        assertEq(usdc.balanceOf(developer1), devBalBefore + expectedDev);
        assertEq(usdc.balanceOf(treasury), treasuryBalBefore + expectedProtocol);
        // Ensure no dust: dev + protocol == gross
        assertEq(expectedDev + expectedProtocol, oddPrice);
    }

    function test_revenue_cumulative_across_plugins() public {
        vm.startPrank(developer1);
        uint256 id1 = dev.registerPlugin("Plugin1", META_HASH);
        dev.publishPlugin(id1, 100e6);
        uint256 id2 = dev.registerPlugin("Plugin2", META_HASH_2);
        dev.publishPlugin(id2, 200e6);
        vm.stopPrank();

        vm.prank(buyer1);
        dev.purchasePlugin(id1);
        vm.prank(buyer1);
        dev.purchasePlugin(id2);

        // 80e6 + 160e6 = 240e6
        assertEq(dev.developerEarnings(developer1), 240e6);
    }

    // ═══════════════════════════════════════════════════════════════
    //  Constants
    // ═══════════════════════════════════════════════════════════════

    function test_bps_constants() public view {
        assertEq(dev.DEVELOPER_BPS(), 8000);
        assertEq(dev.PROTOCOL_BPS(), 2000);
        assertEq(dev.DEVELOPER_BPS() + dev.PROTOCOL_BPS(), 10_000);
    }

    // ═══════════════════════════════════════════════════════════════
    //  End-to-End: Full lifecycle
    // ═══════════════════════════════════════════════════════════════

    function test_full_lifecycle() public {
        // 1. Register
        vm.prank(developer1);
        uint256 id = dev.registerPlugin("LifecyclePlugin", META_HASH);
        assertTrue(dev.getPlugin(id).status == IPactDev.PluginStatus.Draft);

        // 2. Publish
        vm.prank(developer1);
        dev.publishPlugin(id, PLUGIN_PRICE);
        assertTrue(dev.getPlugin(id).status == IPactDev.PluginStatus.Published);

        // 3. Purchase
        vm.prank(buyer1);
        dev.purchasePlugin(id);
        assertTrue(dev.hasPurchased(id, buyer1));

        // 4. Update price
        vm.prank(developer1);
        dev.updatePlugin(id, META_HASH_2, 200e6);
        assertEq(dev.getPlugin(id).price, 200e6);

        // 5. Another buyer at new price
        vm.prank(buyer2);
        dev.purchasePlugin(id);
        assertEq(dev.getPlugin(id).totalInstalls, 2);
        assertEq(dev.getPlugin(id).totalRevenue, PLUGIN_PRICE + 200e6);

        // 6. Deprecate
        vm.prank(developer1);
        dev.deprecatePlugin(id);
        assertTrue(dev.getPlugin(id).status == IPactDev.PluginStatus.Deprecated);

        // 7. Can't purchase deprecated
        vm.prank(nobody);
        vm.expectRevert(PactDev.PluginNotPublished.selector);
        dev.purchasePlugin(id);
    }
}
