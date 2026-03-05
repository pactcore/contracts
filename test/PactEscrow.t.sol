// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PactEscrow} from "../src/PactEscrow.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

contract PactEscrowTest is Test {
    MockUSDC private usdc;
    PactEscrow private escrow;

    address private payer = makeAddr("payer");
    address private worker = makeAddr("worker");
    address private validators = makeAddr("validators");
    address private treasury = makeAddr("treasury");
    address private issuer = makeAddr("issuer");

    uint256 private constant INITIAL_BALANCE = 10_000e6;
    uint256 private constant ESCROW_AMOUNT = 1_000e6;
    uint256 private constant TASK_ID = 1;

    function setUp() external {
        usdc = new MockUSDC();
        escrow = new PactEscrow(address(usdc));

        usdc.mint(payer, INITIAL_BALANCE);
        vm.prank(payer);
        usdc.approve(address(escrow), type(uint256).max);
    }

    function testCreateEscrow() external {
        vm.prank(payer);
        escrow.createEscrow(TASK_ID, payer, ESCROW_AMOUNT);

        PactEscrow.Escrow memory state = escrow.getEscrow(TASK_ID);
        assertEq(state.payer, payer);
        assertEq(state.amount, ESCROW_AMOUNT);
        assertFalse(state.released);
        assertFalse(state.refunded);
        assertEq(usdc.balanceOf(address(escrow)), ESCROW_AMOUNT);
        assertEq(usdc.balanceOf(payer), INITIAL_BALANCE - ESCROW_AMOUNT);
    }

    function testReleaseEscrowSplit85_5_5_5() external {
        vm.prank(payer);
        escrow.createEscrow(TASK_ID, payer, ESCROW_AMOUNT);

        PactEscrow.Payouts memory payouts = PactEscrow.Payouts({
            worker: worker,
            validators: validators,
            treasury: treasury,
            issuer: issuer
        });

        escrow.releaseEscrow(TASK_ID, payouts);

        uint256 validatorsAmount = (ESCROW_AMOUNT * 500) / 10_000;
        uint256 treasuryAmount = (ESCROW_AMOUNT * 500) / 10_000;
        uint256 issuerAmount = (ESCROW_AMOUNT * 500) / 10_000;
        uint256 workerAmount = ESCROW_AMOUNT - validatorsAmount - treasuryAmount - issuerAmount;

        assertEq(usdc.balanceOf(worker), workerAmount);
        assertEq(usdc.balanceOf(validators), validatorsAmount);
        assertEq(usdc.balanceOf(treasury), treasuryAmount);
        assertEq(usdc.balanceOf(issuer), issuerAmount);
        assertEq(usdc.balanceOf(address(escrow)), 0);

        PactEscrow.Escrow memory state = escrow.getEscrow(TASK_ID);
        assertTrue(state.released);
        assertFalse(state.refunded);
    }

    function testRefundEscrow() external {
        vm.prank(payer);
        escrow.createEscrow(TASK_ID, payer, ESCROW_AMOUNT);

        escrow.refundEscrow(TASK_ID);

        assertEq(usdc.balanceOf(payer), INITIAL_BALANCE);
        assertEq(usdc.balanceOf(address(escrow)), 0);

        PactEscrow.Escrow memory state = escrow.getEscrow(TASK_ID);
        assertFalse(state.released);
        assertTrue(state.refunded);
    }
}
