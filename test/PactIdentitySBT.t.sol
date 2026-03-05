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
}
