// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";

/// @title PactSybilResistance
/// @notice On-chain Sybil resistance controls for PACT (§12).
///         Enforces identity-verification and stake-based anti-Sybil scoring.
///         Gatekeeper: accounts below a minimum score cannot participate in
///         high-trust protocol actions (validation, governance, data listing).
contract PactSybilResistance is Ownable {
    // ── Constants ─────────────────────────────────────────────────────────
    uint256 public constant SCORE_PRECISION = 100; // score 0..100
    uint256 public constant IDENTITY_WEIGHT = 70; // 70% identity, 30% stake
    uint256 public constant STAKE_WEIGHT = 30;

    // ── Enums ─────────────────────────────────────────────────────────────
    enum VerificationLevel {
        None, // 0 — no verification
        Basic, // 1 — email/phone
        Verified, // 2 — KYC / DID attestation
        Trusted, // 3 — multi-factor + stake history
        Elite // 4 — long-standing high-reputation
    }

    // ── Structs ───────────────────────────────────────────────────────────
    struct ParticipantProfile {
        VerificationLevel level;
        uint256 stakeCents; // current stake in cents (USDC 6-dec scaled externally)
        uint256 sybilScore; // computed 0..100
        uint64 registeredAt;
        uint64 lastUpdated;
        bool frozen;
    }

    struct SybilConfig {
        uint256 minimumStakeCents; // minimum stake for score computation
        uint256 minScoreForHighTrust; // minimum score to participate in high-trust actions
        uint256 minScoreForGovernance; // minimum score for governance votes
    }

    // ── State ─────────────────────────────────────────────────────────────
    mapping(address => ParticipantProfile) public profiles;
    SybilConfig public config;
    mapping(address => bool) public authorizedUpdaters;

    // ── Events ────────────────────────────────────────────────────────────
    event ProfileRegistered(address indexed participant, VerificationLevel level, uint256 stakeCents);
    event ProfileUpdated(address indexed participant, uint256 oldScore, uint256 newScore);
    event StakeUpdated(address indexed participant, uint256 oldStake, uint256 newStake);
    event VerificationLevelChanged(address indexed participant, VerificationLevel oldLevel, VerificationLevel newLevel);
    event ParticipantFrozen(address indexed participant);
    event ParticipantUnfrozen(address indexed participant);
    event ConfigUpdated(uint256 minimumStakeCents, uint256 minScoreForHighTrust, uint256 minScoreForGovernance);
    event UpdaterAuthorizationChanged(address indexed updater, bool authorized);

    // ── Errors ────────────────────────────────────────────────────────────
    error ZeroAddress();
    error AlreadyRegistered();
    error NotRegistered();
    error ParticipantIsFrozen();
    error InsufficientSybilScore(uint256 required, uint256 actual);
    error UnauthorizedUpdater();
    error InvalidConfig();

    // ── Modifiers ─────────────────────────────────────────────────────────
    modifier onlyAuthorized() {
        if (msg.sender != owner() && !authorizedUpdaters[msg.sender]) revert UnauthorizedUpdater();
        _;
    }

    modifier onlyRegistered(address participant) {
        if (profiles[participant].registeredAt == 0) revert NotRegistered();
        _;
    }

    modifier notFrozen(address participant) {
        if (profiles[participant].frozen) revert ParticipantIsFrozen();
        _;
    }

    // ── Constructor ───────────────────────────────────────────────────────
    constructor() Ownable(msg.sender) {
        config = SybilConfig({
            minimumStakeCents: 1000, // $10 minimum
            minScoreForHighTrust: 50,
            minScoreForGovernance: 70
        });
    }

    // ── Admin ─────────────────────────────────────────────────────────────

    function setAuthorizedUpdater(address updater, bool authorized) external onlyOwner {
        if (updater == address(0)) revert ZeroAddress();
        authorizedUpdaters[updater] = authorized;
        emit UpdaterAuthorizationChanged(updater, authorized);
    }

    function updateConfig(uint256 minimumStakeCents, uint256 minScoreForHighTrust, uint256 minScoreForGovernance)
        external
        onlyOwner
    {
        if (minimumStakeCents == 0) revert InvalidConfig();
        if (minScoreForHighTrust > 100 || minScoreForGovernance > 100) revert InvalidConfig();
        config = SybilConfig({
            minimumStakeCents: minimumStakeCents,
            minScoreForHighTrust: minScoreForHighTrust,
            minScoreForGovernance: minScoreForGovernance
        });
        emit ConfigUpdated(minimumStakeCents, minScoreForHighTrust, minScoreForGovernance);
    }

    // ── Registration ──────────────────────────────────────────────────────

    function registerParticipant(address participant, VerificationLevel level, uint256 stakeCents)
        external
        onlyAuthorized
    {
        if (participant == address(0)) revert ZeroAddress();
        if (profiles[participant].registeredAt != 0) revert AlreadyRegistered();

        uint256 score = _computeScore(level, stakeCents);
        profiles[participant] = ParticipantProfile({
            level: level,
            stakeCents: stakeCents,
            sybilScore: score,
            registeredAt: uint64(block.timestamp),
            lastUpdated: uint64(block.timestamp),
            frozen: false
        });

        emit ProfileRegistered(participant, level, stakeCents);
    }

    // ── Updates ───────────────────────────────────────────────────────────

    function updateVerificationLevel(address participant, VerificationLevel newLevel)
        external
        onlyAuthorized
        onlyRegistered(participant)
        notFrozen(participant)
    {
        ParticipantProfile storage p = profiles[participant];
        VerificationLevel oldLevel = p.level;
        uint256 oldScore = p.sybilScore;

        p.level = newLevel;
        p.sybilScore = _computeScore(newLevel, p.stakeCents);
        p.lastUpdated = uint64(block.timestamp);

        emit VerificationLevelChanged(participant, oldLevel, newLevel);
        emit ProfileUpdated(participant, oldScore, p.sybilScore);
    }

    function updateStake(address participant, uint256 newStakeCents)
        external
        onlyAuthorized
        onlyRegistered(participant)
        notFrozen(participant)
    {
        ParticipantProfile storage p = profiles[participant];
        uint256 oldStake = p.stakeCents;
        uint256 oldScore = p.sybilScore;

        p.stakeCents = newStakeCents;
        p.sybilScore = _computeScore(p.level, newStakeCents);
        p.lastUpdated = uint64(block.timestamp);

        emit StakeUpdated(participant, oldStake, newStakeCents);
        emit ProfileUpdated(participant, oldScore, p.sybilScore);
    }

    function freezeParticipant(address participant) external onlyAuthorized onlyRegistered(participant) {
        profiles[participant].frozen = true;
        profiles[participant].lastUpdated = uint64(block.timestamp);
        emit ParticipantFrozen(participant);
    }

    function unfreezeParticipant(address participant) external onlyAuthorized onlyRegistered(participant) {
        profiles[participant].frozen = false;
        profiles[participant].lastUpdated = uint64(block.timestamp);
        emit ParticipantUnfrozen(participant);
    }

    // ── Gatekeeper ────────────────────────────────────────────────────────

    /// @notice Check if participant can perform high-trust actions.
    function canPerformHighTrust(address participant) external view returns (bool) {
        ParticipantProfile storage p = profiles[participant];
        if (p.registeredAt == 0 || p.frozen) return false;
        return p.sybilScore >= config.minScoreForHighTrust;
    }

    /// @notice Check if participant can vote in governance.
    function canParticipateInGovernance(address participant) external view returns (bool) {
        ParticipantProfile storage p = profiles[participant];
        if (p.registeredAt == 0 || p.frozen) return false;
        return p.sybilScore >= config.minScoreForGovernance;
    }

    /// @notice Revert if participant score is below threshold.
    function requireMinScore(address participant, uint256 minScore) external view {
        ParticipantProfile storage p = profiles[participant];
        if (p.registeredAt == 0) revert NotRegistered();
        if (p.frozen) revert ParticipantIsFrozen();
        if (p.sybilScore < minScore) revert InsufficientSybilScore(minScore, p.sybilScore);
    }

    // ── View ──────────────────────────────────────────────────────────────

    function getScore(address participant) external view returns (uint256) {
        return profiles[participant].sybilScore;
    }

    function getProfile(address participant)
        external
        view
        returns (
            VerificationLevel level,
            uint256 stakeCents,
            uint256 sybilScore,
            uint64 registeredAt,
            uint64 lastUpdated,
            bool frozen
        )
    {
        ParticipantProfile storage p = profiles[participant];
        return (p.level, p.stakeCents, p.sybilScore, p.registeredAt, p.lastUpdated, p.frozen);
    }

    // ── Internal ──────────────────────────────────────────────────────────

    /// @dev Compute sybil resistance score: 70% identity + 30% stake coverage.
    ///      Identity score = verificationLevel / 4 (Elite = 100%).
    ///      Stake coverage = min(stakeCents / minimumStakeCents, 1).
    function _computeScore(VerificationLevel level, uint256 stakeCents) internal view returns (uint256) {
        // Identity component: 0..100
        uint256 identityScore = (uint256(level) * SCORE_PRECISION) / uint256(type(VerificationLevel).max);

        // Stake component: 0..100
        uint256 minStake = config.minimumStakeCents;
        uint256 stakeScore;
        if (minStake == 0 || stakeCents >= minStake) {
            stakeScore = SCORE_PRECISION;
        } else {
            stakeScore = (stakeCents * SCORE_PRECISION) / minStake;
        }

        // Weighted blend
        return (identityScore * IDENTITY_WEIGHT + stakeScore * STAKE_WEIGHT) / 100;
    }
}
