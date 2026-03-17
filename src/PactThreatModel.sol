// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";

/// @title PactThreatModel
/// @notice On-chain threat model registry for PACT (§12).
///         Stores threat entries with severity, mitigations, and residual risk.
///         Supports risk assessments linked to network statistics and
///         on-chain audit trail of security posture over time.
contract PactThreatModel is Ownable {
    // ── Constants ─────────────────────────────────────────────────────────
    uint256 public constant RISK_PRECISION = 1e18; // 18-decimal fixed-point for risk scores
    uint256 public constant MAX_RISK = 1e18; // 100%
    uint256 public constant MAX_MITIGATIONS = 10;
    uint256 public constant MAX_THREATS_PER_AUDIT = 50;

    // ── Enums ─────────────────────────────────────────────────────────────
    enum ThreatCategory {
        SybilAttack,
        Collusion,
        FrontRunning,
        ReplayAttack,
        DataPoisoning,
        IdentityTheft,
        DDoS,
        SmartContractExploit
    }

    enum Severity {
        Low, // weight 1
        Medium, // weight 2
        High, // weight 3
        Critical // weight 4
    }

    // ── Structs ───────────────────────────────────────────────────────────
    struct ThreatEntry {
        bytes32 threatId;
        ThreatCategory category;
        Severity severity;
        string description;
        string[] mitigations;
        uint256 residualRisk; // 0..1e18
        uint64 registeredAt;
        uint64 lastUpdated;
        bool active;
    }

    struct NetworkStats {
        uint256 participants;
        uint256 transactions;
        uint256 disputes;
        uint256 avgReputation; // 0..100
    }

    struct AuditResult {
        uint256 auditId;
        uint64 timestamp;
        uint256 overallRiskScore; // 0..100 (2-decimal scaled)
        uint256 threatCount;
        string[] recommendations;
        NetworkStats stats;
    }

    // ── State ─────────────────────────────────────────────────────────────
    mapping(bytes32 => ThreatEntry) public threats;
    bytes32[] public threatIds;
    mapping(address => bool) public authorizedAuditors;

    AuditResult[] public auditHistory;
    uint256 public nextAuditId;

    // ── Events ────────────────────────────────────────────────────────────
    event ThreatRegistered(bytes32 indexed threatId, ThreatCategory category, Severity severity);
    event ThreatUpdated(bytes32 indexed threatId, uint256 oldResidualRisk, uint256 newResidualRisk);
    event ThreatDeactivated(bytes32 indexed threatId);
    event ThreatReactivated(bytes32 indexed threatId);
    event AuditCompleted(uint256 indexed auditId, uint256 overallRiskScore, uint256 threatCount);
    event AuditorAuthorizationChanged(address indexed auditor, bool authorized);

    // ── Errors ────────────────────────────────────────────────────────────
    error ZeroAddress();
    error UnauthorizedAuditor();
    error ThreatAlreadyExists();
    error ThreatNotFound();
    error TooManyMitigations();
    error InvalidRisk();
    error InvalidStats();
    error EmptyDescription();

    // ── Modifiers ─────────────────────────────────────────────────────────
    modifier onlyAuditor() {
        if (msg.sender != owner() && !authorizedAuditors[msg.sender]) revert UnauthorizedAuditor();
        _;
    }

    // ── Constructor ───────────────────────────────────────────────────────
    constructor() Ownable(msg.sender) {}

    // ── Admin ─────────────────────────────────────────────────────────────

    function setAuthorizedAuditor(address auditor, bool authorized) external onlyOwner {
        if (auditor == address(0)) revert ZeroAddress();
        authorizedAuditors[auditor] = authorized;
        emit AuditorAuthorizationChanged(auditor, authorized);
    }

    // ── Threat Registration ───────────────────────────────────────────────

    function registerThreat(
        bytes32 threatId,
        ThreatCategory category,
        Severity severity,
        string calldata description,
        string[] calldata mitigations,
        uint256 residualRisk
    ) external onlyAuditor {
        if (threats[threatId].registeredAt != 0) revert ThreatAlreadyExists();
        if (bytes(description).length == 0) revert EmptyDescription();
        if (mitigations.length > MAX_MITIGATIONS) revert TooManyMitigations();
        if (residualRisk > MAX_RISK) revert InvalidRisk();

        ThreatEntry storage t = threats[threatId];
        t.threatId = threatId;
        t.category = category;
        t.severity = severity;
        t.description = description;
        t.residualRisk = residualRisk;
        t.registeredAt = uint64(block.timestamp);
        t.lastUpdated = uint64(block.timestamp);
        t.active = true;

        // Copy mitigations
        for (uint256 i = 0; i < mitigations.length; i++) {
            t.mitigations.push(mitigations[i]);
        }

        threatIds.push(threatId);
        emit ThreatRegistered(threatId, category, severity);
    }

    function updateThreatRisk(bytes32 threatId, uint256 newResidualRisk) external onlyAuditor {
        ThreatEntry storage t = threats[threatId];
        if (t.registeredAt == 0) revert ThreatNotFound();
        if (newResidualRisk > MAX_RISK) revert InvalidRisk();

        uint256 oldRisk = t.residualRisk;
        t.residualRisk = newResidualRisk;
        t.lastUpdated = uint64(block.timestamp);

        emit ThreatUpdated(threatId, oldRisk, newResidualRisk);
    }

    function deactivateThreat(bytes32 threatId) external onlyAuditor {
        ThreatEntry storage t = threats[threatId];
        if (t.registeredAt == 0) revert ThreatNotFound();
        t.active = false;
        t.lastUpdated = uint64(block.timestamp);
        emit ThreatDeactivated(threatId);
    }

    function reactivateThreat(bytes32 threatId) external onlyAuditor {
        ThreatEntry storage t = threats[threatId];
        if (t.registeredAt == 0) revert ThreatNotFound();
        t.active = true;
        t.lastUpdated = uint64(block.timestamp);
        emit ThreatReactivated(threatId);
    }

    // ── Audit ─────────────────────────────────────────────────────────────

    /// @notice Run an on-chain risk assessment against current threats and network stats.
    function runAudit(NetworkStats calldata stats, string[] calldata recommendations)
        external
        onlyAuditor
        returns (uint256 auditId)
    {
        if (stats.avgReputation > 100) revert InvalidStats();

        uint256 overallRisk = _calculateOverallRisk();
        auditId = nextAuditId++;

        auditHistory.push();
        AuditResult storage result = auditHistory[auditHistory.length - 1];
        result.auditId = auditId;
        result.timestamp = uint64(block.timestamp);
        result.overallRiskScore = overallRisk;
        result.threatCount = _activeCount();
        result.stats = stats;

        for (uint256 i = 0; i < recommendations.length; i++) {
            result.recommendations.push(recommendations[i]);
        }

        emit AuditCompleted(auditId, overallRisk, result.threatCount);
    }

    // ── View ──────────────────────────────────────────────────────────────

    function getThreatCount() external view returns (uint256) {
        return threatIds.length;
    }

    function getActiveThreats() external view returns (bytes32[] memory) {
        uint256 activeCount = _activeCount();
        bytes32[] memory result = new bytes32[](activeCount);
        uint256 idx = 0;
        for (uint256 i = 0; i < threatIds.length; i++) {
            if (threats[threatIds[i]].active) {
                result[idx++] = threatIds[i];
            }
        }
        return result;
    }

    function getThreatMitigations(bytes32 threatId) external view returns (string[] memory) {
        if (threats[threatId].registeredAt == 0) revert ThreatNotFound();
        return threats[threatId].mitigations;
    }

    function getAuditCount() external view returns (uint256) {
        return auditHistory.length;
    }

    function getLatestAudit()
        external
        view
        returns (uint256 auditId, uint64 timestamp, uint256 overallRiskScore, uint256 threatCount)
    {
        if (auditHistory.length == 0) return (0, 0, 0, 0);
        AuditResult storage latest = auditHistory[auditHistory.length - 1];
        return (latest.auditId, latest.timestamp, latest.overallRiskScore, latest.threatCount);
    }

    function getAuditRecommendations(uint256 index) external view returns (string[] memory) {
        return auditHistory[index].recommendations;
    }

    // ── Internal ──────────────────────────────────────────────────────────

    function _activeCount() internal view returns (uint256 count) {
        for (uint256 i = 0; i < threatIds.length; i++) {
            if (threats[threatIds[i]].active) count++;
        }
    }

    /// @dev Weighted average risk: sum(residualRisk * severityWeight) / sum(severityWeight).
    ///      Returns a score 0..100 (2-decimal precision).
    function _calculateOverallRisk() internal view returns (uint256) {
        uint256 totalWeight;
        uint256 weightedRisk;

        for (uint256 i = 0; i < threatIds.length; i++) {
            ThreatEntry storage t = threats[threatIds[i]];
            if (!t.active) continue;

            uint256 weight = _severityWeight(t.severity);
            totalWeight += weight;
            weightedRisk += (t.residualRisk * weight);
        }

        if (totalWeight == 0) return 0;

        // Convert from 1e18 precision to 0..100
        return (weightedRisk * 100) / (totalWeight * RISK_PRECISION);
    }

    function _severityWeight(Severity sev) internal pure returns (uint256) {
        if (sev == Severity.Low) return 1;
        if (sev == Severity.Medium) return 2;
        if (sev == Severity.High) return 3;
        return 4; // Critical
    }
}
