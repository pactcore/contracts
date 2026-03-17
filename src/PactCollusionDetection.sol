// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";

/// @title PactCollusionDetection
/// @notice On-chain collusion detection and penalty enforcement (§8.5).
///         Detects repeated pairing, bid clustering, and timing correlation
///         among auction participants. Reports are submitted by authorized
///         monitors (off-chain detectors); the contract stores signals,
///         computes aggregate risk scores, and can slash/freeze flagged actors.
contract PactCollusionDetection is Ownable {
    // ── Constants ─────────────────────────────────────────────────────────
    uint256 public constant CONFIDENCE_PRECISION = 1e18; // 18-decimal fixed-point
    uint256 public constant MAX_CONFIDENCE = 1e18; // 100%
    uint8 public constant MAX_PARTICIPANTS_PER_SIGNAL = 20;
    uint256 public constant MAX_SIGNALS_PER_QUERY = 100;

    // ── Enums ─────────────────────────────────────────────────────────────

    enum SignalType {
        RepeatedPairing, // Same bidder-issuer pair occurs abnormally often
        BidClustering, // Bids from multiple participants are suspiciously close
        TimingCorrelation // Bids submitted within a narrow time window
    }

    enum ActorStatus {
        Clean, // No flags
        Flagged, // Under investigation
        Penalized, // Penalty applied
        Frozen // Participation frozen
    }

    // ── Structs ───────────────────────────────────────────────────────────

    /// @notice A single collusion signal submitted by an off-chain monitor.
    struct CollusionSignal {
        uint256 signalId;
        SignalType signalType;
        address[] participants; // involved addresses
        uint256 confidence; // 0..1e18 (0% .. 100%)
        bytes32 auctionId; // the auction in which collusion was detected
        uint64 detectedAt;
        address reporter; // the monitor that submitted this signal
    }

    /// @notice Collusion cost analysis result stored per query.
    struct CollusionCostAnalysis {
        uint256 networkSize;
        uint256 colluders;
        uint256 controlCostBps; // basis points (quadratic in colluder ratio)
        uint256 expectedPenalty; // controlCostBps * colluders (scaled)
        uint64 computedAt;
    }

    /// @notice Per-actor collusion risk profile.
    struct ActorProfile {
        uint256 totalSignals; // how many signals involve this actor
        uint256 aggregateConfidence; // sum of confidences (for averaging)
        uint256 penaltyAmount; // total penalty applied
        ActorStatus status;
        uint64 lastFlaggedAt;
    }

    /// @notice Detection configuration (tunable by governance).
    struct DetectionConfig {
        uint256 flagThreshold; // min signals before actor gets flagged
        uint256 penaltyThreshold; // min signals before penalty applied
        uint256 freezeThreshold; // min signals before actor is frozen
        uint256 minConfidenceForFlag; // min avg confidence to flag (18-dec)
        uint256 basePenaltyAmount; // base penalty in payment token units
        uint64 decayPeriod; // seconds after which old signals lose weight
    }

    // ── State ─────────────────────────────────────────────────────────────
    mapping(uint256 signalId => CollusionSignal) private signals;
    uint256 public signalCount;

    mapping(address actor => ActorProfile) public actorProfiles;
    mapping(address actor => uint256[]) private actorSignalIds;

    /// @notice Latest collusion cost analysis.
    CollusionCostAnalysis public latestCostAnalysis;

    DetectionConfig public config;

    /// @notice Addresses permitted to submit signals (off-chain monitors).
    mapping(address monitor => bool) public authorizedMonitors;

    // ── Events ────────────────────────────────────────────────────────────
    event SignalSubmitted(
        uint256 indexed signalId,
        SignalType signalType,
        bytes32 indexed auctionId,
        uint256 confidence,
        uint256 participantCount
    );
    event ActorFlagged(address indexed actor, uint256 totalSignals, uint256 avgConfidence);
    event ActorPenalized(address indexed actor, uint256 penaltyAmount, uint256 totalSignals);
    event ActorFrozen(address indexed actor, uint256 totalSignals);
    event ActorStatusReset(address indexed actor, ActorStatus previousStatus);
    event CostAnalysisUpdated(uint256 networkSize, uint256 colluders, uint256 controlCostBps, uint256 expectedPenalty);
    event MonitorAuthorizationChanged(address indexed monitor, bool authorized);
    event ConfigUpdated();

    // ── Errors ────────────────────────────────────────────────────────────
    error ZeroAddress();
    error UnauthorizedMonitor();
    error EmptyParticipants();
    error TooManyParticipants();
    error ConfidenceTooHigh();
    error InvalidNetworkSize();
    error ColludersExceedNetwork();
    error ZeroColluders();
    error SignalNotFound();
    error InvalidThresholds();
    error ActorNotFlagged();

    // ── Modifiers ─────────────────────────────────────────────────────────
    modifier onlyMonitor() {
        if (!authorizedMonitors[msg.sender] && msg.sender != owner()) revert UnauthorizedMonitor();
        _;
    }

    constructor() Ownable(msg.sender) {
        config = DetectionConfig({
            flagThreshold: 3,
            penaltyThreshold: 5,
            freezeThreshold: 10,
            minConfidenceForFlag: 0.55e18, // 55%
            basePenaltyAmount: 500e6, // 500 USDC (6 decimals)
            decayPeriod: 30 days
        });
    }

    // ── Admin ─────────────────────────────────────────────────────────────

    /// @notice Grant or revoke monitor permissions.
    function setAuthorizedMonitor(address monitor, bool authorized) external onlyOwner {
        if (monitor == address(0)) revert ZeroAddress();
        authorizedMonitors[monitor] = authorized;
        emit MonitorAuthorizationChanged(monitor, authorized);
    }

    /// @notice Update detection configuration.
    function setConfig(
        uint256 flagThreshold,
        uint256 penaltyThreshold,
        uint256 freezeThreshold,
        uint256 minConfidenceForFlag,
        uint256 basePenaltyAmount,
        uint64 decayPeriod
    ) external onlyOwner {
        if (flagThreshold == 0 || penaltyThreshold <= flagThreshold || freezeThreshold <= penaltyThreshold) {
            revert InvalidThresholds();
        }
        if (minConfidenceForFlag > MAX_CONFIDENCE) revert ConfidenceTooHigh();

        config = DetectionConfig({
            flagThreshold: flagThreshold,
            penaltyThreshold: penaltyThreshold,
            freezeThreshold: freezeThreshold,
            minConfidenceForFlag: minConfidenceForFlag,
            basePenaltyAmount: basePenaltyAmount,
            decayPeriod: decayPeriod
        });

        emit ConfigUpdated();
    }

    // ── Signal Submission ─────────────────────────────────────────────────

    /// @notice Submit a new collusion signal from an off-chain detector.
    function submitSignal(SignalType signalType, address[] calldata participants, uint256 confidence, bytes32 auctionId)
        external
        onlyMonitor
        returns (uint256 signalId)
    {
        if (participants.length == 0) revert EmptyParticipants();
        if (participants.length > MAX_PARTICIPANTS_PER_SIGNAL) revert TooManyParticipants();
        if (confidence > MAX_CONFIDENCE) revert ConfidenceTooHigh();

        signalId = signalCount;
        signalCount++;

        signals[signalId] = CollusionSignal({
            signalId: signalId,
            signalType: signalType,
            participants: participants,
            confidence: confidence,
            auctionId: auctionId,
            detectedAt: uint64(block.timestamp),
            reporter: msg.sender
        });

        // Update actor profiles for each participant
        for (uint256 i = 0; i < participants.length; i++) {
            address actor = participants[i];
            if (actor == address(0)) revert ZeroAddress();

            ActorProfile storage profile = actorProfiles[actor];
            profile.totalSignals++;
            profile.aggregateConfidence += confidence;
            actorSignalIds[actor].push(signalId);

            _evaluateActorStatus(actor);
        }

        emit SignalSubmitted(signalId, signalType, auctionId, confidence, participants.length);
    }

    // ── Collusion Cost Analysis ───────────────────────────────────────────

    /// @notice Compute and store collusion cost analysis.
    ///         Cost rises quadratically as colluders approach network size.
    function computeCollusionCost(uint256 networkSize, uint256 colluders) external onlyMonitor {
        if (networkSize == 0) revert InvalidNetworkSize();
        if (colluders == 0) revert ZeroColluders();
        if (colluders > networkSize) revert ColludersExceedNetwork();

        // controlCostBps = (colluders/networkSize)^2 * 10000
        // Using fixed-point to avoid precision loss:
        // ratio = colluders * 1e18 / networkSize
        // costBps = ratio^2 / 1e18 * 10000 / 1e18
        uint256 ratio = (colluders * CONFIDENCE_PRECISION) / networkSize;
        uint256 costBps = (ratio * ratio * 10_000) / (CONFIDENCE_PRECISION * CONFIDENCE_PRECISION);
        if (costBps > 10_000) costBps = 10_000;

        uint256 expectedPenalty = costBps * colluders;

        latestCostAnalysis = CollusionCostAnalysis({
            networkSize: networkSize,
            colluders: colluders,
            controlCostBps: costBps,
            expectedPenalty: expectedPenalty,
            computedAt: uint64(block.timestamp)
        });

        emit CostAnalysisUpdated(networkSize, colluders, costBps, expectedPenalty);
    }

    // ── Actor Management ──────────────────────────────────────────────────

    /// @notice Reset an actor's status (e.g., after appeal succeeds).
    function resetActorStatus(address actor) external onlyOwner {
        ActorProfile storage profile = actorProfiles[actor];
        if (profile.status == ActorStatus.Clean) revert ActorNotFlagged();

        ActorStatus prev = profile.status;
        profile.status = ActorStatus.Clean;
        profile.totalSignals = 0;
        profile.aggregateConfidence = 0;
        profile.penaltyAmount = 0;
        profile.lastFlaggedAt = 0;
        delete actorSignalIds[actor];

        emit ActorStatusReset(actor, prev);
    }

    // ── Views ─────────────────────────────────────────────────────────────

    /// @notice Get a signal by ID.
    function getSignal(uint256 signalId)
        external
        view
        returns (
            SignalType signalType,
            address[] memory participants,
            uint256 confidence,
            bytes32 auctionId,
            uint64 detectedAt,
            address reporter
        )
    {
        if (signalId >= signalCount) revert SignalNotFound();
        CollusionSignal storage s = signals[signalId];
        return (s.signalType, s.participants, s.confidence, s.auctionId, s.detectedAt, s.reporter);
    }

    /// @notice Get the signal IDs involving a specific actor.
    function getActorSignalIds(address actor) external view returns (uint256[] memory) {
        return actorSignalIds[actor];
    }

    /// @notice Get the number of signals involving a specific actor.
    function getActorSignalCount(address actor) external view returns (uint256) {
        return actorSignalIds[actor].length;
    }

    /// @notice Get the average confidence for an actor's signals.
    function getActorAverageConfidence(address actor) external view returns (uint256) {
        ActorProfile storage profile = actorProfiles[actor];
        if (profile.totalSignals == 0) return 0;
        return profile.aggregateConfidence / profile.totalSignals;
    }

    /// @notice Check if an actor is currently allowed to participate.
    function isActorAllowed(address actor) external view returns (bool) {
        return actorProfiles[actor].status != ActorStatus.Frozen;
    }

    /// @notice Check if an actor is under investigation.
    function isActorFlagged(address actor) external view returns (bool) {
        ActorStatus s = actorProfiles[actor].status;
        return s == ActorStatus.Flagged || s == ActorStatus.Penalized || s == ActorStatus.Frozen;
    }

    /// @notice Get the latest collusion cost analysis.
    function getCostAnalysis()
        external
        view
        returns (
            uint256 networkSize,
            uint256 colluders,
            uint256 controlCostBps,
            uint256 expectedPenalty,
            uint64 computedAt
        )
    {
        CollusionCostAnalysis storage c = latestCostAnalysis;
        return (c.networkSize, c.colluders, c.controlCostBps, c.expectedPenalty, c.computedAt);
    }

    // ── Internal ──────────────────────────────────────────────────────────

    /// @dev Evaluate and update an actor's status based on accumulated signals.
    function _evaluateActorStatus(address actor) internal {
        ActorProfile storage profile = actorProfiles[actor];
        uint256 avgConfidence = profile.aggregateConfidence / profile.totalSignals;

        // Frozen: highest threshold
        if (profile.totalSignals >= config.freezeThreshold && avgConfidence >= config.minConfidenceForFlag) {
            if (profile.status != ActorStatus.Frozen) {
                profile.status = ActorStatus.Frozen;
                profile.lastFlaggedAt = uint64(block.timestamp);
                emit ActorFrozen(actor, profile.totalSignals);
            }
            return;
        }

        // Penalized: middle threshold
        if (profile.totalSignals >= config.penaltyThreshold && avgConfidence >= config.minConfidenceForFlag) {
            if (profile.status != ActorStatus.Penalized && profile.status != ActorStatus.Frozen) {
                profile.penaltyAmount += config.basePenaltyAmount;
                profile.status = ActorStatus.Penalized;
                profile.lastFlaggedAt = uint64(block.timestamp);
                emit ActorPenalized(actor, profile.penaltyAmount, profile.totalSignals);
            }
            return;
        }

        // Flagged: lowest threshold
        if (profile.totalSignals >= config.flagThreshold && avgConfidence >= config.minConfidenceForFlag) {
            if (profile.status == ActorStatus.Clean) {
                profile.status = ActorStatus.Flagged;
                profile.lastFlaggedAt = uint64(block.timestamp);
                emit ActorFlagged(actor, profile.totalSignals, avgConfidence);
            }
            return;
        }
    }
}
