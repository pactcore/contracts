// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PactCollusionDetection} from "../src/PactCollusionDetection.sol";

contract PactCollusionDetectionTest is Test {
    PactCollusionDetection public detector;
    address public owner = address(this);
    address public monitor = address(0xBEEF);
    address public alice = address(0x1);
    address public bob = address(0x2);
    address public charlie = address(0x3);
    address public dave = address(0x4);
    address public eve = address(0x5);
    address public unauthorized = address(0xDEAD);

    function setUp() public {
        detector = new PactCollusionDetection();
        detector.setAuthorizedMonitor(monitor, true);
    }

    // ── Constructor / Config ──────────────────────────────────────────

    function test_constructor_defaults() public view {
        (
            uint256 flagThreshold,
            uint256 penaltyThreshold,
            uint256 freezeThreshold,
            uint256 minConfidenceForFlag,
            uint256 basePenaltyAmount,
            uint64 decayPeriod
        ) = detector.config();

        assertEq(flagThreshold, 3);
        assertEq(penaltyThreshold, 5);
        assertEq(freezeThreshold, 10);
        assertEq(minConfidenceForFlag, 0.55e18);
        assertEq(basePenaltyAmount, 500e6);
        assertEq(decayPeriod, 30 days);
    }

    function test_setConfig() public {
        detector.setConfig(2, 4, 8, 0.6e18, 1000e6, 60 days);

        (
            uint256 flagThreshold,
            uint256 penaltyThreshold,
            uint256 freezeThreshold,
            uint256 minConfidenceForFlag,
            uint256 basePenaltyAmount,
            uint64 decayPeriod
        ) = detector.config();

        assertEq(flagThreshold, 2);
        assertEq(penaltyThreshold, 4);
        assertEq(freezeThreshold, 8);
        assertEq(minConfidenceForFlag, 0.6e18);
        assertEq(basePenaltyAmount, 1000e6);
        assertEq(decayPeriod, 60 days);
    }

    function test_setConfig_invalidThresholds_reverts() public {
        // flag must be > 0
        vm.expectRevert(PactCollusionDetection.InvalidThresholds.selector);
        detector.setConfig(0, 4, 8, 0.6e18, 1000e6, 60 days);

        // penalty must be > flag
        vm.expectRevert(PactCollusionDetection.InvalidThresholds.selector);
        detector.setConfig(5, 5, 8, 0.6e18, 1000e6, 60 days);

        // freeze must be > penalty
        vm.expectRevert(PactCollusionDetection.InvalidThresholds.selector);
        detector.setConfig(2, 4, 4, 0.6e18, 1000e6, 60 days);
    }

    function test_setConfig_confidenceTooHigh_reverts() public {
        vm.expectRevert(PactCollusionDetection.ConfidenceTooHigh.selector);
        detector.setConfig(2, 4, 8, 1.1e18, 1000e6, 60 days);
    }

    function test_setConfig_onlyOwner() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        detector.setConfig(2, 4, 8, 0.6e18, 1000e6, 60 days);
    }

    // ── Monitor Authorization ─────────────────────────────────────────

    function test_setAuthorizedMonitor() public {
        assertFalse(detector.authorizedMonitors(unauthorized));

        detector.setAuthorizedMonitor(unauthorized, true);
        assertTrue(detector.authorizedMonitors(unauthorized));

        detector.setAuthorizedMonitor(unauthorized, false);
        assertFalse(detector.authorizedMonitors(unauthorized));
    }

    function test_setAuthorizedMonitor_zeroAddress_reverts() public {
        vm.expectRevert(PactCollusionDetection.ZeroAddress.selector);
        detector.setAuthorizedMonitor(address(0), true);
    }

    function test_setAuthorizedMonitor_onlyOwner() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        detector.setAuthorizedMonitor(monitor, true);
    }

    // ── Signal Submission ─────────────────────────────────────────────

    function test_submitSignal_basic() public {
        address[] memory participants = new address[](2);
        participants[0] = alice;
        participants[1] = bob;

        vm.prank(monitor);
        uint256 signalId = detector.submitSignal(
            PactCollusionDetection.SignalType.RepeatedPairing,
            participants,
            0.7e18,
            keccak256("auction-1")
        );

        assertEq(signalId, 0);
        assertEq(detector.signalCount(), 1);

        (
            PactCollusionDetection.SignalType signalType,
            address[] memory parts,
            uint256 confidence,
            bytes32 auctionId,
            uint64 detectedAt,
            address reporter
        ) = detector.getSignal(0);

        assertEq(uint8(signalType), uint8(PactCollusionDetection.SignalType.RepeatedPairing));
        assertEq(parts.length, 2);
        assertEq(parts[0], alice);
        assertEq(parts[1], bob);
        assertEq(confidence, 0.7e18);
        assertEq(auctionId, keccak256("auction-1"));
        assertGt(detectedAt, 0);
        assertEq(reporter, monitor);
    }

    function test_submitSignal_ownerCanSubmit() public {
        address[] memory participants = new address[](1);
        participants[0] = alice;

        // Owner should also be able to submit (onlyMonitor allows owner)
        uint256 signalId = detector.submitSignal(
            PactCollusionDetection.SignalType.BidClustering,
            participants,
            0.8e18,
            keccak256("auction-2")
        );

        assertEq(signalId, 0);
    }

    function test_submitSignal_unauthorized_reverts() public {
        address[] memory participants = new address[](1);
        participants[0] = alice;

        vm.prank(unauthorized);
        vm.expectRevert(PactCollusionDetection.UnauthorizedMonitor.selector);
        detector.submitSignal(
            PactCollusionDetection.SignalType.BidClustering,
            participants,
            0.8e18,
            keccak256("auction-2")
        );
    }

    function test_submitSignal_emptyParticipants_reverts() public {
        address[] memory participants = new address[](0);

        vm.prank(monitor);
        vm.expectRevert(PactCollusionDetection.EmptyParticipants.selector);
        detector.submitSignal(
            PactCollusionDetection.SignalType.BidClustering,
            participants,
            0.8e18,
            keccak256("auction-2")
        );
    }

    function test_submitSignal_tooManyParticipants_reverts() public {
        address[] memory participants = new address[](21);
        for (uint256 i = 0; i < 21; i++) {
            participants[i] = address(uint160(100 + i));
        }

        vm.prank(monitor);
        vm.expectRevert(PactCollusionDetection.TooManyParticipants.selector);
        detector.submitSignal(
            PactCollusionDetection.SignalType.BidClustering,
            participants,
            0.8e18,
            keccak256("auction-2")
        );
    }

    function test_submitSignal_confidenceTooHigh_reverts() public {
        address[] memory participants = new address[](1);
        participants[0] = alice;

        vm.prank(monitor);
        vm.expectRevert(PactCollusionDetection.ConfidenceTooHigh.selector);
        detector.submitSignal(
            PactCollusionDetection.SignalType.BidClustering,
            participants,
            1.1e18,
            keccak256("auction-2")
        );
    }

    function test_submitSignal_zeroParticipant_reverts() public {
        address[] memory participants = new address[](1);
        participants[0] = address(0);

        vm.prank(monitor);
        vm.expectRevert(PactCollusionDetection.ZeroAddress.selector);
        detector.submitSignal(
            PactCollusionDetection.SignalType.BidClustering,
            participants,
            0.8e18,
            keccak256("auction-2")
        );
    }

    function test_submitSignal_allSignalTypes() public {
        address[] memory participants = new address[](2);
        participants[0] = alice;
        participants[1] = bob;

        vm.startPrank(monitor);

        detector.submitSignal(
            PactCollusionDetection.SignalType.RepeatedPairing,
            participants, 0.6e18, keccak256("a1")
        );
        detector.submitSignal(
            PactCollusionDetection.SignalType.BidClustering,
            participants, 0.7e18, keccak256("a2")
        );
        detector.submitSignal(
            PactCollusionDetection.SignalType.TimingCorrelation,
            participants, 0.8e18, keccak256("a3")
        );

        vm.stopPrank();

        assertEq(detector.signalCount(), 3);

        // Check each type
        (PactCollusionDetection.SignalType t0,,,,, ) = detector.getSignal(0);
        (PactCollusionDetection.SignalType t1,,,,, ) = detector.getSignal(1);
        (PactCollusionDetection.SignalType t2,,,,, ) = detector.getSignal(2);

        assertEq(uint8(t0), uint8(PactCollusionDetection.SignalType.RepeatedPairing));
        assertEq(uint8(t1), uint8(PactCollusionDetection.SignalType.BidClustering));
        assertEq(uint8(t2), uint8(PactCollusionDetection.SignalType.TimingCorrelation));
    }

    function test_getSignal_notFound_reverts() public {
        vm.expectRevert(PactCollusionDetection.SignalNotFound.selector);
        detector.getSignal(0);
    }

    // ── Actor Status Progression ──────────────────────────────────────

    function test_actorStatus_clean_initially() public view {
        (uint256 totalSignals, uint256 aggConf, uint256 penalty, PactCollusionDetection.ActorStatus status, ) =
            detector.actorProfiles(alice);

        assertEq(totalSignals, 0);
        assertEq(aggConf, 0);
        assertEq(penalty, 0);
        assertEq(uint8(status), uint8(PactCollusionDetection.ActorStatus.Clean));
    }

    function test_actorStatus_flagged_after_threshold() public {
        // Default flagThreshold = 3, minConfidence = 0.55e18
        _submitSignalsForActor(alice, 3, 0.6e18);

        (, , , PactCollusionDetection.ActorStatus status, ) = detector.actorProfiles(alice);
        assertEq(uint8(status), uint8(PactCollusionDetection.ActorStatus.Flagged));
        assertTrue(detector.isActorFlagged(alice));
        assertTrue(detector.isActorAllowed(alice)); // flagged but not frozen
    }

    function test_actorStatus_notFlagged_lowConfidence() public {
        // Signals with confidence below threshold → stay clean
        _submitSignalsForActor(alice, 5, 0.3e18);

        (, , , PactCollusionDetection.ActorStatus status, ) = detector.actorProfiles(alice);
        assertEq(uint8(status), uint8(PactCollusionDetection.ActorStatus.Clean));
        assertFalse(detector.isActorFlagged(alice));
    }

    function test_actorStatus_penalized_after_threshold() public {
        // Default penaltyThreshold = 5
        _submitSignalsForActor(alice, 5, 0.7e18);

        (, , uint256 penalty, PactCollusionDetection.ActorStatus status, ) = detector.actorProfiles(alice);
        assertEq(uint8(status), uint8(PactCollusionDetection.ActorStatus.Penalized));
        assertEq(penalty, 500e6); // basePenaltyAmount
        assertTrue(detector.isActorFlagged(alice));
        assertTrue(detector.isActorAllowed(alice)); // penalized but not frozen
    }

    function test_actorStatus_frozen_after_threshold() public {
        // Default freezeThreshold = 10
        _submitSignalsForActor(alice, 10, 0.8e18);

        (, , , PactCollusionDetection.ActorStatus status, ) = detector.actorProfiles(alice);
        assertEq(uint8(status), uint8(PactCollusionDetection.ActorStatus.Frozen));
        assertTrue(detector.isActorFlagged(alice));
        assertFalse(detector.isActorAllowed(alice)); // frozen = not allowed
    }

    function test_actorStatus_progression() public {
        // Submit signals one by one and verify progression
        // Signals 1-2: Clean
        _submitSignalsForActor(alice, 2, 0.7e18);
        (, , , PactCollusionDetection.ActorStatus s1, ) = detector.actorProfiles(alice);
        assertEq(uint8(s1), uint8(PactCollusionDetection.ActorStatus.Clean));

        // Signal 3: Flagged
        _submitSignalsForActor(alice, 1, 0.7e18);
        (, , , PactCollusionDetection.ActorStatus s2, ) = detector.actorProfiles(alice);
        assertEq(uint8(s2), uint8(PactCollusionDetection.ActorStatus.Flagged));

        // Signals 4-5: Penalized (at signal 5)
        _submitSignalsForActor(alice, 2, 0.7e18);
        (, , , PactCollusionDetection.ActorStatus s3, ) = detector.actorProfiles(alice);
        assertEq(uint8(s3), uint8(PactCollusionDetection.ActorStatus.Penalized));

        // Signals 6-10: Frozen (at signal 10)
        _submitSignalsForActor(alice, 5, 0.7e18);
        (, , , PactCollusionDetection.ActorStatus s4, ) = detector.actorProfiles(alice);
        assertEq(uint8(s4), uint8(PactCollusionDetection.ActorStatus.Frozen));
    }

    // ── Actor Signal Tracking ─────────────────────────────────────────

    function test_actorSignalIds_tracked() public {
        address[] memory participants = new address[](2);
        participants[0] = alice;
        participants[1] = bob;

        vm.startPrank(monitor);

        detector.submitSignal(PactCollusionDetection.SignalType.BidClustering, participants, 0.6e18, keccak256("a1"));
        detector.submitSignal(PactCollusionDetection.SignalType.BidClustering, participants, 0.7e18, keccak256("a2"));

        vm.stopPrank();

        uint256[] memory aliceSignals = detector.getActorSignalIds(alice);
        uint256[] memory bobSignals = detector.getActorSignalIds(bob);

        assertEq(aliceSignals.length, 2);
        assertEq(bobSignals.length, 2);
        assertEq(aliceSignals[0], 0);
        assertEq(aliceSignals[1], 1);
    }

    function test_actorSignalCount() public {
        _submitSignalsForActor(alice, 4, 0.6e18);
        assertEq(detector.getActorSignalCount(alice), 4);
        assertEq(detector.getActorSignalCount(bob), 0);
    }

    function test_actorAverageConfidence() public {
        address[] memory participants = new address[](1);
        participants[0] = alice;

        vm.startPrank(monitor);

        detector.submitSignal(PactCollusionDetection.SignalType.BidClustering, participants, 0.6e18, keccak256("a1"));
        detector.submitSignal(PactCollusionDetection.SignalType.BidClustering, participants, 0.8e18, keccak256("a2"));

        vm.stopPrank();

        uint256 avgConf = detector.getActorAverageConfidence(alice);
        assertEq(avgConf, 0.7e18); // (0.6 + 0.8) / 2

        // Zero signals → zero average
        assertEq(detector.getActorAverageConfidence(bob), 0);
    }

    // ── Reset Actor Status ────────────────────────────────────────────

    function test_resetActorStatus() public {
        _submitSignalsForActor(alice, 5, 0.7e18);

        (, , , PactCollusionDetection.ActorStatus statusBefore, ) = detector.actorProfiles(alice);
        assertEq(uint8(statusBefore), uint8(PactCollusionDetection.ActorStatus.Penalized));

        detector.resetActorStatus(alice);

        (uint256 totalSignals, uint256 aggConf, uint256 penalty, PactCollusionDetection.ActorStatus statusAfter, uint64 lastFlagged) =
            detector.actorProfiles(alice);

        assertEq(uint8(statusAfter), uint8(PactCollusionDetection.ActorStatus.Clean));
        assertEq(totalSignals, 0);
        assertEq(aggConf, 0);
        assertEq(penalty, 0);
        assertEq(lastFlagged, 0);

        // Signal IDs should be cleared
        assertEq(detector.getActorSignalIds(alice).length, 0);
    }

    function test_resetActorStatus_cleanActor_reverts() public {
        vm.expectRevert(PactCollusionDetection.ActorNotFlagged.selector);
        detector.resetActorStatus(alice);
    }

    function test_resetActorStatus_onlyOwner() public {
        _submitSignalsForActor(alice, 3, 0.7e18);

        vm.prank(unauthorized);
        vm.expectRevert();
        detector.resetActorStatus(alice);
    }

    // ── Collusion Cost Analysis ───────────────────────────────────────

    function test_computeCollusionCost_basic() public {
        vm.prank(monitor);
        detector.computeCollusionCost(100, 10);

        (uint256 networkSize, uint256 colluders, uint256 controlCostBps, uint256 expectedPenalty, uint64 computedAt) =
            detector.getCostAnalysis();

        assertEq(networkSize, 100);
        assertEq(colluders, 10);
        // (10/100)^2 * 10000 = 0.01 * 10000 = 100 bps (1%)
        assertEq(controlCostBps, 100);
        assertEq(expectedPenalty, 100 * 10); // 1000
        assertGt(computedAt, 0);
    }

    function test_computeCollusionCost_halfNetwork() public {
        vm.prank(monitor);
        detector.computeCollusionCost(100, 50);

        (, , uint256 controlCostBps, uint256 expectedPenalty, ) = detector.getCostAnalysis();

        // (50/100)^2 * 10000 = 0.25 * 10000 = 2500 bps (25%)
        assertEq(controlCostBps, 2500);
        assertEq(expectedPenalty, 2500 * 50);
    }

    function test_computeCollusionCost_fullNetwork() public {
        vm.prank(monitor);
        detector.computeCollusionCost(100, 100);

        (, , uint256 controlCostBps, , ) = detector.getCostAnalysis();

        // (100/100)^2 * 10000 = 10000 bps (100%)
        assertEq(controlCostBps, 10_000);
    }

    function test_computeCollusionCost_singleColluder() public {
        vm.prank(monitor);
        detector.computeCollusionCost(1000, 1);

        (, , uint256 controlCostBps, , ) = detector.getCostAnalysis();

        // (1/1000)^2 * 10000 ≈ 0 bps
        assertEq(controlCostBps, 0);
    }

    function test_computeCollusionCost_zeroNetwork_reverts() public {
        vm.prank(monitor);
        vm.expectRevert(PactCollusionDetection.InvalidNetworkSize.selector);
        detector.computeCollusionCost(0, 1);
    }

    function test_computeCollusionCost_zeroColluders_reverts() public {
        vm.prank(monitor);
        vm.expectRevert(PactCollusionDetection.ZeroColluders.selector);
        detector.computeCollusionCost(100, 0);
    }

    function test_computeCollusionCost_colludersExceedNetwork_reverts() public {
        vm.prank(monitor);
        vm.expectRevert(PactCollusionDetection.ColludersExceedNetwork.selector);
        detector.computeCollusionCost(10, 11);
    }

    function test_computeCollusionCost_unauthorized_reverts() public {
        vm.prank(unauthorized);
        vm.expectRevert(PactCollusionDetection.UnauthorizedMonitor.selector);
        detector.computeCollusionCost(100, 10);
    }

    // ── Multi-actor Isolation ─────────────────────────────────────────

    function test_multipleActors_independent() public {
        // Alice gets flagged, Bob stays clean
        _submitSignalsForActor(alice, 5, 0.7e18);
        _submitSignalsForActor(bob, 1, 0.7e18);

        (, , , PactCollusionDetection.ActorStatus aliceStatus, ) = detector.actorProfiles(alice);
        (, , , PactCollusionDetection.ActorStatus bobStatus, ) = detector.actorProfiles(bob);

        assertEq(uint8(aliceStatus), uint8(PactCollusionDetection.ActorStatus.Penalized));
        assertEq(uint8(bobStatus), uint8(PactCollusionDetection.ActorStatus.Clean));
    }

    function test_sharedSignal_affectsBothActors() public {
        address[] memory participants = new address[](3);
        participants[0] = alice;
        participants[1] = bob;
        participants[2] = charlie;

        vm.startPrank(monitor);
        for (uint256 i = 0; i < 3; i++) {
            detector.submitSignal(
                PactCollusionDetection.SignalType.TimingCorrelation,
                participants,
                0.7e18,
                keccak256(abi.encodePacked("auction-", i))
            );
        }
        vm.stopPrank();

        // All three should be flagged (3 signals each, above threshold)
        assertTrue(detector.isActorFlagged(alice));
        assertTrue(detector.isActorFlagged(bob));
        assertTrue(detector.isActorFlagged(charlie));
    }

    // ── Edge Cases ────────────────────────────────────────────────────

    function test_maxConfidence_accepted() public {
        address[] memory participants = new address[](1);
        participants[0] = alice;

        vm.prank(monitor);
        detector.submitSignal(
            PactCollusionDetection.SignalType.BidClustering,
            participants,
            1e18, // exactly 100%
            keccak256("auction-max")
        );

        (, , uint256 confidence, , , ) = detector.getSignal(0);
        assertEq(confidence, 1e18);
    }

    function test_zeroConfidence_accepted() public {
        address[] memory participants = new address[](1);
        participants[0] = alice;

        vm.prank(monitor);
        detector.submitSignal(
            PactCollusionDetection.SignalType.BidClustering,
            participants,
            0,
            keccak256("auction-zero")
        );

        (, , uint256 confidence, , , ) = detector.getSignal(0);
        assertEq(confidence, 0);
    }

    function test_maxParticipants_accepted() public {
        address[] memory participants = new address[](20);
        for (uint256 i = 0; i < 20; i++) {
            participants[i] = address(uint160(1000 + i));
        }

        vm.prank(monitor);
        detector.submitSignal(
            PactCollusionDetection.SignalType.TimingCorrelation,
            participants,
            0.5e18,
            keccak256("auction-large")
        );

        (, address[] memory parts, , , , ) = detector.getSignal(0);
        assertEq(parts.length, 20);
    }

    function test_multipleMonitors_canSubmit() public {
        address monitor2 = address(0xCAFE);
        detector.setAuthorizedMonitor(monitor2, true);

        address[] memory participants = new address[](1);
        participants[0] = alice;

        vm.prank(monitor);
        detector.submitSignal(PactCollusionDetection.SignalType.RepeatedPairing, participants, 0.6e18, keccak256("a1"));

        vm.prank(monitor2);
        detector.submitSignal(PactCollusionDetection.SignalType.BidClustering, participants, 0.7e18, keccak256("a2"));

        assertEq(detector.signalCount(), 2);

        (, , , , , address reporter1) = detector.getSignal(0);
        (, , , , , address reporter2) = detector.getSignal(1);
        assertEq(reporter1, monitor);
        assertEq(reporter2, monitor2);
    }

    function test_resetFrozenActor_allowsReFlag() public {
        // Freeze actor
        _submitSignalsForActor(alice, 10, 0.8e18);
        assertFalse(detector.isActorAllowed(alice));

        // Reset
        detector.resetActorStatus(alice);
        assertTrue(detector.isActorAllowed(alice));
        assertFalse(detector.isActorFlagged(alice));

        // Can be flagged again
        _submitSignalsForActor(alice, 3, 0.7e18);
        assertTrue(detector.isActorFlagged(alice));
    }

    function test_latestCostAnalysis_overwritten() public {
        vm.startPrank(monitor);

        detector.computeCollusionCost(100, 10);
        (, , uint256 cost1, , ) = detector.getCostAnalysis();
        assertEq(cost1, 100);

        detector.computeCollusionCost(200, 50);
        (uint256 ns2, uint256 c2, uint256 cost2, , ) = detector.getCostAnalysis();
        assertEq(ns2, 200);
        assertEq(c2, 50);
        // (50/200)^2 * 10000 = 0.0625 * 10000 = 625
        assertEq(cost2, 625);

        vm.stopPrank();
    }

    // ── Events ────────────────────────────────────────────────────────

    function test_emits_SignalSubmitted() public {
        address[] memory participants = new address[](2);
        participants[0] = alice;
        participants[1] = bob;

        vm.prank(monitor);
        vm.expectEmit(true, true, false, true);
        emit PactCollusionDetection.SignalSubmitted(
            0,
            PactCollusionDetection.SignalType.RepeatedPairing,
            keccak256("auction-1"),
            0.7e18,
            2
        );
        detector.submitSignal(PactCollusionDetection.SignalType.RepeatedPairing, participants, 0.7e18, keccak256("auction-1"));
    }

    function test_emits_ActorFlagged() public {
        address[] memory participants = new address[](1);
        participants[0] = alice;

        vm.startPrank(monitor);

        // Submit 2 signals (below threshold)
        detector.submitSignal(PactCollusionDetection.SignalType.BidClustering, participants, 0.6e18, keccak256("a1"));
        detector.submitSignal(PactCollusionDetection.SignalType.BidClustering, participants, 0.6e18, keccak256("a2"));

        // 3rd signal should trigger ActorFlagged
        vm.expectEmit(true, false, false, true);
        emit PactCollusionDetection.ActorFlagged(alice, 3, 0.6e18);
        detector.submitSignal(PactCollusionDetection.SignalType.BidClustering, participants, 0.6e18, keccak256("a3"));

        vm.stopPrank();
    }

    function test_emits_CostAnalysisUpdated() public {
        vm.prank(monitor);
        vm.expectEmit(false, false, false, true);
        emit PactCollusionDetection.CostAnalysisUpdated(100, 10, 100, 1000);
        detector.computeCollusionCost(100, 10);
    }

    function test_emits_MonitorAuthorizationChanged() public {
        vm.expectEmit(true, false, false, true);
        emit PactCollusionDetection.MonitorAuthorizationChanged(unauthorized, true);
        detector.setAuthorizedMonitor(unauthorized, true);
    }

    function test_emits_ActorStatusReset() public {
        _submitSignalsForActor(alice, 3, 0.7e18);

        vm.expectEmit(true, false, false, true);
        emit PactCollusionDetection.ActorStatusReset(alice, PactCollusionDetection.ActorStatus.Flagged);
        detector.resetActorStatus(alice);
    }

    function test_emits_ConfigUpdated() public {
        vm.expectEmit(false, false, false, false);
        emit PactCollusionDetection.ConfigUpdated();
        detector.setConfig(2, 4, 8, 0.6e18, 1000e6, 60 days);
    }

    // ── Helper ────────────────────────────────────────────────────────

    function _submitSignalsForActor(address actor, uint256 count, uint256 confidence) internal {
        address[] memory participants = new address[](1);
        participants[0] = actor;

        vm.startPrank(monitor);
        for (uint256 i = 0; i < count; i++) {
            detector.submitSignal(
                PactCollusionDetection.SignalType.RepeatedPairing,
                participants,
                confidence,
                keccak256(abi.encodePacked("auto-auction-", actor, i))
            );
        }
        vm.stopPrank();
    }}
