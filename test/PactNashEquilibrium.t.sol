// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {PactNashEquilibrium} from "../src/PactNashEquilibrium.sol";

contract PactNashEquilibriumTest is Test {
    PactNashEquilibrium public nash;
    address public owner;
    address public updater;
    address public stranger;

    bytes32 constant PROFILE_1 = keccak256("worker-validator-honest");
    bytes32 constant PROFILE_2 = keccak256("issuer-worker-mixed");
    bytes32 constant PROFILE_UNSTABLE = keccak256("unstable-profile");

    function setUp() public {
        owner = address(this);
        updater = makeAddr("updater");
        stranger = makeAddr("stranger");
        nash = new PactNashEquilibrium();
    }

    // ── Helper ────────────────────────────────────────────────────────────

    function _storeDefaultStableProfile() internal {
        string[] memory players = new string[](3);
        players[0] = "worker";
        players[1] = "validator";
        players[2] = "issuer";

        string[] memory strategies = new string[](2);
        strategies[0] = "honest";
        strategies[1] = "dishonest";

        string[] memory chosen = new string[](3);
        chosen[0] = "honest";
        chosen[1] = "honest";
        chosen[2] = "honest";

        int256[] memory payoffs = new int256[](3);
        payoffs[0] = 85e18;
        payoffs[1] = 5e18;
        payoffs[2] = 5e18;

        nash.storeProfile(PROFILE_1, players, strategies, chosen, payoffs, 95e18, true);
    }

    function _storeUnstableProfile() internal {
        string[] memory players = new string[](2);
        players[0] = "worker";
        players[1] = "validator";

        string[] memory strategies = new string[](2);
        strategies[0] = "honest";
        strategies[1] = "dishonest";

        string[] memory chosen = new string[](2);
        chosen[0] = "honest";
        chosen[1] = "dishonest";

        int256[] memory payoffs = new int256[](2);
        payoffs[0] = 30e18;
        payoffs[1] = 70e18;

        nash.storeProfile(PROFILE_UNSTABLE, players, strategies, chosen, payoffs, 100e18, false);
    }

    // ── Constructor defaults ──────────────────────────────────────────────

    function test_constructor_defaults() public view {
        (
            uint16 w,
            uint16 v,
            uint16 t,
            uint16 i,
            uint256 minStake,
            uint256 penalty,
            uint256 collusionThresh,
            uint64 updatedAt
        ) = nash.incentiveParams();
        assertEq(w, 8500);
        assertEq(v, 500);
        assertEq(t, 500);
        assertEq(i, 500);
        assertEq(minStake, 100e6);
        assertEq(penalty, 500e6);
        assertEq(collusionThresh, 3);
        assertGt(updatedAt, 0);
    }

    // ── Authorized updater ────────────────────────────────────────────────

    function test_setAuthorizedUpdater() public {
        assertFalse(nash.authorizedUpdaters(updater));
        nash.setAuthorizedUpdater(updater, true);
        assertTrue(nash.authorizedUpdaters(updater));
        nash.setAuthorizedUpdater(updater, false);
        assertFalse(nash.authorizedUpdaters(updater));
    }

    function test_setAuthorizedUpdater_zeroAddress_reverts() public {
        vm.expectRevert(PactNashEquilibrium.ZeroAddress.selector);
        nash.setAuthorizedUpdater(address(0), true);
    }

    function test_setAuthorizedUpdater_nonOwner_reverts() public {
        vm.prank(stranger);
        vm.expectRevert();
        nash.setAuthorizedUpdater(updater, true);
    }

    // ── Store profile ─────────────────────────────────────────────────────

    function test_storeProfile_success() public {
        _storeDefaultStableProfile();
        assertEq(nash.profileCount(), 1);
        assertEq(nash.profileIdAt(0), PROFILE_1);
    }

    function test_storeProfile_getProfile() public {
        _storeDefaultStableProfile();
        (
            string[] memory players,
            string[] memory strategies,
            string[] memory chosen,
            int256[] memory payoffs,
            int256 totalPayoff,
            bool stable,
            uint64 updatedAt
        ) = nash.getProfile(PROFILE_1);
        assertEq(players.length, 3);
        assertEq(strategies.length, 2);
        assertEq(chosen.length, 3);
        assertEq(payoffs.length, 3);
        assertEq(totalPayoff, 95e18);
        assertTrue(stable);
        assertGt(updatedAt, 0);
        assertEq(keccak256(bytes(players[0])), keccak256(bytes("worker")));
        assertEq(keccak256(bytes(chosen[2])), keccak256(bytes("honest")));
    }

    function test_storeProfile_emptyPlayers_reverts() public {
        string[] memory players = new string[](0);
        string[] memory strategies = new string[](1);
        strategies[0] = "honest";
        string[] memory chosen = new string[](0);
        int256[] memory payoffs = new int256[](0);

        vm.expectRevert(PactNashEquilibrium.EmptyPlayers.selector);
        nash.storeProfile(PROFILE_1, players, strategies, chosen, payoffs, 0, true);
    }

    function test_storeProfile_emptyStrategies_reverts() public {
        string[] memory players = new string[](1);
        players[0] = "worker";
        string[] memory strategies = new string[](0);
        string[] memory chosen = new string[](1);
        chosen[0] = "honest";
        int256[] memory payoffs = new int256[](1);
        payoffs[0] = 1e18;

        vm.expectRevert(PactNashEquilibrium.EmptyStrategies.selector);
        nash.storeProfile(PROFILE_1, players, strategies, chosen, payoffs, 1e18, true);
    }

    function test_storeProfile_tooManyPlayers_reverts() public {
        string[] memory players = new string[](11);
        for (uint256 j; j < 11; j++) {
            players[j] = "p";
        }
        string[] memory strategies = new string[](1);
        strategies[0] = "s";
        string[] memory chosen = new string[](11);
        for (uint256 j; j < 11; j++) {
            chosen[j] = "s";
        }
        int256[] memory payoffs = new int256[](11);

        vm.expectRevert(PactNashEquilibrium.TooManyPlayers.selector);
        nash.storeProfile(PROFILE_1, players, strategies, chosen, payoffs, 0, true);
    }

    function test_storeProfile_tooManyStrategies_reverts() public {
        string[] memory players = new string[](1);
        players[0] = "p";
        string[] memory strategies = new string[](11);
        for (uint256 j; j < 11; j++) {
            strategies[j] = "s";
        }
        string[] memory chosen = new string[](1);
        chosen[0] = "s";
        int256[] memory payoffs = new int256[](1);

        vm.expectRevert(PactNashEquilibrium.TooManyStrategies.selector);
        nash.storeProfile(PROFILE_1, players, strategies, chosen, payoffs, 0, true);
    }

    function test_storeProfile_chosenLengthMismatch_reverts() public {
        string[] memory players = new string[](2);
        players[0] = "a";
        players[1] = "b";
        string[] memory strategies = new string[](1);
        strategies[0] = "s";
        string[] memory chosen = new string[](1);
        chosen[0] = "s";
        int256[] memory payoffs = new int256[](2);

        vm.expectRevert(PactNashEquilibrium.LengthMismatch.selector);
        nash.storeProfile(PROFILE_1, players, strategies, chosen, payoffs, 0, true);
    }

    function test_storeProfile_payoffsLengthMismatch_reverts() public {
        string[] memory players = new string[](2);
        players[0] = "a";
        players[1] = "b";
        string[] memory strategies = new string[](1);
        strategies[0] = "s";
        string[] memory chosen = new string[](2);
        chosen[0] = "s";
        chosen[1] = "s";
        int256[] memory payoffs = new int256[](1);
        payoffs[0] = 1e18;

        vm.expectRevert(PactNashEquilibrium.LengthMismatch.selector);
        nash.storeProfile(PROFILE_1, players, strategies, chosen, payoffs, 0, true);
    }

    function test_storeProfile_duplicateId_reverts() public {
        _storeDefaultStableProfile();

        string[] memory players = new string[](1);
        players[0] = "p";
        string[] memory strategies = new string[](1);
        strategies[0] = "s";
        string[] memory chosen = new string[](1);
        chosen[0] = "s";
        int256[] memory payoffs = new int256[](1);
        payoffs[0] = 1e18;

        vm.expectRevert(PactNashEquilibrium.ProfileAlreadyExists.selector);
        nash.storeProfile(PROFILE_1, players, strategies, chosen, payoffs, 1e18, true);
    }

    function test_storeProfile_unauthorized_reverts() public {
        string[] memory players = new string[](1);
        players[0] = "p";
        string[] memory strategies = new string[](1);
        strategies[0] = "s";
        string[] memory chosen = new string[](1);
        chosen[0] = "s";
        int256[] memory payoffs = new int256[](1);

        vm.prank(stranger);
        vm.expectRevert(PactNashEquilibrium.UnauthorizedUpdater.selector);
        nash.storeProfile(PROFILE_1, players, strategies, chosen, payoffs, 0, true);
    }

    function test_storeProfile_authorizedUpdater() public {
        nash.setAuthorizedUpdater(updater, true);

        string[] memory players = new string[](1);
        players[0] = "p";
        string[] memory strategies = new string[](1);
        strategies[0] = "s";
        string[] memory chosen = new string[](1);
        chosen[0] = "s";
        int256[] memory payoffs = new int256[](1);
        payoffs[0] = 1e18;

        vm.prank(updater);
        nash.storeProfile(PROFILE_1, players, strategies, chosen, payoffs, 1e18, true);
        assertEq(nash.profileCount(), 1);
    }

    // ── Update profile ────────────────────────────────────────────────────

    function test_updateProfile_success() public {
        _storeDefaultStableProfile();

        string[] memory newChosen = new string[](3);
        newChosen[0] = "dishonest";
        newChosen[1] = "honest";
        newChosen[2] = "honest";

        int256[] memory newPayoffs = new int256[](3);
        newPayoffs[0] = 60e18;
        newPayoffs[1] = 10e18;
        newPayoffs[2] = 10e18;

        nash.updateProfile(PROFILE_1, newChosen, newPayoffs, 80e18, false);

        (,, string[] memory chosen, int256[] memory payoffs, int256 total, bool stable,) = nash.getProfile(PROFILE_1);
        assertEq(keccak256(bytes(chosen[0])), keccak256(bytes("dishonest")));
        assertEq(payoffs[0], 60e18);
        assertEq(total, 80e18);
        assertFalse(stable);
    }

    function test_updateProfile_notFound_reverts() public {
        string[] memory c = new string[](1);
        c[0] = "s";
        int256[] memory p = new int256[](1);

        vm.expectRevert(PactNashEquilibrium.ProfileNotFound.selector);
        nash.updateProfile(PROFILE_1, c, p, 0, true);
    }

    function test_updateProfile_chosenMismatch_reverts() public {
        _storeDefaultStableProfile();

        string[] memory c = new string[](2); // should be 3
        c[0] = "s";
        c[1] = "s";
        int256[] memory p = new int256[](3);

        vm.expectRevert(PactNashEquilibrium.LengthMismatch.selector);
        nash.updateProfile(PROFILE_1, c, p, 0, true);
    }

    function test_updateProfile_payoffsMismatch_reverts() public {
        _storeDefaultStableProfile();

        string[] memory c = new string[](3);
        c[0] = "s";
        c[1] = "s";
        c[2] = "s";
        int256[] memory p = new int256[](2); // should be 3

        vm.expectRevert(PactNashEquilibrium.LengthMismatch.selector);
        nash.updateProfile(PROFILE_1, c, p, 0, true);
    }

    // ── Active profile ────────────────────────────────────────────────────

    function test_setActiveProfile_stable() public {
        _storeDefaultStableProfile();
        nash.setActiveProfile(PROFILE_1);
        assertEq(nash.activeProfileId(), PROFILE_1);
    }

    function test_setActiveProfile_notFound_reverts() public {
        vm.expectRevert(PactNashEquilibrium.ProfileNotFound.selector);
        nash.setActiveProfile(PROFILE_1);
    }

    function test_setActiveProfile_unstable_reverts() public {
        _storeUnstableProfile();
        vm.expectRevert(PactNashEquilibrium.ProfileNotStable.selector);
        nash.setActiveProfile(PROFILE_UNSTABLE);
    }

    function test_getActiveProfile() public {
        _storeDefaultStableProfile();
        nash.setActiveProfile(PROFILE_1);

        (bytes32 id, string[] memory players,, int256[] memory payoffs, int256 total, bool stable) =
            nash.getActiveProfile();
        assertEq(id, PROFILE_1);
        assertEq(players.length, 3);
        assertEq(payoffs.length, 3);
        assertEq(total, 95e18);
        assertTrue(stable);
    }

    function test_getActiveProfile_noActive_reverts() public {
        vm.expectRevert(PactNashEquilibrium.ProfileNotFound.selector);
        nash.getActiveProfile();
    }

    function test_isEquilibriumStable_noProfile() public view {
        assertFalse(nash.isEquilibriumStable());
    }

    function test_isEquilibriumStable_stableProfile() public {
        _storeDefaultStableProfile();
        nash.setActiveProfile(PROFILE_1);
        assertTrue(nash.isEquilibriumStable());
    }

    // ── Incentive params ──────────────────────────────────────────────────

    function test_setIncentiveParams_success() public {
        nash.setIncentiveParams(7000, 1000, 1000, 1000, 200e6, 1000e6, 5);

        (uint16 w, uint16 v, uint16 t, uint16 i, uint256 minStake, uint256 penalty, uint256 collusionThresh,) =
            nash.incentiveParams();
        assertEq(w, 7000);
        assertEq(v, 1000);
        assertEq(t, 1000);
        assertEq(i, 1000);
        assertEq(minStake, 200e6);
        assertEq(penalty, 1000e6);
        assertEq(collusionThresh, 5);
    }

    function test_setIncentiveParams_invalidBps_reverts() public {
        vm.expectRevert(PactNashEquilibrium.InvalidBps.selector);
        nash.setIncentiveParams(7000, 1000, 1000, 500, 200e6, 1000e6, 5); // sums to 9500
    }

    function test_setIncentiveParams_unauthorized_reverts() public {
        vm.prank(stranger);
        vm.expectRevert(PactNashEquilibrium.UnauthorizedUpdater.selector);
        nash.setIncentiveParams(8500, 500, 500, 500, 100e6, 500e6, 3);
    }

    // ── View helpers ──────────────────────────────────────────────────────

    function test_isStakeSufficient() public view {
        assertTrue(nash.isStakeSufficient(100e6));
        assertTrue(nash.isStakeSufficient(200e6));
        assertFalse(nash.isStakeSufficient(99e6));
        assertFalse(nash.isStakeSufficient(0));
    }

    function test_getCollusionThreshold() public view {
        assertEq(nash.getCollusionThreshold(), 3);
    }

    function test_getCollusionThreshold_afterUpdate() public {
        nash.setIncentiveParams(8500, 500, 500, 500, 100e6, 500e6, 7);
        assertEq(nash.getCollusionThreshold(), 7);
    }

    // ── Multiple profiles ─────────────────────────────────────────────────

    function test_multipleProfiles() public {
        _storeDefaultStableProfile();
        _storeUnstableProfile();
        assertEq(nash.profileCount(), 2);
        assertEq(nash.profileIdAt(0), PROFILE_1);
        assertEq(nash.profileIdAt(1), PROFILE_UNSTABLE);
    }

    function test_switchActiveProfile() public {
        _storeDefaultStableProfile();

        // Store a second stable profile
        string[] memory players = new string[](2);
        players[0] = "issuer";
        players[1] = "worker";
        string[] memory strategies = new string[](2);
        strategies[0] = "honest";
        strategies[1] = "dishonest";
        string[] memory chosen = new string[](2);
        chosen[0] = "honest";
        chosen[1] = "honest";
        int256[] memory payoffs = new int256[](2);
        payoffs[0] = 50e18;
        payoffs[1] = 50e18;
        nash.storeProfile(PROFILE_2, players, strategies, chosen, payoffs, 100e18, true);

        nash.setActiveProfile(PROFILE_1);
        assertEq(nash.activeProfileId(), PROFILE_1);

        nash.setActiveProfile(PROFILE_2);
        assertEq(nash.activeProfileId(), PROFILE_2);

        (bytes32 id,,,,, bool stable) = nash.getActiveProfile();
        assertEq(id, PROFILE_2);
        assertTrue(stable);
    }

    // ── Events ────────────────────────────────────────────────────────────

    function test_emitsProfileStored() public {
        string[] memory players = new string[](1);
        players[0] = "p";
        string[] memory strategies = new string[](1);
        strategies[0] = "s";
        string[] memory chosen = new string[](1);
        chosen[0] = "s";
        int256[] memory payoffs = new int256[](1);
        payoffs[0] = 42e18;

        vm.expectEmit(true, false, false, true);
        emit PactNashEquilibrium.ProfileStored(PROFILE_1, true, 42e18);
        nash.storeProfile(PROFILE_1, players, strategies, chosen, payoffs, 42e18, true);
    }

    function test_emitsActiveProfileChanged() public {
        _storeDefaultStableProfile();

        vm.expectEmit(true, true, false, false);
        emit PactNashEquilibrium.ActiveProfileChanged(bytes32(0), PROFILE_1);
        nash.setActiveProfile(PROFILE_1);
    }

    function test_emitsIncentiveParamsUpdated() public {
        vm.expectEmit(false, false, false, true);
        emit PactNashEquilibrium.IncentiveParamsUpdated(7000, 1000, 1500, 500, 50e6, 200e6, 4);
        nash.setIncentiveParams(7000, 1000, 1500, 500, 50e6, 200e6, 4);
    }

    // ── Negative payoffs (penalty scenarios) ──────────────────────────────

    function test_negativePayoffs() public {
        string[] memory players = new string[](2);
        players[0] = "attacker";
        players[1] = "victim";
        string[] memory strategies = new string[](2);
        strategies[0] = "honest";
        strategies[1] = "exploit";
        string[] memory chosen = new string[](2);
        chosen[0] = "exploit";
        chosen[1] = "honest";
        int256[] memory payoffs = new int256[](2);
        payoffs[0] = -100e18; // attacker penalised
        payoffs[1] = 50e18;

        nash.storeProfile(PROFILE_2, players, strategies, chosen, payoffs, -50e18, false);

        (,,, int256[] memory p, int256 total, bool stable,) = nash.getProfile(PROFILE_2);
        assertEq(p[0], -100e18);
        assertEq(p[1], 50e18);
        assertEq(total, -50e18);
        assertFalse(stable);
    }

    // ── getProfile not found ──────────────────────────────────────────────

    function test_getProfile_notFound_reverts() public {
        vm.expectRevert(PactNashEquilibrium.ProfileNotFound.selector);
        nash.getProfile(PROFILE_1);
    }
}
