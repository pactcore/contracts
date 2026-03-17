// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PactSybilResistance} from "../src/PactSybilResistance.sol";

contract PactSybilResistanceTest is Test {
    PactSybilResistance public sybil;
    address public owner = address(this);
    address public updater = address(0xBEEF);
    address public alice = address(0x1);
    address public bob = address(0x2);
    address public charlie = address(0x3);
    address public unauthorized = address(0xDEAD);

    function setUp() public {
        sybil = new PactSybilResistance();
        sybil.setAuthorizedUpdater(updater, true);
    }

    // ── Constructor / Config ──────────────────────────────────────────

    function test_constructor_defaults() public view {
        (uint256 minStake, uint256 minHighTrust, uint256 minGov) = sybil.config();
        assertEq(minStake, 1000);
        assertEq(minHighTrust, 50);
        assertEq(minGov, 70);
    }

    function test_updateConfig() public {
        sybil.updateConfig(2000, 60, 80);
        (uint256 minStake, uint256 minHighTrust, uint256 minGov) = sybil.config();
        assertEq(minStake, 2000);
        assertEq(minHighTrust, 60);
        assertEq(minGov, 80);
    }

    function test_updateConfig_revert_zeroStake() public {
        vm.expectRevert(PactSybilResistance.InvalidConfig.selector);
        sybil.updateConfig(0, 50, 70);
    }

    function test_updateConfig_revert_scoreTooHigh() public {
        vm.expectRevert(PactSybilResistance.InvalidConfig.selector);
        sybil.updateConfig(1000, 101, 70);
    }

    function test_updateConfig_revert_nonOwner() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        sybil.updateConfig(1000, 50, 70);
    }

    // ── Authorization ─────────────────────────────────────────────────

    function test_setAuthorizedUpdater() public {
        sybil.setAuthorizedUpdater(alice, true);
        assertTrue(sybil.authorizedUpdaters(alice));
        sybil.setAuthorizedUpdater(alice, false);
        assertFalse(sybil.authorizedUpdaters(alice));
    }

    function test_setAuthorizedUpdater_revert_zeroAddress() public {
        vm.expectRevert(PactSybilResistance.ZeroAddress.selector);
        sybil.setAuthorizedUpdater(address(0), true);
    }

    // ── Registration ──────────────────────────────────────────────────

    function test_registerParticipant_basic() public {
        vm.prank(updater);
        sybil.registerParticipant(alice, PactSybilResistance.VerificationLevel.Basic, 500);

        (
            PactSybilResistance.VerificationLevel level,
            uint256 stake,
            uint256 score,
            uint64 registered,
            uint64 updated,
            bool frozen
        ) = sybil.getProfile(alice);

        assertEq(uint256(level), uint256(PactSybilResistance.VerificationLevel.Basic));
        assertEq(stake, 500);
        assertTrue(score > 0);
        assertTrue(registered > 0);
        assertTrue(updated > 0);
        assertFalse(frozen);
    }

    function test_registerParticipant_elite_fullStake() public {
        vm.prank(updater);
        sybil.registerParticipant(alice, PactSybilResistance.VerificationLevel.Elite, 2000);
        assertEq(sybil.getScore(alice), 100);
    }

    function test_registerParticipant_none_noStake() public {
        vm.prank(updater);
        sybil.registerParticipant(alice, PactSybilResistance.VerificationLevel.None, 0);
        assertEq(sybil.getScore(alice), 0);
    }

    function test_registerParticipant_revert_duplicate() public {
        vm.prank(updater);
        sybil.registerParticipant(alice, PactSybilResistance.VerificationLevel.Basic, 500);

        vm.prank(updater);
        vm.expectRevert(PactSybilResistance.AlreadyRegistered.selector);
        sybil.registerParticipant(alice, PactSybilResistance.VerificationLevel.Verified, 1000);
    }

    function test_registerParticipant_revert_zeroAddress() public {
        vm.prank(updater);
        vm.expectRevert(PactSybilResistance.ZeroAddress.selector);
        sybil.registerParticipant(address(0), PactSybilResistance.VerificationLevel.Basic, 500);
    }

    function test_registerParticipant_revert_unauthorized() public {
        vm.prank(unauthorized);
        vm.expectRevert(PactSybilResistance.UnauthorizedUpdater.selector);
        sybil.registerParticipant(alice, PactSybilResistance.VerificationLevel.Basic, 500);
    }

    // ── Score Computation ─────────────────────────────────────────────

    function test_score_verified_halfStake() public {
        // Verified = level 2 → identity = 2/4 * 100 = 50
        // stake 500 / minStake 1000 = 50% → stakeScore = 50
        // score = (50 * 70 + 50 * 30) / 100 = 50
        vm.prank(updater);
        sybil.registerParticipant(alice, PactSybilResistance.VerificationLevel.Verified, 500);
        assertEq(sybil.getScore(alice), 50);
    }

    function test_score_trusted_overStake() public {
        // Trusted = level 3 → identity = 3/4 * 100 = 75
        // stake 5000 > minStake 1000 → stakeScore = 100
        // score = (75 * 70 + 100 * 30) / 100 = 82
        vm.prank(updater);
        sybil.registerParticipant(alice, PactSybilResistance.VerificationLevel.Trusted, 5000);
        assertEq(sybil.getScore(alice), 82);
    }

    function test_score_basic_noStake() public {
        // Basic = level 1 → identity = 1/4 * 100 = 25
        // stake 0 / 1000 = 0 → stakeScore = 0
        // score = (25 * 70 + 0 * 30) / 100 = 17
        vm.prank(updater);
        sybil.registerParticipant(alice, PactSybilResistance.VerificationLevel.Basic, 0);
        assertEq(sybil.getScore(alice), 17);
    }

    // ── Updates ───────────────────────────────────────────────────────

    function test_updateVerificationLevel() public {
        vm.prank(updater);
        sybil.registerParticipant(alice, PactSybilResistance.VerificationLevel.Basic, 1000);
        uint256 oldScore = sybil.getScore(alice);

        vm.prank(updater);
        sybil.updateVerificationLevel(alice, PactSybilResistance.VerificationLevel.Elite);
        uint256 newScore = sybil.getScore(alice);

        assertTrue(newScore > oldScore);
        assertEq(newScore, 100);
    }

    function test_updateStake() public {
        vm.prank(updater);
        sybil.registerParticipant(alice, PactSybilResistance.VerificationLevel.Verified, 500);
        uint256 oldScore = sybil.getScore(alice);

        vm.prank(updater);
        sybil.updateStake(alice, 2000);
        uint256 newScore = sybil.getScore(alice);

        assertTrue(newScore > oldScore);
    }

    function test_updateVerificationLevel_revert_notRegistered() public {
        vm.prank(updater);
        vm.expectRevert(PactSybilResistance.NotRegistered.selector);
        sybil.updateVerificationLevel(alice, PactSybilResistance.VerificationLevel.Elite);
    }

    function test_updateStake_revert_notRegistered() public {
        vm.prank(updater);
        vm.expectRevert(PactSybilResistance.NotRegistered.selector);
        sybil.updateStake(alice, 1000);
    }

    function test_updateVerificationLevel_revert_frozen() public {
        vm.prank(updater);
        sybil.registerParticipant(alice, PactSybilResistance.VerificationLevel.Basic, 500);
        vm.prank(updater);
        sybil.freezeParticipant(alice);

        vm.prank(updater);
        vm.expectRevert(PactSybilResistance.ParticipantIsFrozen.selector);
        sybil.updateVerificationLevel(alice, PactSybilResistance.VerificationLevel.Elite);
    }

    function test_updateStake_revert_frozen() public {
        vm.prank(updater);
        sybil.registerParticipant(alice, PactSybilResistance.VerificationLevel.Basic, 500);
        vm.prank(updater);
        sybil.freezeParticipant(alice);

        vm.prank(updater);
        vm.expectRevert(PactSybilResistance.ParticipantIsFrozen.selector);
        sybil.updateStake(alice, 1000);
    }

    // ── Freeze / Unfreeze ─────────────────────────────────────────────

    function test_freezeAndUnfreeze() public {
        vm.prank(updater);
        sybil.registerParticipant(alice, PactSybilResistance.VerificationLevel.Elite, 2000);

        vm.prank(updater);
        sybil.freezeParticipant(alice);
        (,,,,, bool frozen) = sybil.getProfile(alice);
        assertTrue(frozen);

        vm.prank(updater);
        sybil.unfreezeParticipant(alice);
        (,,,,, bool frozenAfter) = sybil.getProfile(alice);
        assertFalse(frozenAfter);
    }

    // ── Gatekeeper ────────────────────────────────────────────────────

    function test_canPerformHighTrust_true() public {
        vm.prank(updater);
        sybil.registerParticipant(alice, PactSybilResistance.VerificationLevel.Verified, 500);
        assertTrue(sybil.canPerformHighTrust(alice));
    }

    function test_canPerformHighTrust_false_lowScore() public {
        vm.prank(updater);
        sybil.registerParticipant(alice, PactSybilResistance.VerificationLevel.Basic, 0);
        assertFalse(sybil.canPerformHighTrust(alice));
    }

    function test_canPerformHighTrust_false_frozen() public {
        vm.prank(updater);
        sybil.registerParticipant(alice, PactSybilResistance.VerificationLevel.Elite, 2000);
        vm.prank(updater);
        sybil.freezeParticipant(alice);
        assertFalse(sybil.canPerformHighTrust(alice));
    }

    function test_canPerformHighTrust_false_notRegistered() public view {
        assertFalse(sybil.canPerformHighTrust(alice));
    }

    function test_canParticipateInGovernance_true() public {
        vm.prank(updater);
        sybil.registerParticipant(alice, PactSybilResistance.VerificationLevel.Trusted, 2000);
        assertTrue(sybil.canParticipateInGovernance(alice));
    }

    function test_canParticipateInGovernance_false() public {
        vm.prank(updater);
        sybil.registerParticipant(alice, PactSybilResistance.VerificationLevel.Verified, 500);
        assertFalse(sybil.canParticipateInGovernance(alice));
    }

    function test_requireMinScore_passes() public {
        vm.prank(updater);
        sybil.registerParticipant(alice, PactSybilResistance.VerificationLevel.Elite, 2000);
        // Should not revert
        sybil.requireMinScore(alice, 50);
    }

    function test_requireMinScore_revert_lowScore() public {
        vm.prank(updater);
        sybil.registerParticipant(alice, PactSybilResistance.VerificationLevel.None, 0);

        vm.expectRevert(abi.encodeWithSelector(PactSybilResistance.InsufficientSybilScore.selector, 50, 0));
        sybil.requireMinScore(alice, 50);
    }

    function test_requireMinScore_revert_notRegistered() public {
        vm.expectRevert(PactSybilResistance.NotRegistered.selector);
        sybil.requireMinScore(alice, 50);
    }

    function test_requireMinScore_revert_frozen() public {
        vm.prank(updater);
        sybil.registerParticipant(alice, PactSybilResistance.VerificationLevel.Elite, 2000);
        vm.prank(updater);
        sybil.freezeParticipant(alice);

        vm.expectRevert(PactSybilResistance.ParticipantIsFrozen.selector);
        sybil.requireMinScore(alice, 50);
    }

    // ── Multiple Participants ─────────────────────────────────────────

    function test_multipleParticipants_independent() public {
        vm.startPrank(updater);
        sybil.registerParticipant(alice, PactSybilResistance.VerificationLevel.Elite, 2000);
        sybil.registerParticipant(bob, PactSybilResistance.VerificationLevel.Basic, 100);
        sybil.registerParticipant(charlie, PactSybilResistance.VerificationLevel.Verified, 1000);
        vm.stopPrank();

        assertEq(sybil.getScore(alice), 100);
        assertTrue(sybil.getScore(bob) < 30);
        assertEq(sybil.getScore(charlie), 65);
    }

    // ── Owner direct actions ──────────────────────────────────────────

    function test_ownerCanRegister() public {
        sybil.registerParticipant(alice, PactSybilResistance.VerificationLevel.Verified, 1000);
        assertTrue(sybil.getScore(alice) > 0);
    }
}
