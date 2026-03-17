// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PactIdentitySBT} from "../src/PactIdentitySBT.sol";

contract PactIdentitySBTTest is Test {
    PactIdentitySBT private sbt;

    address private alice = makeAddr("alice");
    address private bob = makeAddr("bob");
    address private upgrader = makeAddr("upgrader");

    function setUp() external {
        sbt = new PactIdentitySBT();
        sbt.grantRole(sbt.UPGRADER_ROLE(), upgrader);
    }

    function testMint() external {
        uint256 tokenId = sbt.mint(alice, 1001, "worker", 1);

        assertEq(sbt.ownerOf(tokenId), alice);
        (string memory role, uint8 level, uint256 registeredAt) = sbt.getIdentity(tokenId);
        assertEq(role, "worker");
        assertEq(level, 1);
        assertEq(registeredAt, block.timestamp);
    }

    function testUpgradeLevel() external {
        uint256 tokenId = sbt.mint(alice, 1001, "worker", 1);

        vm.prank(upgrader);
        sbt.upgradeLevel(tokenId, 2);

        (, uint8 level,) = sbt.getIdentity(tokenId);
        assertEq(level, 2);
    }

    function testTransferRevertsSoulbound() external {
        uint256 tokenId = sbt.mint(alice, 1001, "worker", 1);

        vm.prank(alice);
        vm.expectRevert(PactIdentitySBT.Soulbound.selector);
        sbt.transferFrom(alice, bob, tokenId);
    }

    // ── Identity Level Benefits Tests ──

    function testGetLevelBenefits_Basic() external view {
        (uint16 fee, uint8 maxTasks, bool premium) = sbt.getLevelBenefits(1);
        assertEq(fee, 0);
        assertEq(maxTasks, 1);
        assertFalse(premium);
    }

    function testGetLevelBenefits_Verified() external view {
        (uint16 fee, uint8 maxTasks, bool premium) = sbt.getLevelBenefits(2);
        assertEq(fee, 250);
        assertEq(maxTasks, 3);
        assertFalse(premium);
    }

    function testGetLevelBenefits_Trusted() external view {
        (uint16 fee, uint8 maxTasks, bool premium) = sbt.getLevelBenefits(3);
        assertEq(fee, 500);
        assertEq(maxTasks, 5);
        assertTrue(premium);
    }

    function testGetLevelBenefits_Elite() external view {
        (uint16 fee, uint8 maxTasks, bool premium) = sbt.getLevelBenefits(4);
        assertEq(fee, 1000);
        assertEq(maxTasks, 10);
        assertTrue(premium);
    }

    function testGetLevelBenefits_InvalidLevel() external {
        vm.expectRevert(PactIdentitySBT.InvalidLevel.selector);
        sbt.getLevelBenefits(0);
    }

    function testGetLevelBenefits_InvalidLevel5() external {
        vm.expectRevert(PactIdentitySBT.InvalidLevel.selector);
        sbt.getLevelBenefits(5);
    }

    function testMintAutoPopulatesBenefits() external {
        uint256 tokenId = sbt.mint(alice, 2001, "validator", 2);

        (uint8 level, uint16 feeDiscount, uint8 maxTasks, bool premium) = sbt.getParticipantLevel(tokenId);
        assertEq(level, 2);
        assertEq(feeDiscount, 250);
        assertEq(maxTasks, 3);
        assertFalse(premium);
    }

    function testUpgradeLevelUpdatesBenefits() external {
        uint256 tokenId = sbt.mint(alice, 3001, "worker", 1);

        // Verify initial basic benefits
        (uint8 level, uint16 feeDiscount, uint8 maxTasks, bool premium) = sbt.getParticipantLevel(tokenId);
        assertEq(level, 1);
        assertEq(feeDiscount, 0);
        assertEq(maxTasks, 1);
        assertFalse(premium);

        // Upgrade to elite
        vm.prank(upgrader);
        sbt.upgradeLevel(tokenId, 4);

        (level, feeDiscount, maxTasks, premium) = sbt.getParticipantLevel(tokenId);
        assertEq(level, 4);
        assertEq(feeDiscount, 1000);
        assertEq(maxTasks, 10);
        assertTrue(premium);
    }

    function testGetParticipantLevel_RevertsNonexistent() external {
        vm.expectRevert(PactIdentitySBT.TokenDoesNotExist.selector);
        sbt.getParticipantLevel(999);
    }

    function testMintRevertsInvalidLevel() external {
        vm.expectRevert(PactIdentitySBT.InvalidLevel.selector);
        sbt.mint(alice, 4001, "worker", 0);
    }

    function testLevelConstants() external view {
        assertEq(sbt.LEVEL_BASIC(), 1);
        assertEq(sbt.LEVEL_VERIFIED(), 2);
        assertEq(sbt.LEVEL_TRUSTED(), 3);
        assertEq(sbt.LEVEL_ELITE(), 4);
    }
}
