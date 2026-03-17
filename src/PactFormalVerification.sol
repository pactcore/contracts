// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "openzeppelin-contracts/contracts/access/AccessControl.sol";

/// @title PactFormalVerification — On-chain formal verification attestations for ZK circuits (§7)
/// @notice Records formal verification reports (soundness, completeness, zero-knowledge) for
///         PACT ZK circuits. Auditors submit attestations per circuit per security property.
///         This mirrors the off-chain `zk-formal-verification.ts` in pact-network-core.
/// @dev Only authorized auditors can submit reports. Once all 3 properties are satisfied for
///      a circuit, it is considered formally verified. Reports are append-only (immutable).
contract PactFormalVerification is AccessControl {
    bytes32 public constant AUDITOR_ROLE = keccak256("AUDITOR_ROLE");

    // ── Security properties (mirrors core SecurityProperty) ─────────
    enum SecurityProperty {
        Soundness, // Adversarial inputs rejected
        Completeness, // Honest inputs accepted
        ZeroKnowledge // No witness leakage
    }

    // ── Formal proof attestation ────────────────────────────────────
    struct FormalProof {
        SecurityProperty property;
        bool satisfied;
        string details;
        string[] assumptions;
        address auditor;
        uint64 checkedAt;
    }

    // ── Full verification report for a circuit ──────────────────────
    struct VerificationReport {
        bytes32 circuitId;
        bool verified; // true if all 3 properties satisfied
        uint256 proofCount;
        uint64 lastUpdated;
    }

    // ── Circuit metadata ────────────────────────────────────────────
    struct CircuitInfo {
        bytes32 circuitId;
        string name;
        string version;
        address registeredBy;
        uint64 registeredAt;
        bool active;
    }

    // ── Storage ─────────────────────────────────────────────────────
    uint256 private nextCircuitIndex = 1;
    mapping(bytes32 circuitId => CircuitInfo) private circuits;
    mapping(bytes32 circuitId => FormalProof[]) private circuitProofs;
    mapping(bytes32 circuitId => mapping(SecurityProperty => bool)) private propertySatisfied;
    mapping(bytes32 circuitId => bool) private fullyVerified;
    bytes32[] private circuitIds;

    // Per-auditor tracking
    mapping(address auditor => uint256) private auditorReportCount;

    // ── Events ──────────────────────────────────────────────────────
    event CircuitRegistered(bytes32 indexed circuitId, string name, string version, address registeredBy);
    event CircuitDeactivated(bytes32 indexed circuitId);
    event FormalProofSubmitted(
        bytes32 indexed circuitId,
        SecurityProperty indexed property,
        bool satisfied,
        address indexed auditor
    );
    event CircuitFullyVerified(bytes32 indexed circuitId, uint64 verifiedAt);

    // ── Errors ──────────────────────────────────────────────────────
    error CircuitNotRegistered(bytes32 circuitId);
    error CircuitAlreadyRegistered(bytes32 circuitId);
    error CircuitNotActive(bytes32 circuitId);
    error EmptyName();
    error EmptyVersion();
    error EmptyDetails();

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(AUDITOR_ROLE, msg.sender);
    }

    // ── Circuit registration ────────────────────────────────────────

    /// @notice Register a ZK circuit for formal verification tracking
    /// @param name Human-readable circuit name (e.g. "location", "completion")
    /// @param version Circuit version string
    /// @return circuitId The deterministic circuit identifier
    function registerCircuit(string calldata name, string calldata version)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        returns (bytes32 circuitId)
    {
        if (bytes(name).length == 0) revert EmptyName();
        if (bytes(version).length == 0) revert EmptyVersion();

        circuitId = keccak256(abi.encodePacked(name, version));
        if (circuits[circuitId].registeredAt != 0) revert CircuitAlreadyRegistered(circuitId);

        circuits[circuitId] = CircuitInfo({
            circuitId: circuitId,
            name: name,
            version: version,
            registeredBy: msg.sender,
            registeredAt: uint64(block.timestamp),
            active: true
        });
        circuitIds.push(circuitId);

        emit CircuitRegistered(circuitId, name, version, msg.sender);
    }

    /// @notice Deactivate a circuit (no new proofs can be submitted)
    function deactivateCircuit(bytes32 circuitId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        CircuitInfo storage info = circuits[circuitId];
        if (info.registeredAt == 0) revert CircuitNotRegistered(circuitId);
        if (!info.active) revert CircuitNotActive(circuitId);
        info.active = false;
        emit CircuitDeactivated(circuitId);
    }

    // ── Formal proof submission ─────────────────────────────────────

    /// @notice Submit a formal verification attestation for a circuit property
    /// @param circuitId The circuit to attest for
    /// @param property Which security property (Soundness, Completeness, ZeroKnowledge)
    /// @param satisfied Whether the property was satisfied
    /// @param details Human-readable verification details
    /// @param assumptions Array of assumptions made during verification
    function submitProof(
        bytes32 circuitId,
        SecurityProperty property,
        bool satisfied,
        string calldata details,
        string[] calldata assumptions
    ) external onlyRole(AUDITOR_ROLE) {
        CircuitInfo storage info = circuits[circuitId];
        if (info.registeredAt == 0) revert CircuitNotRegistered(circuitId);
        if (!info.active) revert CircuitNotActive(circuitId);
        if (bytes(details).length == 0) revert EmptyDetails();

        FormalProof memory proof = FormalProof({
            property: property,
            satisfied: satisfied,
            details: details,
            assumptions: assumptions,
            auditor: msg.sender,
            checkedAt: uint64(block.timestamp)
        });

        circuitProofs[circuitId].push(proof);
        auditorReportCount[msg.sender]++;

        // Update property status — once satisfied, stays satisfied
        if (satisfied) {
            propertySatisfied[circuitId][property] = true;
        }

        emit FormalProofSubmitted(circuitId, property, satisfied, msg.sender);

        // Check if all 3 properties are now satisfied
        if (
            !fullyVerified[circuitId] && propertySatisfied[circuitId][SecurityProperty.Soundness]
                && propertySatisfied[circuitId][SecurityProperty.Completeness]
                && propertySatisfied[circuitId][SecurityProperty.ZeroKnowledge]
        ) {
            fullyVerified[circuitId] = true;
            emit CircuitFullyVerified(circuitId, uint64(block.timestamp));
        }
    }

    // ── Queries ─────────────────────────────────────────────────────

    /// @notice Get circuit info
    function getCircuit(bytes32 circuitId) external view returns (CircuitInfo memory) {
        if (circuits[circuitId].registeredAt == 0) revert CircuitNotRegistered(circuitId);
        return circuits[circuitId];
    }

    /// @notice Check if a circuit is fully verified (all 3 properties satisfied)
    function isFullyVerified(bytes32 circuitId) external view returns (bool) {
        return fullyVerified[circuitId];
    }

    /// @notice Check if a specific property is satisfied for a circuit
    function isPropertySatisfied(bytes32 circuitId, SecurityProperty property) external view returns (bool) {
        return propertySatisfied[circuitId][property];
    }

    /// @notice Get verification report summary for a circuit
    function getReport(bytes32 circuitId) external view returns (VerificationReport memory) {
        if (circuits[circuitId].registeredAt == 0) revert CircuitNotRegistered(circuitId);

        FormalProof[] storage proofs = circuitProofs[circuitId];
        uint64 lastUpdated = 0;
        if (proofs.length > 0) {
            lastUpdated = proofs[proofs.length - 1].checkedAt;
        }

        return VerificationReport({
            circuitId: circuitId,
            verified: fullyVerified[circuitId],
            proofCount: proofs.length,
            lastUpdated: lastUpdated
        });
    }

    /// @notice Get all formal proofs submitted for a circuit
    function getCircuitProofs(bytes32 circuitId, uint256 offset, uint256 limit)
        external
        view
        returns (FormalProof[] memory)
    {
        FormalProof[] storage proofs = circuitProofs[circuitId];
        uint256 total = proofs.length;
        if (offset >= total) return new FormalProof[](0);
        uint256 end = offset + limit;
        if (end > total) end = total;
        FormalProof[] memory result = new FormalProof[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            result[i - offset] = proofs[i];
        }
        return result;
    }

    /// @notice Get the number of proofs submitted for a circuit
    function getCircuitProofCount(bytes32 circuitId) external view returns (uint256) {
        return circuitProofs[circuitId].length;
    }

    /// @notice Get total registered circuits
    function getCircuitCount() external view returns (uint256) {
        return circuitIds.length;
    }

    /// @notice Get all circuit IDs (paginated)
    function getCircuitIds(uint256 offset, uint256 limit) external view returns (bytes32[] memory) {
        uint256 total = circuitIds.length;
        if (offset >= total) return new bytes32[](0);
        uint256 end = offset + limit;
        if (end > total) end = total;
        bytes32[] memory result = new bytes32[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            result[i - offset] = circuitIds[i];
        }
        return result;
    }

    /// @notice Get the total reports submitted by an auditor
    function getAuditorReportCount(address auditor) external view returns (uint256) {
        return auditorReportCount[auditor];
    }

    /// @notice Get property satisfaction status for all 3 properties at once
    function getPropertyStatus(bytes32 circuitId) external view returns (bool soundness, bool completeness, bool zeroKnowledge) {
        soundness = propertySatisfied[circuitId][SecurityProperty.Soundness];
        completeness = propertySatisfied[circuitId][SecurityProperty.Completeness];
        zeroKnowledge = propertySatisfied[circuitId][SecurityProperty.ZeroKnowledge];
    }
}
