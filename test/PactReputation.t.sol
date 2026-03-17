// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PactReputation} from "../src/PactReputation.sol";

contract PactReputationTest is Test {
    PactReputation private rep;

    address private participant = makeAddr("participant");
    address private updater = makeAddr("updater");

    // 30-day inactivity threshold; 7-day decay period; 5 points per period
    uint256 private constant INACTIVITY = 30 days;
    uint256 private constant PERIOD = 7 days;
    uint8 private constant DECAY = 5;

    function setUp() external {
        rep = new PactReputation(INACTIVITY, PERIOD, DECAY);
    }

    // ── Initial state ──────────────────────────────────────────────────────────

    function testInitialScoreIsDefault() external view {
        assertEq(rep.getScore(participant, PactReputation.Role.Worker), rep.INITIAL_SCORE());
        assertEq(rep.getScore(participant, PactReputation.Role.Validator), rep.INITIAL_SCORE());
        assertEq(rep.getScore(participant, PactReputation.Role.Issuer), rep.INITIAL_SCORE());
    }

    function testInitialScoreTimestampIsZero() external view {
        (, uint64 ts) = rep.getScoreWithTimestamp(participant, PactReputation.Role.Worker);
        assertEq(ts, 0);
    }

    // ── Score adjustments ─────────────────────────────────────────────────────

    function testAdjustScoreIncrease() external {
        rep.adjustScore(participant, PactReputation.Role.Worker, 10);
        assertEq(rep.getScore(participant, PactReputation.Role.Worker), 60);
    }

    function testAdjustScoreDecrease() external {
        rep.adjustScore(participant, PactReputation.Role.Worker, -10);
        assertEq(rep.getScore(participant, PactReputation.Role.Worker), 40);
    }

    function testScoreCappedAtMax() external {
        rep.adjustScore(participant, PactReputation.Role.Worker, 100);
        assertEq(rep.getScore(participant, PactReputation.Role.Worker), rep.MAX_SCORE());
    }

    function testScoreFlooredAtMin() external {
        rep.adjustScore(participant, PactReputation.Role.Worker, -100);
        assertEq(rep.getScore(participant, PactReputation.Role.Worker), rep.MIN_SCORE());
    }

    function testAdjustScoreZeroDeltaReverts() external {
        vm.expectRevert(PactReputation.InvalidAdjustment.selector);
        rep.adjustScore(participant, PactReputation.Role.Worker, 0);
    }

    function testAdjustScoreZeroAddressReverts() external {
        vm.expectRevert(PactReputation.ZeroAddress.selector);
        rep.adjustScore(address(0), PactReputation.Role.Worker, 5);
    }

    // ── Multi-role independence ────────────────────────────────────────────────

    function testMultiRoleScoresAreIndependent() external {
        rep.adjustScore(participant, PactReputation.Role.Worker, 20);
        rep.adjustScore(participant, PactReputation.Role.Validator, -5);

        assertEq(rep.getScore(participant, PactReputation.Role.Worker), 70);
        assertEq(rep.getScore(participant, PactReputation.Role.Validator), 45);
        assertEq(rep.getScore(participant, PactReputation.Role.Issuer), rep.INITIAL_SCORE());
    }

    // ── Decay ─────────────────────────────────────────────────────────────────

    function testNoDecayBeforeThreshold() external {
        rep.adjustScore(participant, PactReputation.Role.Worker, 30); // score = 80

        vm.warp(block.timestamp + INACTIVITY - 1);
        assertEq(rep.getScore(participant, PactReputation.Role.Worker), 80);
    }

    function testDecayAfterInactivityThreshold() external {
        rep.adjustScore(participant, PactReputation.Role.Worker, 30); // score = 80

        // Advance exactly to the inactivity threshold: 1 decay period fires
        vm.warp(block.timestamp + INACTIVITY);
        assertEq(rep.getScore(participant, PactReputation.Role.Worker), 80 - DECAY);
    }

    function testDecayMultiplePeriods() external {
        rep.adjustScore(participant, PactReputation.Role.Worker, 30); // score = 80

        // Advance by inactivity + 2 decay periods
        vm.warp(block.timestamp + INACTIVITY + 2 * PERIOD);
        // periods = (INACTIVITY + 2*PERIOD - INACTIVITY) / PERIOD + 1 = 2 + 1 = 3
        assertEq(rep.getScore(participant, PactReputation.Role.Worker), 80 - 3 * DECAY);
    }

    function testDecayDoesNotGoBelowZero() external {
        rep.adjustScore(participant, PactReputation.Role.Worker, -45); // score = 5

        // Advance enough for many decay periods
        vm.warp(block.timestamp + INACTIVITY + 10 * PERIOD);
        assertEq(rep.getScore(participant, PactReputation.Role.Worker), rep.MIN_SCORE());
    }

    function testApplyDecayMaterialisesStorage() external {
        rep.adjustScore(participant, PactReputation.Role.Worker, 30); // score = 80

        vm.warp(block.timestamp + INACTIVITY);
        rep.applyDecay(participant, PactReputation.Role.Worker);

        (uint8 value,) = rep.getScoreWithTimestamp(participant, PactReputation.Role.Worker);
        assertEq(value, 80 - DECAY);
    }

    function testApplyDecayOnUninitializedIsNoop() external {
        // Should not revert, just return silently
        rep.applyDecay(participant, PactReputation.Role.Worker);
        assertEq(rep.getScore(participant, PactReputation.Role.Worker), rep.INITIAL_SCORE());
    }

    function testAdjustScoreResetsDecayClock() external {
        rep.adjustScore(participant, PactReputation.Role.Worker, 30); // score = 80

        // Advance past threshold
        vm.warp(block.timestamp + INACTIVITY + PERIOD);

        // Activity resets clock: getScore applies decay, then adjustScore materialises it
        rep.adjustScore(participant, PactReputation.Role.Worker, 5);
        // Current decayed score = 80 - 2*5 = 70; +5 = 75
        assertEq(rep.getScore(participant, PactReputation.Role.Worker), 75);

        // Now move forward by less than the threshold — no additional decay
        vm.warp(block.timestamp + INACTIVITY - 1);
        assertEq(rep.getScore(participant, PactReputation.Role.Worker), 75);
    }

    // ── Access control ────────────────────────────────────────────────────────

    function testAuthorizedUpdaterCanAdjust() external {
        rep.setAuthorizedUpdater(updater, true);
        assertTrue(rep.authorizedUpdaters(updater));

        vm.prank(updater);
        rep.adjustScore(participant, PactReputation.Role.Validator, 10);
        assertEq(rep.getScore(participant, PactReputation.Role.Validator), 60);
    }

    function testUnauthorizedUpdaterReverts() external {
        vm.prank(updater);
        vm.expectRevert(PactReputation.UnauthorizedUpdater.selector);
        rep.adjustScore(participant, PactReputation.Role.Worker, 5);
    }

    function testRevokeUpdaterPreventsAdjust() external {
        rep.setAuthorizedUpdater(updater, true);
        rep.setAuthorizedUpdater(updater, false);

        vm.prank(updater);
        vm.expectRevert(PactReputation.UnauthorizedUpdater.selector);
        rep.adjustScore(participant, PactReputation.Role.Worker, 5);
    }

    function testSetUpdaterZeroAddressReverts() external {
        vm.expectRevert(PactReputation.ZeroAddress.selector);
        rep.setAuthorizedUpdater(address(0), true);
    }
}
