// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {PactFormalVerification} from "../src/PactFormalVerification.sol";

contract PactFormalVerificationTest is Test {
    PactFormalVerification fv;
    address admin;
    address auditor1;
    address auditor2;
    address nonAuditor;

    bytes32 locationCircuit;
    bytes32 completionCircuit;
    bytes32 identityCircuit;
    bytes32 reputationCircuit;

    function setUp() public {
        admin = address(this);
        auditor1 = makeAddr("auditor1");
        auditor2 = makeAddr("auditor2");
        nonAuditor = makeAddr("nonAuditor");

        fv = new PactFormalVerification();

        // Grant auditor roles
        fv.grantRole(fv.AUDITOR_ROLE(), auditor1);
        fv.grantRole(fv.AUDITOR_ROLE(), auditor2);

        // Register standard circuits
        locationCircuit = fv.registerCircuit("location", "1.0.0");
        completionCircuit = fv.registerCircuit("completion", "1.0.0");
        identityCircuit = fv.registerCircuit("identity", "1.0.0");
        reputationCircuit = fv.registerCircuit("reputation", "1.0.0");
    }

    // ── Circuit Registration ────────────────────────────────────────

    function test_registerCircuit() public view {
        PactFormalVerification.CircuitInfo memory info = fv.getCircuit(locationCircuit);
        assertEq(info.name, "location");
        assertEq(info.version, "1.0.0");
        assertEq(info.registeredBy, admin);
        assertTrue(info.active);
        assertEq(fv.getCircuitCount(), 4);
    }

    function test_registerCircuit_deterministicId() public view {
        bytes32 expected = keccak256(abi.encodePacked("location", "1.0.0"));
        assertEq(locationCircuit, expected);
    }

    function test_registerCircuit_emptyName_reverts() public {
        vm.expectRevert(PactFormalVerification.EmptyName.selector);
        fv.registerCircuit("", "1.0.0");
    }

    function test_registerCircuit_emptyVersion_reverts() public {
        vm.expectRevert(PactFormalVerification.EmptyVersion.selector);
        fv.registerCircuit("test", "");
    }

    function test_registerCircuit_duplicate_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(PactFormalVerification.CircuitAlreadyRegistered.selector, locationCircuit));
        fv.registerCircuit("location", "1.0.0");
    }

    function test_registerCircuit_nonAdmin_reverts() public {
        vm.prank(nonAuditor);
        vm.expectRevert();
        fv.registerCircuit("test", "1.0.0");
    }

    function test_registerCircuit_sameNameDifferentVersion() public {
        bytes32 cid = fv.registerCircuit("location", "2.0.0");
        PactFormalVerification.CircuitInfo memory info = fv.getCircuit(cid);
        assertEq(info.version, "2.0.0");
        assertEq(fv.getCircuitCount(), 5);
    }

    // ── Circuit Deactivation ────────────────────────────────────────

    function test_deactivateCircuit() public {
        fv.deactivateCircuit(locationCircuit);
        PactFormalVerification.CircuitInfo memory info = fv.getCircuit(locationCircuit);
        assertFalse(info.active);
    }

    function test_deactivateCircuit_notRegistered_reverts() public {
        bytes32 fake = keccak256("fake");
        vm.expectRevert(abi.encodeWithSelector(PactFormalVerification.CircuitNotRegistered.selector, fake));
        fv.deactivateCircuit(fake);
    }

    function test_deactivateCircuit_alreadyInactive_reverts() public {
        fv.deactivateCircuit(locationCircuit);
        vm.expectRevert(abi.encodeWithSelector(PactFormalVerification.CircuitNotActive.selector, locationCircuit));
        fv.deactivateCircuit(locationCircuit);
    }

    function test_deactivateCircuit_nonAdmin_reverts() public {
        vm.prank(nonAuditor);
        vm.expectRevert();
        fv.deactivateCircuit(locationCircuit);
    }

    // ── Formal Proof Submission ─────────────────────────────────────

    function test_submitProof_soundness() public {
        string[] memory assumptions = new string[](2);
        assumptions[0] = "Constraint validity approximates statement validity.";
        assumptions[1] = "Single adversarial mutation is representative.";

        vm.prank(auditor1);
        fv.submitProof(
            locationCircuit,
            PactFormalVerification.SecurityProperty.Soundness,
            true,
            "Honest statement accepted and adversarial mutation rejected.",
            assumptions
        );

        assertEq(fv.getCircuitProofCount(locationCircuit), 1);
        assertTrue(fv.isPropertySatisfied(locationCircuit, PactFormalVerification.SecurityProperty.Soundness));
        assertFalse(fv.isFullyVerified(locationCircuit));
    }

    function test_submitProof_completeness() public {
        string[] memory assumptions = new string[](1);
        assumptions[0] = "Given proof artifact corresponds to an honest prover run.";

        vm.prank(auditor1);
        fv.submitProof(
            locationCircuit,
            PactFormalVerification.SecurityProperty.Completeness,
            true,
            "Well-formed statement accepted by verifier simulation.",
            assumptions
        );

        assertTrue(fv.isPropertySatisfied(locationCircuit, PactFormalVerification.SecurityProperty.Completeness));
    }

    function test_submitProof_zeroKnowledge() public {
        string[] memory assumptions = new string[](1);
        assumptions[0] = "Leakage is approximated by static artifact inspection.";

        vm.prank(auditor2);
        fv.submitProof(
            locationCircuit,
            PactFormalVerification.SecurityProperty.ZeroKnowledge,
            true,
            "Proof artifact shape is valid and no witness leakage markers detected.",
            assumptions
        );

        assertTrue(fv.isPropertySatisfied(locationCircuit, PactFormalVerification.SecurityProperty.ZeroKnowledge));
    }

    function test_submitProof_allThree_fullyVerified() public {
        _submitAllThreeProperties(locationCircuit, auditor1);
        assertTrue(fv.isFullyVerified(locationCircuit));
    }

    function test_submitProof_emitsFormalProofSubmitted() public {
        string[] memory assumptions = new string[](0);

        vm.prank(auditor1);
        vm.expectEmit(true, true, true, true);
        emit PactFormalVerification.FormalProofSubmitted(
            locationCircuit,
            PactFormalVerification.SecurityProperty.Soundness,
            true,
            auditor1
        );
        fv.submitProof(locationCircuit, PactFormalVerification.SecurityProperty.Soundness, true, "OK", assumptions);
    }

    function test_submitProof_emitsCircuitFullyVerified() public {
        string[] memory assumptions = new string[](0);

        vm.prank(auditor1);
        fv.submitProof(locationCircuit, PactFormalVerification.SecurityProperty.Soundness, true, "OK", assumptions);
        vm.prank(auditor1);
        fv.submitProof(locationCircuit, PactFormalVerification.SecurityProperty.Completeness, true, "OK", assumptions);

        vm.prank(auditor1);
        vm.expectEmit(true, false, false, false);
        emit PactFormalVerification.CircuitFullyVerified(locationCircuit, 0);
        fv.submitProof(locationCircuit, PactFormalVerification.SecurityProperty.ZeroKnowledge, true, "OK", assumptions);
    }

    function test_submitProof_nonAuditor_reverts() public {
        string[] memory assumptions = new string[](0);
        vm.prank(nonAuditor);
        vm.expectRevert();
        fv.submitProof(locationCircuit, PactFormalVerification.SecurityProperty.Soundness, true, "OK", assumptions);
    }

    function test_submitProof_inactiveCircuit_reverts() public {
        fv.deactivateCircuit(locationCircuit);
        string[] memory assumptions = new string[](0);
        vm.prank(auditor1);
        vm.expectRevert(abi.encodeWithSelector(PactFormalVerification.CircuitNotActive.selector, locationCircuit));
        fv.submitProof(locationCircuit, PactFormalVerification.SecurityProperty.Soundness, true, "OK", assumptions);
    }

    function test_submitProof_notRegistered_reverts() public {
        bytes32 fake = keccak256("fake");
        string[] memory assumptions = new string[](0);
        vm.prank(auditor1);
        vm.expectRevert(abi.encodeWithSelector(PactFormalVerification.CircuitNotRegistered.selector, fake));
        fv.submitProof(fake, PactFormalVerification.SecurityProperty.Soundness, true, "OK", assumptions);
    }

    function test_submitProof_emptyDetails_reverts() public {
        string[] memory assumptions = new string[](0);
        vm.prank(auditor1);
        vm.expectRevert(PactFormalVerification.EmptyDetails.selector);
        fv.submitProof(locationCircuit, PactFormalVerification.SecurityProperty.Soundness, true, "", assumptions);
    }

    function test_submitProof_notSatisfied() public {
        string[] memory assumptions = new string[](0);
        vm.prank(auditor1);
        fv.submitProof(locationCircuit, PactFormalVerification.SecurityProperty.Soundness, false, "Failed soundness check", assumptions);

        assertFalse(fv.isPropertySatisfied(locationCircuit, PactFormalVerification.SecurityProperty.Soundness));
        assertEq(fv.getCircuitProofCount(locationCircuit), 1);
    }

    function test_submitProof_satisfiedAfterNotSatisfied() public {
        string[] memory assumptions = new string[](0);

        // First: not satisfied
        vm.prank(auditor1);
        fv.submitProof(locationCircuit, PactFormalVerification.SecurityProperty.Soundness, false, "Failed first attempt", assumptions);
        assertFalse(fv.isPropertySatisfied(locationCircuit, PactFormalVerification.SecurityProperty.Soundness));

        // Second: satisfied
        vm.prank(auditor2);
        fv.submitProof(locationCircuit, PactFormalVerification.SecurityProperty.Soundness, true, "Passed second attempt", assumptions);
        assertTrue(fv.isPropertySatisfied(locationCircuit, PactFormalVerification.SecurityProperty.Soundness));
        assertEq(fv.getCircuitProofCount(locationCircuit), 2);
    }

    function test_submitProof_multipleAuditors() public {
        string[] memory assumptions = new string[](0);

        vm.prank(auditor1);
        fv.submitProof(locationCircuit, PactFormalVerification.SecurityProperty.Soundness, true, "Auditor1 soundness OK", assumptions);

        vm.prank(auditor2);
        fv.submitProof(locationCircuit, PactFormalVerification.SecurityProperty.Soundness, true, "Auditor2 soundness OK", assumptions);

        assertEq(fv.getCircuitProofCount(locationCircuit), 2);
        assertEq(fv.getAuditorReportCount(auditor1), 1);
        assertEq(fv.getAuditorReportCount(auditor2), 1);
    }

    // ── Fully verified across multiple circuits ─────────────────────

    function test_multipleCircuits_independentVerification() public {
        _submitAllThreeProperties(locationCircuit, auditor1);
        _submitAllThreeProperties(completionCircuit, auditor2);

        assertTrue(fv.isFullyVerified(locationCircuit));
        assertTrue(fv.isFullyVerified(completionCircuit));
        assertFalse(fv.isFullyVerified(identityCircuit));
        assertFalse(fv.isFullyVerified(reputationCircuit));
    }

    function test_allFourCircuits_fullyVerified() public {
        _submitAllThreeProperties(locationCircuit, auditor1);
        _submitAllThreeProperties(completionCircuit, auditor1);
        _submitAllThreeProperties(identityCircuit, auditor2);
        _submitAllThreeProperties(reputationCircuit, auditor2);

        assertTrue(fv.isFullyVerified(locationCircuit));
        assertTrue(fv.isFullyVerified(completionCircuit));
        assertTrue(fv.isFullyVerified(identityCircuit));
        assertTrue(fv.isFullyVerified(reputationCircuit));
    }

    // ── Queries ─────────────────────────────────────────────────────

    function test_getReport() public {
        _submitAllThreeProperties(locationCircuit, auditor1);

        PactFormalVerification.VerificationReport memory report = fv.getReport(locationCircuit);
        assertEq(report.circuitId, locationCircuit);
        assertTrue(report.verified);
        assertEq(report.proofCount, 3);
        assertGt(report.lastUpdated, 0);
    }

    function test_getReport_noProofs() public view {
        PactFormalVerification.VerificationReport memory report = fv.getReport(locationCircuit);
        assertFalse(report.verified);
        assertEq(report.proofCount, 0);
        assertEq(report.lastUpdated, 0);
    }

    function test_getReport_notRegistered_reverts() public {
        bytes32 fake = keccak256("fake");
        vm.expectRevert(abi.encodeWithSelector(PactFormalVerification.CircuitNotRegistered.selector, fake));
        fv.getReport(fake);
    }

    function test_getCircuitProofs_pagination() public {
        string[] memory assumptions = new string[](0);

        // Submit 5 proofs
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(auditor1);
            fv.submitProof(locationCircuit, PactFormalVerification.SecurityProperty.Soundness, true, string(abi.encodePacked("Proof ", vm.toString(i))), assumptions);
        }

        // Page 1 (offset 0, limit 3)
        PactFormalVerification.FormalProof[] memory page1 = fv.getCircuitProofs(locationCircuit, 0, 3);
        assertEq(page1.length, 3);

        // Page 2 (offset 3, limit 3)
        PactFormalVerification.FormalProof[] memory page2 = fv.getCircuitProofs(locationCircuit, 3, 3);
        assertEq(page2.length, 2);

        // Out of range
        PactFormalVerification.FormalProof[] memory empty = fv.getCircuitProofs(locationCircuit, 10, 5);
        assertEq(empty.length, 0);
    }

    function test_getCircuitIds_pagination() public view {
        bytes32[] memory page1 = fv.getCircuitIds(0, 2);
        assertEq(page1.length, 2);
        assertEq(page1[0], locationCircuit);
        assertEq(page1[1], completionCircuit);

        bytes32[] memory page2 = fv.getCircuitIds(2, 10);
        assertEq(page2.length, 2);
        assertEq(page2[0], identityCircuit);
        assertEq(page2[1], reputationCircuit);
    }

    function test_getPropertyStatus() public {
        string[] memory assumptions = new string[](0);

        vm.prank(auditor1);
        fv.submitProof(locationCircuit, PactFormalVerification.SecurityProperty.Soundness, true, "OK", assumptions);
        vm.prank(auditor1);
        fv.submitProof(locationCircuit, PactFormalVerification.SecurityProperty.ZeroKnowledge, true, "OK", assumptions);

        (bool soundness, bool completeness, bool zk) = fv.getPropertyStatus(locationCircuit);
        assertTrue(soundness);
        assertFalse(completeness);
        assertTrue(zk);
    }

    function test_getAuditorReportCount() public {
        _submitAllThreeProperties(locationCircuit, auditor1);
        _submitAllThreeProperties(completionCircuit, auditor1);

        assertEq(fv.getAuditorReportCount(auditor1), 6);
        assertEq(fv.getAuditorReportCount(auditor2), 0);
    }

    // ── Proof data integrity ────────────────────────────────────────

    function test_proofDataIntegrity() public {
        string[] memory assumptions = new string[](2);
        assumptions[0] = "Assumption A";
        assumptions[1] = "Assumption B";

        vm.warp(1700000000);
        vm.prank(auditor1);
        fv.submitProof(locationCircuit, PactFormalVerification.SecurityProperty.Soundness, true, "Detailed analysis", assumptions);

        PactFormalVerification.FormalProof[] memory proofs = fv.getCircuitProofs(locationCircuit, 0, 1);
        assertEq(proofs.length, 1);
        assertEq(uint256(proofs[0].property), uint256(PactFormalVerification.SecurityProperty.Soundness));
        assertTrue(proofs[0].satisfied);
        assertEq(proofs[0].details, "Detailed analysis");
        assertEq(proofs[0].assumptions.length, 2);
        assertEq(proofs[0].assumptions[0], "Assumption A");
        assertEq(proofs[0].assumptions[1], "Assumption B");
        assertEq(proofs[0].auditor, auditor1);
        assertEq(proofs[0].checkedAt, 1700000000);
    }

    // ── Edge cases ──────────────────────────────────────────────────

    function test_satisfiedStaysSatisfied() public {
        string[] memory assumptions = new string[](0);

        // Satisfied first
        vm.prank(auditor1);
        fv.submitProof(locationCircuit, PactFormalVerification.SecurityProperty.Soundness, true, "Passed", assumptions);
        assertTrue(fv.isPropertySatisfied(locationCircuit, PactFormalVerification.SecurityProperty.Soundness));

        // Submit not-satisfied later — property stays satisfied (append-only)
        vm.prank(auditor2);
        fv.submitProof(locationCircuit, PactFormalVerification.SecurityProperty.Soundness, false, "Different analysis - failed", assumptions);
        assertTrue(fv.isPropertySatisfied(locationCircuit, PactFormalVerification.SecurityProperty.Soundness));
    }

    function test_fullyVerifiedStaysVerified() public {
        _submitAllThreeProperties(locationCircuit, auditor1);
        assertTrue(fv.isFullyVerified(locationCircuit));

        // Even after a failing proof for a property, fully verified stays true
        string[] memory assumptions = new string[](0);
        vm.prank(auditor2);
        fv.submitProof(locationCircuit, PactFormalVerification.SecurityProperty.Soundness, false, "Contested", assumptions);
        assertTrue(fv.isFullyVerified(locationCircuit));
    }

    function test_emptyAssumptions() public {
        string[] memory assumptions = new string[](0);
        vm.prank(auditor1);
        fv.submitProof(locationCircuit, PactFormalVerification.SecurityProperty.Soundness, true, "No assumptions", assumptions);

        PactFormalVerification.FormalProof[] memory proofs = fv.getCircuitProofs(locationCircuit, 0, 1);
        assertEq(proofs[0].assumptions.length, 0);
    }

    // ── Helpers ──────────────────────────────────────────────────────

    function _submitAllThreeProperties(bytes32 circuitId, address auditor) internal {
        string[] memory assumptions = new string[](1);
        assumptions[0] = "Standard assumption.";

        vm.prank(auditor);
        fv.submitProof(circuitId, PactFormalVerification.SecurityProperty.Soundness, true, "Soundness verified.", assumptions);
        vm.prank(auditor);
        fv.submitProof(circuitId, PactFormalVerification.SecurityProperty.Completeness, true, "Completeness verified.", assumptions);
        vm.prank(auditor);
        fv.submitProof(circuitId, PactFormalVerification.SecurityProperty.ZeroKnowledge, true, "Zero-knowledge verified.", assumptions);
    }
}
