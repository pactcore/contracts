// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PactGasSponsor} from "../src/PactGasSponsor.sol";
import {IPactGasSponsor} from "../src/interfaces/IPactGasSponsor.sol";
import {PactReputation} from "../src/PactReputation.sol";
import {PactIdentitySBT} from "../src/PactIdentitySBT.sol";

contract PactGasSponsorTest is Test {
    PactGasSponsor public sponsor;
    PactReputation public reputation;
    PactIdentitySBT public identity;

    address public admin = address(this);
    address public poolOwner = makeAddr("poolOwner");
    address public relayer = makeAddr("relayer");
    address public user1 = makeAddr("user1");
    address public user2 = makeAddr("user2");
    address public user3 = makeAddr("user3");

    function setUp() public {
        // Deploy deps
        reputation = new PactReputation(30 days, 7 days, 5);
        identity = new PactIdentitySBT();

        // Deploy sponsor
        sponsor = new PactGasSponsor(address(reputation), address(identity));

        // Authorize relayer
        sponsor.setRelayerAuthorization(relayer, true);

        // Fund pool owner
        vm.deal(poolOwner, 100 ether);
        vm.deal(relayer, 1 ether);

        // Set reputation for user1 (Worker role = 0)
        reputation.adjustScore(user1, PactReputation.Role.Worker, 30); // 50 + 30 = 80

        // Mint identity SBT for user1
        identity.mint(user1, 1, "worker", 2);
    }

    // ── Pool creation ────────────────────────────────────────────────────

    function testCreatePool() public {
        vm.prank(poolOwner);
        uint256 poolId = sponsor.createPool{value: 10 ether}("Test Pool", 1 ether, 50, 1, false);

        assertEq(poolId, 1);
        IPactGasSponsor.SponsorPool memory pool = sponsor.getPool(poolId);
        assertEq(pool.owner, poolOwner);
        assertEq(pool.balance, 10 ether);
        assertEq(pool.dailyLimitPerUser, 1 ether);
        assertEq(pool.minReputation, 50);
        assertEq(pool.minIdentityLevel, 1);
        assertFalse(pool.whitelistOnly);
        assertTrue(pool.active);
    }

    function testCreatePoolNoDeposit() public {
        vm.prank(poolOwner);
        uint256 poolId = sponsor.createPool("Empty Pool", 0.5 ether, 0, 0, false);
        IPactGasSponsor.SponsorPool memory pool = sponsor.getPool(poolId);
        assertEq(pool.balance, 0);
    }

    function testMultiplePoolsIndependent() public {
        vm.startPrank(poolOwner);
        uint256 p1 = sponsor.createPool{value: 5 ether}("Pool A", 1 ether, 0, 0, false);
        uint256 p2 = sponsor.createPool{value: 3 ether}("Pool B", 0.5 ether, 0, 0, false);
        vm.stopPrank();

        assertEq(p1, 1);
        assertEq(p2, 2);
        assertEq(sponsor.getPool(p1).balance, 5 ether);
        assertEq(sponsor.getPool(p2).balance, 3 ether);
    }

    // ── Fund pool ────────────────────────────────────────────────────────

    function testFundPool() public {
        vm.prank(poolOwner);
        uint256 poolId = sponsor.createPool{value: 1 ether}("Pool", 1 ether, 0, 0, false);

        vm.deal(user1, 5 ether);
        vm.prank(user1);
        sponsor.fundPool{value: 2 ether}(poolId);

        assertEq(sponsor.getPool(poolId).balance, 3 ether);
    }

    function testFundPoolZeroReverts() public {
        vm.prank(poolOwner);
        uint256 poolId = sponsor.createPool{value: 1 ether}("Pool", 1 ether, 0, 0, false);

        vm.expectRevert(IPactGasSponsor.ZeroAmount.selector);
        sponsor.fundPool(poolId);
    }

    function testFundInactivePoolReverts() public {
        vm.prank(poolOwner);
        uint256 poolId = sponsor.createPool{value: 1 ether}("Pool", 1 ether, 0, 0, false);
        vm.prank(poolOwner);
        sponsor.deactivatePool(poolId);

        vm.deal(user1, 1 ether);
        vm.prank(user1);
        vm.expectRevert(IPactGasSponsor.PoolNotActive.selector);
        sponsor.fundPool{value: 1 ether}(poolId);
    }

    // ── Withdraw ─────────────────────────────────────────────────────────

    function testWithdrawPool() public {
        vm.prank(poolOwner);
        uint256 poolId = sponsor.createPool{value: 5 ether}("Pool", 1 ether, 0, 0, false);

        uint256 balBefore = poolOwner.balance;
        vm.prank(poolOwner);
        sponsor.withdrawPool(poolId, 3 ether);

        assertEq(sponsor.getPool(poolId).balance, 2 ether);
        assertEq(poolOwner.balance, balBefore + 3 ether);
    }

    function testWithdrawNotOwnerReverts() public {
        vm.prank(poolOwner);
        uint256 poolId = sponsor.createPool{value: 5 ether}("Pool", 1 ether, 0, 0, false);

        vm.prank(user1);
        vm.expectRevert(IPactGasSponsor.NotPoolOwner.selector);
        sponsor.withdrawPool(poolId, 1 ether);
    }

    function testWithdrawExcessReverts() public {
        vm.prank(poolOwner);
        uint256 poolId = sponsor.createPool{value: 1 ether}("Pool", 1 ether, 0, 0, false);

        vm.prank(poolOwner);
        vm.expectRevert(IPactGasSponsor.InsufficientPoolBalance.selector);
        sponsor.withdrawPool(poolId, 2 ether);
    }

    function testWithdrawZeroReverts() public {
        vm.prank(poolOwner);
        uint256 poolId = sponsor.createPool{value: 1 ether}("Pool", 1 ether, 0, 0, false);

        vm.prank(poolOwner);
        vm.expectRevert(IPactGasSponsor.ZeroAmount.selector);
        sponsor.withdrawPool(poolId, 0);
    }

    // ── Deactivate ───────────────────────────────────────────────────────

    function testDeactivatePool() public {
        vm.prank(poolOwner);
        uint256 poolId = sponsor.createPool{value: 1 ether}("Pool", 1 ether, 0, 0, false);
        vm.prank(poolOwner);
        sponsor.deactivatePool(poolId);

        assertFalse(sponsor.getPool(poolId).active);
    }

    // ── Whitelist ────────────────────────────────────────────────────────

    function testWhitelistAddRemove() public {
        vm.prank(poolOwner);
        uint256 poolId = sponsor.createPool{value: 1 ether}("Pool", 1 ether, 0, 0, true);

        address[] memory users = new address[](2);
        users[0] = user1;
        users[1] = user2;

        vm.prank(poolOwner);
        sponsor.addToWhitelist(poolId, users);
        assertTrue(sponsor.isWhitelisted(poolId, user1));
        assertTrue(sponsor.isWhitelisted(poolId, user2));
        assertFalse(sponsor.isWhitelisted(poolId, user3));

        address[] memory removeUsers = new address[](1);
        removeUsers[0] = user1;
        vm.prank(poolOwner);
        sponsor.removeFromWhitelist(poolId, removeUsers);
        assertFalse(sponsor.isWhitelisted(poolId, user1));
        assertTrue(sponsor.isWhitelisted(poolId, user2));
    }

    function testWhitelistNotOwnerReverts() public {
        vm.prank(poolOwner);
        uint256 poolId = sponsor.createPool{value: 1 ether}("Pool", 1 ether, 0, 0, true);

        address[] memory users = new address[](1);
        users[0] = user1;

        vm.prank(user1);
        vm.expectRevert(IPactGasSponsor.NotPoolOwner.selector);
        sponsor.addToWhitelist(poolId, users);
    }

    // ── Gas sponsorship ──────────────────────────────────────────────────

    function testSponsorGasEligibleUser() public {
        // Pool with no reputation/identity requirements
        vm.prank(poolOwner);
        uint256 poolId = sponsor.createPool{value: 10 ether}("Open Pool", 1 ether, 0, 0, false);

        uint256 relayerBalBefore = relayer.balance;
        vm.prank(relayer);
        sponsor.sponsorGas(poolId, user1, 0.1 ether);

        assertEq(sponsor.getPool(poolId).balance, 9.9 ether);
        assertEq(relayer.balance, relayerBalBefore + 0.1 ether);
        assertEq(sponsor.getUserDailyUsage(poolId, user1), 0.1 ether);
    }

    function testSponsorGasReputationCheck() public {
        // Pool requires reputation >= 70
        vm.prank(poolOwner);
        uint256 poolId = sponsor.createPool{value: 10 ether}("Rep Pool", 2 ether, 70, 0, false);

        // user1 has 80 rep → eligible
        vm.prank(relayer);
        sponsor.sponsorGas(poolId, user1, 0.1 ether);
        assertEq(sponsor.getUserDailyUsage(poolId, user1), 0.1 ether);

        // user2 has default (50) rep → not eligible
        vm.prank(relayer);
        vm.expectRevert(IPactGasSponsor.NotEligible.selector);
        sponsor.sponsorGas(poolId, user2, 0.1 ether);
    }

    function testSponsorGasIdentityCheck() public {
        // Pool requires identity (minIdentityLevel > 0)
        vm.prank(poolOwner);
        uint256 poolId = sponsor.createPool{value: 10 ether}("ID Pool", 2 ether, 0, 1, false);

        // user1 has SBT → eligible
        vm.prank(relayer);
        sponsor.sponsorGas(poolId, user1, 0.1 ether);

        // user2 has no SBT → not eligible
        vm.prank(relayer);
        vm.expectRevert(IPactGasSponsor.NotEligible.selector);
        sponsor.sponsorGas(poolId, user2, 0.1 ether);
    }

    function testSponsorGasWhitelistOnly() public {
        vm.prank(poolOwner);
        uint256 poolId = sponsor.createPool{value: 10 ether}("WL Pool", 2 ether, 0, 0, true);

        // user1 not whitelisted → reject
        vm.prank(relayer);
        vm.expectRevert(IPactGasSponsor.NotEligible.selector);
        sponsor.sponsorGas(poolId, user1, 0.1 ether);

        // Add to whitelist
        address[] memory users = new address[](1);
        users[0] = user1;
        vm.prank(poolOwner);
        sponsor.addToWhitelist(poolId, users);

        // Now eligible
        vm.prank(relayer);
        sponsor.sponsorGas(poolId, user1, 0.1 ether);
        assertEq(sponsor.getUserDailyUsage(poolId, user1), 0.1 ether);
    }

    function testDailyLimitEnforced() public {
        vm.prank(poolOwner);
        uint256 poolId = sponsor.createPool{value: 10 ether}("Limited", 0.5 ether, 0, 0, false);

        // First use — 0.4 ETH (under limit)
        vm.prank(relayer);
        sponsor.sponsorGas(poolId, user1, 0.4 ether);
        assertEq(sponsor.getUserDailyUsage(poolId, user1), 0.4 ether);

        // Second use — 0.2 ETH would exceed 0.5 daily limit
        vm.prank(relayer);
        vm.expectRevert(IPactGasSponsor.DailyLimitExceeded.selector);
        sponsor.sponsorGas(poolId, user1, 0.2 ether);

        // Exact remaining (0.1) — ok
        vm.prank(relayer);
        sponsor.sponsorGas(poolId, user1, 0.1 ether);
        assertEq(sponsor.getUserDailyUsage(poolId, user1), 0.5 ether);
    }

    function testDailyLimitResetsNextDay() public {
        vm.prank(poolOwner);
        uint256 poolId = sponsor.createPool{value: 10 ether}("Limited", 0.5 ether, 0, 0, false);

        // Use full daily limit
        vm.prank(relayer);
        sponsor.sponsorGas(poolId, user1, 0.5 ether);

        // Exceed
        vm.prank(relayer);
        vm.expectRevert(IPactGasSponsor.DailyLimitExceeded.selector);
        sponsor.sponsorGas(poolId, user1, 0.1 ether);

        // Warp to next day
        vm.warp(block.timestamp + 1 days);

        // Now ok again
        vm.prank(relayer);
        sponsor.sponsorGas(poolId, user1, 0.3 ether);
        assertEq(sponsor.getUserDailyUsage(poolId, user1), 0.3 ether);
    }

    function testNotRelayerReverts() public {
        vm.prank(poolOwner);
        uint256 poolId = sponsor.createPool{value: 10 ether}("Pool", 1 ether, 0, 0, false);

        vm.prank(user1);
        vm.expectRevert(IPactGasSponsor.NotAuthorizedRelayer.selector);
        sponsor.sponsorGas(poolId, user1, 0.1 ether);
    }

    function testSponsorGasInactivePoolReverts() public {
        vm.prank(poolOwner);
        uint256 poolId = sponsor.createPool{value: 1 ether}("Pool", 1 ether, 0, 0, false);
        vm.prank(poolOwner);
        sponsor.deactivatePool(poolId);

        vm.prank(relayer);
        vm.expectRevert(IPactGasSponsor.PoolNotActive.selector);
        sponsor.sponsorGas(poolId, user1, 0.1 ether);
    }

    function testSponsorGasZeroReverts() public {
        vm.prank(poolOwner);
        uint256 poolId = sponsor.createPool{value: 1 ether}("Pool", 1 ether, 0, 0, false);

        vm.prank(relayer);
        vm.expectRevert(IPactGasSponsor.ZeroAmount.selector);
        sponsor.sponsorGas(poolId, user1, 0);
    }

    function testSponsorGasPoolExhaustion() public {
        vm.prank(poolOwner);
        uint256 poolId = sponsor.createPool{value: 0.5 ether}("Small", 10 ether, 0, 0, false);

        vm.prank(relayer);
        vm.expectRevert(IPactGasSponsor.InsufficientPoolBalance.selector);
        sponsor.sponsorGas(poolId, user1, 1 ether);
    }

    // ── Views ────────────────────────────────────────────────────────────

    function testGetPoolNotFound() public {
        vm.expectRevert(IPactGasSponsor.PoolNotFound.selector);
        sponsor.getPool(999);
    }

    function testIsEligibleView() public {
        vm.prank(poolOwner);
        uint256 poolId = sponsor.createPool{value: 1 ether}("Pool", 1 ether, 70, 0, false);

        assertTrue(sponsor.isEligible(poolId, user1)); // 80 rep
        assertFalse(sponsor.isEligible(poolId, user2)); // 50 rep
    }

    // ── Relayer authorization ────────────────────────────────────────────

    function testSetRelayerAuthorization() public {
        address newRelayer = makeAddr("newRelayer");
        assertFalse(sponsor.authorizedRelayers(newRelayer));

        sponsor.setRelayerAuthorization(newRelayer, true);
        assertTrue(sponsor.authorizedRelayers(newRelayer));

        sponsor.setRelayerAuthorization(newRelayer, false);
        assertFalse(sponsor.authorizedRelayers(newRelayer));
    }

    function testSetRelayerOnlyOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        sponsor.setRelayerAuthorization(user1, true);
    }

    // ── Multiple sequential sponsorships ─────────────────────────────────

    function testMultipleSequentialSponsorships() public {
        vm.prank(poolOwner);
        uint256 poolId = sponsor.createPool{value: 10 ether}("Pool", 5 ether, 0, 0, false);

        vm.prank(relayer);
        sponsor.sponsorGas(poolId, user1, 0.1 ether);
        vm.prank(relayer);
        sponsor.sponsorGas(poolId, user1, 0.2 ether);
        vm.prank(relayer);
        sponsor.sponsorGas(poolId, user1, 0.3 ether);

        assertEq(sponsor.getUserDailyUsage(poolId, user1), 0.6 ether);
        assertEq(sponsor.getPool(poolId).balance, 9.4 ether);
    }
}
