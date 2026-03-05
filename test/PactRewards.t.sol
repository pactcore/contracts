// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PactRewards} from "../src/PactRewards.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

contract PactRewardsTest is Test {
    MockUSDC private usdc;
    PactRewards private rewards;

    address private validator1 = makeAddr("validator1");
    address private validator2 = makeAddr("validator2");
    address private worker1 = makeAddr("worker1");
    address private worker2 = makeAddr("worker2");

    uint256 private constant FUNDING_BALANCE = 10_000e6;

    function setUp() external {
        usdc = new MockUSDC();
        rewards = new PactRewards(address(usdc));

        usdc.mint(address(this), FUNDING_BALANCE);
        usdc.approve(address(rewards), type(uint256).max);
    }

    function testDistributeEpochRewardsAccruesBalances() external {
        address[] memory validators = new address[](2);
        validators[0] = validator1;
        validators[1] = validator2;

        uint256[] memory validatorRewards = new uint256[](2);
        validatorRewards[0] = 200e6;
        validatorRewards[1] = 100e6;

        address[] memory workers = new address[](2);
        workers[0] = worker1;
        workers[1] = worker2;

        uint256[] memory workerRewards = new uint256[](2);
        workerRewards[0] = 300e6;
        workerRewards[1] = 150e6;

        rewards.distributeEpochRewards(1, validators, validatorRewards, workers, workerRewards);

        assertEq(rewards.getRewardBalance(validator1), 200e6);
        assertEq(rewards.getRewardBalance(validator2), 100e6);
        assertEq(rewards.getRewardBalance(worker1), 300e6);
        assertEq(rewards.getRewardBalance(worker2), 150e6);
        assertTrue(rewards.epochDistributed(1));
        assertEq(rewards.totalPendingRewards(), 750e6);
        assertEq(usdc.balanceOf(address(rewards)), 750e6);
    }

    function testClaimRewardsTransfersAndClearsBalance() external {
        address[] memory validators = new address[](1);
        validators[0] = validator1;
        uint256[] memory validatorRewards = new uint256[](1);
        validatorRewards[0] = 250e6;

        address[] memory workers = new address[](1);
        workers[0] = worker1;
        uint256[] memory workerRewards = new uint256[](1);
        workerRewards[0] = 400e6;

        rewards.distributeEpochRewards(2, validators, validatorRewards, workers, workerRewards);

        vm.prank(worker1);
        rewards.claimRewards();

        assertEq(usdc.balanceOf(worker1), 400e6);
        assertEq(rewards.getRewardBalance(worker1), 0);
        assertEq(rewards.totalPendingRewards(), 250e6);
        assertEq(usdc.balanceOf(address(rewards)), 250e6);
    }

    function testCannotDistributeSameEpochTwice() external {
        address[] memory validators = new address[](1);
        validators[0] = validator1;
        uint256[] memory validatorRewards = new uint256[](1);
        validatorRewards[0] = 100e6;

        address[] memory workers = new address[](1);
        workers[0] = worker1;
        uint256[] memory workerRewards = new uint256[](1);
        workerRewards[0] = 100e6;

        rewards.distributeEpochRewards(3, validators, validatorRewards, workers, workerRewards);

        vm.expectRevert(PactRewards.EpochAlreadyDistributed.selector);
        rewards.distributeEpochRewards(3, validators, validatorRewards, workers, workerRewards);
    }

    function testClaimRewardsWithoutBalanceReverts() external {
        vm.prank(worker2);
        vm.expectRevert(PactRewards.NothingToClaim.selector);
        rewards.claimRewards();
    }

    function testDistributeWithLengthMismatchReverts() external {
        address[] memory validators = new address[](1);
        validators[0] = validator1;
        uint256[] memory validatorRewards = new uint256[](2);
        validatorRewards[0] = 100e6;
        validatorRewards[1] = 200e6;

        address[] memory workers = new address[](0);
        uint256[] memory workerRewards = new uint256[](0);

        vm.expectRevert(PactRewards.LengthMismatch.selector);
        rewards.distributeEpochRewards(4, validators, validatorRewards, workers, workerRewards);
    }
}
