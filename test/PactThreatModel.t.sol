// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PactThreatModel} from "../src/PactThreatModel.sol";

contract PactThreatModelTest is Test {
    PactThreatModel public model;
    address public owner = address(this);
    address public auditor = address(0xBEEF);
    address public unauthorized = address(0xDEAD);

    bytes32 constant SYBIL_ID = keccak256("sybil-attack");
    bytes32 constant COLLUSION_ID = keccak256("collusion");
    bytes32 constant DDOS_ID = keccak256("ddos");
    bytes32 constant EXPLOIT_ID = keccak256("smart-contract-exploit");

    function setUp() public {
        model = new PactThreatModel();
        model.setAuthorizedAuditor(auditor, true);
    }

    // ── Helper ────────────────────────────────────────────────────────

    function _registerSybilThreat() internal {
        string[] memory mitigations = new string[](2);
        mitigations[0] = "DID-linked identity";
        mitigations[1] = "Stake-weighted anti-spam";

        vm.prank(auditor);
        model.registerThreat(
            SYBIL_ID,
            PactThreatModel.ThreatCategory.SybilAttack,
            PactThreatModel.Severity.Critical,
            "Adversaries create many pseudo-identities",
            mitigations,
            0.42e18
        );
    }

    function _registerCollusionThreat() internal {
        string[] memory mitigations = new string[](1);
        mitigations[0] = "Auction monitoring";

        vm.prank(auditor);
        model.registerThreat(
            COLLUSION_ID,
            PactThreatModel.ThreatCategory.Collusion,
            PactThreatModel.Severity.High,
            "Coordinated manipulation",
            mitigations,
            0.35e18
        );
    }

    function _registerDDoSThreat() internal {
        string[] memory mitigations = new string[](1);
        mitigations[0] = "Rate limiting";

        vm.prank(auditor);
        model.registerThreat(
            DDOS_ID,
            PactThreatModel.ThreatCategory.DDoS,
            PactThreatModel.Severity.High,
            "High-volume request floods",
            mitigations,
            0.36e18
        );
    }

    // ── Authorization ─────────────────────────────────────────────────

    function test_setAuthorizedAuditor() public {
        model.setAuthorizedAuditor(address(0x123), true);
        assertTrue(model.authorizedAuditors(address(0x123)));
    }

    function test_setAuthorizedAuditor_revert_zeroAddress() public {
        vm.expectRevert(PactThreatModel.ZeroAddress.selector);
        model.setAuthorizedAuditor(address(0), true);
    }

    function test_registerThreat_revert_unauthorized() public {
        string[] memory mitigations = new string[](0);
        vm.prank(unauthorized);
        vm.expectRevert(PactThreatModel.UnauthorizedAuditor.selector);
        model.registerThreat(
            SYBIL_ID,
            PactThreatModel.ThreatCategory.SybilAttack,
            PactThreatModel.Severity.Critical,
            "test",
            mitigations,
            0.5e18
        );
    }

    // ── Threat Registration ───────────────────────────────────────────

    function test_registerThreat() public {
        _registerSybilThreat();

        (
            bytes32 id,
            PactThreatModel.ThreatCategory cat,
            PactThreatModel.Severity sev,
            string memory desc,
            uint256 risk,
            uint64 registered,
            uint64 updated,
            bool active
        ) = model.threats(SYBIL_ID);

        assertEq(id, SYBIL_ID);
        assertEq(uint256(cat), uint256(PactThreatModel.ThreatCategory.SybilAttack));
        assertEq(uint256(sev), uint256(PactThreatModel.Severity.Critical));
        assertTrue(bytes(desc).length > 0);
        assertEq(risk, 0.42e18);
        assertTrue(registered > 0);
        assertTrue(updated > 0);
        assertTrue(active);
    }

    function test_registerThreat_revert_duplicate() public {
        _registerSybilThreat();

        string[] memory mitigations = new string[](0);
        vm.prank(auditor);
        vm.expectRevert(PactThreatModel.ThreatAlreadyExists.selector);
        model.registerThreat(
            SYBIL_ID, PactThreatModel.ThreatCategory.SybilAttack, PactThreatModel.Severity.Low, "dup", mitigations, 0
        );
    }

    function test_registerThreat_revert_emptyDescription() public {
        string[] memory mitigations = new string[](0);
        vm.prank(auditor);
        vm.expectRevert(PactThreatModel.EmptyDescription.selector);
        model.registerThreat(
            SYBIL_ID, PactThreatModel.ThreatCategory.SybilAttack, PactThreatModel.Severity.Low, "", mitigations, 0
        );
    }

    function test_registerThreat_revert_tooManyMitigations() public {
        string[] memory mitigations = new string[](11);
        for (uint256 i = 0; i < 11; i++) {
            mitigations[i] = "mitigation";
        }
        vm.prank(auditor);
        vm.expectRevert(PactThreatModel.TooManyMitigations.selector);
        model.registerThreat(
            SYBIL_ID, PactThreatModel.ThreatCategory.SybilAttack, PactThreatModel.Severity.Low, "desc", mitigations, 0
        );
    }

    function test_registerThreat_revert_invalidRisk() public {
        string[] memory mitigations = new string[](0);
        vm.prank(auditor);
        vm.expectRevert(PactThreatModel.InvalidRisk.selector);
        model.registerThreat(
            SYBIL_ID,
            PactThreatModel.ThreatCategory.SybilAttack,
            PactThreatModel.Severity.Low,
            "desc",
            mitigations,
            1e18 + 1
        );
    }

    // ── Threat Updates ────────────────────────────────────────────────

    function test_updateThreatRisk() public {
        _registerSybilThreat();

        vm.prank(auditor);
        model.updateThreatRisk(SYBIL_ID, 0.6e18);

        (,,,, uint256 risk,,,) = model.threats(SYBIL_ID);
        assertEq(risk, 0.6e18);
    }

    function test_updateThreatRisk_revert_notFound() public {
        vm.prank(auditor);
        vm.expectRevert(PactThreatModel.ThreatNotFound.selector);
        model.updateThreatRisk(bytes32(uint256(999)), 0.5e18);
    }

    function test_updateThreatRisk_revert_invalidRisk() public {
        _registerSybilThreat();
        vm.prank(auditor);
        vm.expectRevert(PactThreatModel.InvalidRisk.selector);
        model.updateThreatRisk(SYBIL_ID, 1e18 + 1);
    }

    // ── Deactivate / Reactivate ───────────────────────────────────────

    function test_deactivateThreat() public {
        _registerSybilThreat();

        vm.prank(auditor);
        model.deactivateThreat(SYBIL_ID);

        (,,,,,,, bool active) = model.threats(SYBIL_ID);
        assertFalse(active);
    }

    function test_reactivateThreat() public {
        _registerSybilThreat();

        vm.prank(auditor);
        model.deactivateThreat(SYBIL_ID);
        vm.prank(auditor);
        model.reactivateThreat(SYBIL_ID);

        (,,,,,,, bool active) = model.threats(SYBIL_ID);
        assertTrue(active);
    }

    function test_deactivateThreat_revert_notFound() public {
        vm.prank(auditor);
        vm.expectRevert(PactThreatModel.ThreatNotFound.selector);
        model.deactivateThreat(bytes32(uint256(999)));
    }

    // ── Active Threats / Count ────────────────────────────────────────

    function test_getThreatCount() public {
        _registerSybilThreat();
        _registerCollusionThreat();
        assertEq(model.getThreatCount(), 2);
    }

    function test_getActiveThreats() public {
        _registerSybilThreat();
        _registerCollusionThreat();

        bytes32[] memory active = model.getActiveThreats();
        assertEq(active.length, 2);
    }

    function test_getActiveThreats_excludesDeactivated() public {
        _registerSybilThreat();
        _registerCollusionThreat();

        vm.prank(auditor);
        model.deactivateThreat(SYBIL_ID);

        bytes32[] memory active = model.getActiveThreats();
        assertEq(active.length, 1);
        assertEq(active[0], COLLUSION_ID);
    }

    function test_getMitigations() public {
        _registerSybilThreat();
        string[] memory mits = model.getThreatMitigations(SYBIL_ID);
        assertEq(mits.length, 2);
    }

    function test_getMitigations_revert_notFound() public {
        vm.expectRevert(PactThreatModel.ThreatNotFound.selector);
        model.getThreatMitigations(bytes32(uint256(999)));
    }

    // ── Audit ─────────────────────────────────────────────────────────

    function test_runAudit_basic() public {
        _registerSybilThreat();
        _registerCollusionThreat();

        PactThreatModel.NetworkStats memory stats =
            PactThreatModel.NetworkStats({participants: 1000, transactions: 50000, disputes: 100, avgReputation: 75});

        string[] memory recs = new string[](1);
        recs[0] = "Increase monitoring";

        vm.prank(auditor);
        uint256 auditId = model.runAudit(stats, recs);
        assertEq(auditId, 0);
        assertEq(model.getAuditCount(), 1);
    }

    function test_runAudit_multipleAudits() public {
        _registerSybilThreat();

        PactThreatModel.NetworkStats memory stats =
            PactThreatModel.NetworkStats({participants: 100, transactions: 5000, disputes: 10, avgReputation: 80});
        string[] memory recs = new string[](0);

        vm.prank(auditor);
        model.runAudit(stats, recs);

        vm.warp(block.timestamp + 3600);

        vm.prank(auditor);
        uint256 id2 = model.runAudit(stats, recs);
        assertEq(id2, 1);
        assertEq(model.getAuditCount(), 2);
    }

    function test_runAudit_revert_invalidAvgReputation() public {
        string[] memory recs = new string[](0);
        PactThreatModel.NetworkStats memory stats =
            PactThreatModel.NetworkStats({participants: 100, transactions: 5000, disputes: 10, avgReputation: 101});

        vm.prank(auditor);
        vm.expectRevert(PactThreatModel.InvalidStats.selector);
        model.runAudit(stats, recs);
    }

    function test_getLatestAudit() public {
        _registerSybilThreat();

        PactThreatModel.NetworkStats memory stats =
            PactThreatModel.NetworkStats({participants: 100, transactions: 5000, disputes: 10, avgReputation: 80});
        string[] memory recs = new string[](0);

        vm.prank(auditor);
        model.runAudit(stats, recs);

        (uint256 auditId, uint64 timestamp, uint256 risk, uint256 count) = model.getLatestAudit();
        assertEq(auditId, 0);
        assertTrue(timestamp > 0);
        assertTrue(risk > 0);
        assertEq(count, 1);
    }

    function test_getLatestAudit_empty() public view {
        (uint256 auditId, uint64 timestamp,,) = model.getLatestAudit();
        assertEq(auditId, 0);
        assertEq(timestamp, 0);
    }

    function test_getAuditRecommendations() public {
        _registerSybilThreat();

        PactThreatModel.NetworkStats memory stats =
            PactThreatModel.NetworkStats({participants: 100, transactions: 5000, disputes: 10, avgReputation: 80});

        string[] memory recs = new string[](2);
        recs[0] = "Monitor closely";
        recs[1] = "Increase stake";

        vm.prank(auditor);
        model.runAudit(stats, recs);

        string[] memory stored = model.getAuditRecommendations(0);
        assertEq(stored.length, 2);
    }

    // ── Risk Score Calculation ────────────────────────────────────────

    function test_overallRisk_noThreats() public {
        PactThreatModel.NetworkStats memory stats =
            PactThreatModel.NetworkStats({participants: 100, transactions: 5000, disputes: 10, avgReputation: 80});
        string[] memory recs = new string[](0);

        vm.prank(auditor);
        model.runAudit(stats, recs);

        (,, uint256 risk,) = model.getLatestAudit();
        assertEq(risk, 0); // no active threats
    }

    function test_overallRisk_singleCritical() public {
        _registerSybilThreat(); // critical, 0.42

        PactThreatModel.NetworkStats memory stats =
            PactThreatModel.NetworkStats({participants: 100, transactions: 5000, disputes: 10, avgReputation: 80});
        string[] memory recs = new string[](0);

        vm.prank(auditor);
        model.runAudit(stats, recs);

        (,, uint256 risk,) = model.getLatestAudit();
        assertEq(risk, 42); // 0.42 * 100 = 42
    }

    function test_overallRisk_mixedSeverity() public {
        _registerSybilThreat(); // critical (w=4), 0.42
        _registerCollusionThreat(); // high (w=3), 0.35
        _registerDDoSThreat(); // high (w=3), 0.36

        PactThreatModel.NetworkStats memory stats =
            PactThreatModel.NetworkStats({participants: 100, transactions: 5000, disputes: 10, avgReputation: 80});
        string[] memory recs = new string[](0);

        vm.prank(auditor);
        model.runAudit(stats, recs);

        (,, uint256 risk,) = model.getLatestAudit();
        // (0.42*4 + 0.35*3 + 0.36*3) / (4+3+3) * 100
        // (1.68 + 1.05 + 1.08) / 10 * 100 = 38.1
        assertTrue(risk >= 37 && risk <= 39);
    }

    function test_overallRisk_deactivatedExcluded() public {
        _registerSybilThreat();
        _registerCollusionThreat();

        vm.prank(auditor);
        model.deactivateThreat(SYBIL_ID);

        PactThreatModel.NetworkStats memory stats =
            PactThreatModel.NetworkStats({participants: 100, transactions: 5000, disputes: 10, avgReputation: 80});
        string[] memory recs = new string[](0);

        vm.prank(auditor);
        model.runAudit(stats, recs);

        (,, uint256 risk,) = model.getLatestAudit();
        assertEq(risk, 35); // only collusion at 0.35
    }

    // ── Owner Direct ──────────────────────────────────────────────────

    function test_ownerCanRegisterThreat() public {
        string[] memory mitigations = new string[](0);
        model.registerThreat(
            EXPLOIT_ID,
            PactThreatModel.ThreatCategory.SmartContractExploit,
            PactThreatModel.Severity.Critical,
            "Contract bugs",
            mitigations,
            0.27e18
        );
        assertEq(model.getThreatCount(), 1);
    }
}
