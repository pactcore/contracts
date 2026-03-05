// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PactPayRouter} from "../src/PactPayRouter.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

contract PactPayRouterTest is Test {
    MockUSDC private usdc;
    PactPayRouter private router;

    address private alice = makeAddr("alice");
    address private bob = makeAddr("bob");
    address private carol = makeAddr("carol");

    uint256 private constant INITIAL_BALANCE = 10_000e6;

    function setUp() external {
        usdc = new MockUSDC();
        router = new PactPayRouter(address(usdc));

        usdc.mint(alice, INITIAL_BALANCE);
        vm.prank(alice);
        usdc.approve(address(router), type(uint256).max);
    }

    function testTransfer() external {
        bytes32 paymentRef = keccak256(bytes("task-1"));
        uint256 amount = 250e6;

        vm.prank(alice);
        router.transfer(alice, bob, amount, paymentRef);

        assertEq(usdc.balanceOf(alice), INITIAL_BALANCE - amount);
        assertEq(usdc.balanceOf(bob), amount);

        PactPayRouter.LedgerEntry[] memory aliceLedger = router.getLedger(alice);
        PactPayRouter.LedgerEntry[] memory bobLedger = router.getLedger(bob);

        assertEq(aliceLedger.length, 1);
        assertEq(bobLedger.length, 1);
        assertEq(aliceLedger[0].from, alice);
        assertEq(aliceLedger[0].to, bob);
        assertEq(aliceLedger[0].amount, amount);
        assertEq(aliceLedger[0].ref, paymentRef);
    }

    function testBatchTransfer() external {
        PactPayRouter.TransferRequest[] memory transfers = new PactPayRouter.TransferRequest[](2);
        transfers[0] =
            PactPayRouter.TransferRequest({from: alice, to: bob, amount: 100e6, ref: keccak256(bytes("batch-1"))});
        transfers[1] =
            PactPayRouter.TransferRequest({from: alice, to: carol, amount: 150e6, ref: keccak256(bytes("batch-2"))});

        vm.prank(alice);
        router.batchTransfer(transfers);

        assertEq(usdc.balanceOf(alice), INITIAL_BALANCE - 250e6);
        assertEq(usdc.balanceOf(bob), 100e6);
        assertEq(usdc.balanceOf(carol), 150e6);

        assertEq(router.getLedger(alice).length, 2);
        assertEq(router.getLedger(bob).length, 1);
        assertEq(router.getLedger(carol).length, 1);
    }
}
