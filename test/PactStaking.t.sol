// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PactStaking} from "../src/PactStaking.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

contract PactStakingTest is Test {
    MockUSDC private usdc;
    PactStaking private staking;

    address private challenger = makeAddr("challenger");
    address private juryTreasury = makeAddr("juryTreasury");
    address private protocolTreasury = makeAddr("protocolTreasury");

    uint16 private constant PENALTY_BPS = 1_000; // 10%
    uint256 private constant INITIAL_BALANCE = 5_000e6;
    uint256 private constant STAKE_AMOUNT = 1_000e6;

    function setUp() external {
        usdc = new MockUSDC();
        staking = new PactStaking(address(usdc), juryTreasury, protocolTreasury, PENALTY_BPS);

        usdc.mint(challenger, INITIAL_BALANCE);
        vm.prank(challenger);
        usdc.approve(address(staking), type(uint256).max);
    }

    function testPostStake() external {
        vm.prank(challenger);
        staking.postStake(1, STAKE_AMOUNT);

        PactStaking.Stake memory state = staking.getStake(1);
        assertEq(state.challenger, challenger);
        assertEq(state.amount, STAKE_AMOUNT);
        assertFalse(state.resolved);
        assertFalse(state.upheld);
        assertEq(usdc.balanceOf(address(staking)), STAKE_AMOUNT);
    }

    function testResolveStakeUpheld() external {
        vm.prank(challenger);
        staking.postStake(1, STAKE_AMOUNT);

        staking.resolveStake(1, true);

        uint256 penalty = (STAKE_AMOUNT * PENALTY_BPS) / 10_000;
        uint256 expectedRefund = STAKE_AMOUNT - penalty;
        uint256 expectedJury = penalty / 2;
        uint256 expectedProtocol = penalty - expectedJury;

        assertEq(usdc.balanceOf(challenger), INITIAL_BALANCE - STAKE_AMOUNT + expectedRefund);
        assertEq(usdc.balanceOf(juryTreasury), expectedJury);
        assertEq(usdc.balanceOf(protocolTreasury), expectedProtocol);
        assertEq(usdc.balanceOf(address(staking)), 0);

        PactStaking.Stake memory state = staking.getStake(1);
        assertTrue(state.resolved);
        assertTrue(state.upheld);
    }

    function testResolveStakeRejected() external {
        vm.prank(challenger);
        staking.postStake(2, STAKE_AMOUNT);

        staking.resolveStake(2, false);

        uint256 expectedJury = STAKE_AMOUNT / 2;
        uint256 expectedProtocol = STAKE_AMOUNT - expectedJury;

        assertEq(usdc.balanceOf(challenger), INITIAL_BALANCE - STAKE_AMOUNT);
        assertEq(usdc.balanceOf(juryTreasury), expectedJury);
        assertEq(usdc.balanceOf(protocolTreasury), expectedProtocol);
        assertEq(usdc.balanceOf(address(staking)), 0);

        PactStaking.Stake memory state = staking.getStake(2);
        assertTrue(state.resolved);
        assertFalse(state.upheld);
    }
}
