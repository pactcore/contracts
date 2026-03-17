// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";

/// @title PactNashEquilibrium
/// @notice On-chain Nash-equilibrium parameter storage and stability checks (§8.2).
///         Stores game-theoretic parameters that govern validator/worker/issuer
///         incentive alignment. An off-chain oracle (or governance) pushes
///         equilibrium profiles; contracts read current params to enforce
///         economically rational behaviour.
contract PactNashEquilibrium is Ownable {
    // ── Constants ─────────────────────────────────────────────────────────
    uint8 public constant MAX_PLAYERS = 10;
    uint8 public constant MAX_STRATEGIES = 10;
    uint256 public constant PAYOFF_PRECISION = 1e18; // 18-decimal fixed-point

    // ── Structs ───────────────────────────────────────────────────────────

    /// @notice A complete equilibrium profile stored on-chain.
    struct EquilibriumProfile {
        bytes32 profileId;
        string[] players; // e.g. ["worker", "validator", "issuer"]
        string[] strategies; // e.g. ["honest", "dishonest"]
        string[] chosenStrategies; // parallel to players – the Nash-stable strategy per player
        int256[] payoffs; // parallel to players – fixed-point payoff per player
        int256 totalPayoff;
        bool stable; // true iff no profitable unilateral deviation exists
        uint64 updatedAt;
    }

    /// @notice System-wide incentive parameters derived from equilibrium analysis.
    struct IncentiveParams {
        uint16 workerShareBps; // basis points of task reward to worker
        uint16 validatorShareBps; // basis points to validators
        uint16 treasuryShareBps; // basis points to protocol treasury
        uint16 issuerShareBps; // basis points to task issuer
        uint256 minStakeAmount; // minimum stake for honest participation
        uint256 dishonestPenalty; // penalty for detected dishonest behaviour
        uint256 collusionThreshold; // number of colluders before cost exceeds gain
        uint64 updatedAt;
    }

    // ── State ─────────────────────────────────────────────────────────────
    mapping(bytes32 profileId => EquilibriumProfile) private profiles;
    bytes32[] private profileIds;
    bytes32 public activeProfileId;

    IncentiveParams public incentiveParams;

    /// @notice Addresses permitted to push profiles (besides owner).
    mapping(address updater => bool) public authorizedUpdaters;

    // ── Events ────────────────────────────────────────────────────────────
    event ProfileStored(bytes32 indexed profileId, bool stable, int256 totalPayoff);
    event ActiveProfileChanged(bytes32 indexed oldProfileId, bytes32 indexed newProfileId);
    event IncentiveParamsUpdated(
        uint16 workerShareBps,
        uint16 validatorShareBps,
        uint16 treasuryShareBps,
        uint16 issuerShareBps,
        uint256 minStakeAmount,
        uint256 dishonestPenalty,
        uint256 collusionThreshold
    );
    event UpdaterAuthorizationChanged(address indexed updater, bool authorized);

    // ── Errors ────────────────────────────────────────────────────────────
    error ZeroAddress();
    error UnauthorizedUpdater();
    error EmptyPlayers();
    error EmptyStrategies();
    error TooManyPlayers();
    error TooManyStrategies();
    error LengthMismatch();
    error ProfileNotFound();
    error ProfileNotStable();
    error InvalidBps();
    error ProfileAlreadyExists();

    // ── Modifiers ─────────────────────────────────────────────────────────
    modifier onlyAuthorized() {
        if (msg.sender != owner() && !authorizedUpdaters[msg.sender]) revert UnauthorizedUpdater();
        _;
    }

    constructor() Ownable(msg.sender) {
        // Default conservative incentive params matching §5.1 settlement splits
        incentiveParams = IncentiveParams({
            workerShareBps: 8500, // 85%
            validatorShareBps: 500, // 5%
            treasuryShareBps: 500, // 5%
            issuerShareBps: 500, // 5%
            minStakeAmount: 100e6, // 100 USDC (6 decimals)
            dishonestPenalty: 500e6, // 500 USDC
            collusionThreshold: 3,
            updatedAt: uint64(block.timestamp)
        });
    }

    // ── Admin ─────────────────────────────────────────────────────────────

    /// @notice Grant or revoke updater permission.
    function setAuthorizedUpdater(address updater, bool authorized) external onlyOwner {
        if (updater == address(0)) revert ZeroAddress();
        authorizedUpdaters[updater] = authorized;
        emit UpdaterAuthorizationChanged(updater, authorized);
    }

    // ── Profile Management ────────────────────────────────────────────────

    /// @notice Store a new equilibrium profile. Reverts if profileId already exists.
    function storeProfile(
        bytes32 profileId,
        string[] memory players,
        string[] memory strategies,
        string[] memory chosenStrategies,
        int256[] memory payoffs,
        int256 totalPayoff,
        bool stable
    ) external onlyAuthorized {
        if (players.length == 0) revert EmptyPlayers();
        if (strategies.length == 0) revert EmptyStrategies();
        if (players.length > MAX_PLAYERS) revert TooManyPlayers();
        if (strategies.length > MAX_STRATEGIES) revert TooManyStrategies();
        if (chosenStrategies.length != players.length) revert LengthMismatch();
        if (payoffs.length != players.length) revert LengthMismatch();
        if (profiles[profileId].updatedAt != 0) revert ProfileAlreadyExists();

        profiles[profileId] = EquilibriumProfile({
            profileId: profileId,
            players: players,
            strategies: strategies,
            chosenStrategies: chosenStrategies,
            payoffs: payoffs,
            totalPayoff: totalPayoff,
            stable: stable,
            updatedAt: uint64(block.timestamp)
        });
        profileIds.push(profileId);

        emit ProfileStored(profileId, stable, totalPayoff);
    }

    /// @notice Update an existing equilibrium profile.
    function updateProfile(
        bytes32 profileId,
        string[] memory chosenStrategies,
        int256[] memory payoffs,
        int256 totalPayoff,
        bool stable
    ) external onlyAuthorized {
        EquilibriumProfile storage p = profiles[profileId];
        if (p.updatedAt == 0) revert ProfileNotFound();
        if (chosenStrategies.length != p.players.length) revert LengthMismatch();
        if (payoffs.length != p.players.length) revert LengthMismatch();

        p.chosenStrategies = chosenStrategies;
        p.payoffs = payoffs;
        p.totalPayoff = totalPayoff;
        p.stable = stable;
        p.updatedAt = uint64(block.timestamp);

        emit ProfileStored(profileId, stable, totalPayoff);
    }

    /// @notice Set the active profile used by other contracts for parameter reads.
    ///         Profile must be stable to become active.
    function setActiveProfile(bytes32 profileId) external onlyAuthorized {
        EquilibriumProfile storage p = profiles[profileId];
        if (p.updatedAt == 0) revert ProfileNotFound();
        if (!p.stable) revert ProfileNotStable();

        bytes32 old = activeProfileId;
        activeProfileId = profileId;

        emit ActiveProfileChanged(old, profileId);
    }

    // ── Incentive Params ──────────────────────────────────────────────────

    /// @notice Update the system-wide incentive parameters. BPS must sum to 10000.
    function setIncentiveParams(
        uint16 workerShareBps,
        uint16 validatorShareBps,
        uint16 treasuryShareBps,
        uint16 issuerShareBps,
        uint256 minStakeAmount,
        uint256 dishonestPenalty,
        uint256 collusionThreshold
    ) external onlyAuthorized {
        if (uint256(workerShareBps) + validatorShareBps + treasuryShareBps + issuerShareBps != 10_000) revert InvalidBps();

        incentiveParams = IncentiveParams({
            workerShareBps: workerShareBps,
            validatorShareBps: validatorShareBps,
            treasuryShareBps: treasuryShareBps,
            issuerShareBps: issuerShareBps,
            minStakeAmount: minStakeAmount,
            dishonestPenalty: dishonestPenalty,
            collusionThreshold: collusionThreshold,
            updatedAt: uint64(block.timestamp)
        });

        emit IncentiveParamsUpdated(
            workerShareBps,
            validatorShareBps,
            treasuryShareBps,
            issuerShareBps,
            minStakeAmount,
            dishonestPenalty,
            collusionThreshold
        );
    }

    // ── Views ─────────────────────────────────────────────────────────────

    /// @notice Get a stored profile by ID.
    function getProfile(bytes32 profileId)
        external
        view
        returns (
            string[] memory players,
            string[] memory strategies,
            string[] memory chosenStrategies,
            int256[] memory payoffs,
            int256 totalPayoff,
            bool stable,
            uint64 updatedAt
        )
    {
        EquilibriumProfile storage p = profiles[profileId];
        if (p.updatedAt == 0) revert ProfileNotFound();
        return (p.players, p.strategies, p.chosenStrategies, p.payoffs, p.totalPayoff, p.stable, p.updatedAt);
    }

    /// @notice Get the currently active equilibrium profile.
    function getActiveProfile()
        external
        view
        returns (
            bytes32 profileId,
            string[] memory players,
            string[] memory chosenStrategies,
            int256[] memory payoffs,
            int256 totalPayoff,
            bool stable
        )
    {
        profileId = activeProfileId;
        if (profileId == bytes32(0)) revert ProfileNotFound();
        EquilibriumProfile storage p = profiles[profileId];
        if (p.updatedAt == 0) revert ProfileNotFound();
        return (profileId, p.players, p.chosenStrategies, p.payoffs, p.totalPayoff, p.stable);
    }

    /// @notice Check if the active profile is stable.
    function isEquilibriumStable() external view returns (bool) {
        if (activeProfileId == bytes32(0)) return false;
        EquilibriumProfile storage p = profiles[activeProfileId];
        if (p.updatedAt == 0) return false;
        return p.stable;
    }

    /// @notice Returns the number of stored profiles.
    function profileCount() external view returns (uint256) {
        return profileIds.length;
    }

    /// @notice Returns the profile ID at a given index.
    function profileIdAt(uint256 index) external view returns (bytes32) {
        return profileIds[index];
    }

    /// @notice Compute whether a given stake is sufficient for honest participation
    ///         under the current incentive parameters.
    function isStakeSufficient(uint256 stakeAmount) external view returns (bool) {
        return stakeAmount >= incentiveParams.minStakeAmount;
    }

    /// @notice Read the current collusion threshold.
    function getCollusionThreshold() external view returns (uint256) {
        return incentiveParams.collusionThreshold;
    }
}
