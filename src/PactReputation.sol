// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";

/// @title PactReputation
/// @notice On-chain multi-role reputation scores for PACT participants (§6.4).
///         Scores range [0, 100]. Inactive participants suffer periodic decay
///         after an inactivity threshold is exceeded.
contract PactReputation is Ownable {
    uint8 public constant MAX_SCORE = 100;
    uint8 public constant MIN_SCORE = 0;
    uint8 public constant INITIAL_SCORE = 50;

    /// @notice Seconds of inactivity before decay begins.
    uint256 public immutable inactivityThreshold;
    /// @notice Seconds per decay period (after the threshold).
    uint256 public immutable decayPeriod;
    /// @notice Points deducted per decay period.
    uint8 public immutable decayAmount;

    enum Role {
        Worker,
        Validator,
        Issuer
    }

    struct Score {
        uint8 value;
        uint64 lastUpdated; // 0 means never set; score treated as INITIAL_SCORE
    }

    mapping(address participant => mapping(Role role => Score)) private scores;

    /// @notice Addresses permitted to call adjustScore (besides owner).
    mapping(address updater => bool) public authorizedUpdaters;

    event ScoreUpdated(address indexed participant, Role indexed role, uint8 oldScore, uint8 newScore);
    event ScoreDecayed(address indexed participant, Role indexed role, uint8 oldScore, uint8 newScore);
    event UpdaterAuthorizationChanged(address indexed updater, bool authorized);

    error ZeroAddress();
    error InvalidAdjustment();
    error UnauthorizedUpdater();

    modifier onlyAuthorized() {
        if (msg.sender != owner() && !authorizedUpdaters[msg.sender]) revert UnauthorizedUpdater();
        _;
    }

    constructor(uint256 inactivityThresholdSeconds, uint256 decayPeriodSeconds, uint8 decayAmountPoints)
        Ownable(msg.sender)
    {
        inactivityThreshold = inactivityThresholdSeconds;
        decayPeriod = decayPeriodSeconds;
        decayAmount = decayAmountPoints;
    }

    /// @notice Grant or revoke updater permission.
    function setAuthorizedUpdater(address updater, bool authorized) external onlyOwner {
        if (updater == address(0)) revert ZeroAddress();
        authorizedUpdaters[updater] = authorized;
        emit UpdaterAuthorizationChanged(updater, authorized);
    }

    /// @notice Adjust a participant's score by `delta` points.
    ///         Decay is applied to the stored value before the adjustment.
    ///         Resets the inactivity clock.
    function adjustScore(address participant, Role role, int8 delta) external onlyAuthorized {
        if (participant == address(0)) revert ZeroAddress();
        if (delta == 0) revert InvalidAdjustment();

        Score storage s = scores[participant][role];

        // Apply any pending decay first to get the true current score.
        uint8 current = _computeScore(s);
        uint8 oldScore = current;

        uint8 newScore;
        if (delta > 0) {
            uint8 inc = uint8(delta);
            newScore = (uint16(current) + inc > MAX_SCORE) ? MAX_SCORE : current + inc;
        } else {
            uint8 dec = uint8(-delta);
            newScore = (dec > current) ? MIN_SCORE : current - dec;
        }

        // CEI: write state before any external calls (none here, but pattern preserved)
        s.value = newScore;
        s.lastUpdated = uint64(block.timestamp);

        emit ScoreUpdated(participant, role, oldScore, newScore);
    }

    /// @notice Materialise decay for a participant's role score.
    ///         Anyone can call this; no access restriction needed.
    function applyDecay(address participant, Role role) external {
        Score storage s = scores[participant][role];
        if (s.lastUpdated == 0) return; // Never set; nothing to decay

        uint8 oldScore = s.value;
        uint8 decayed = _computeDecay(s);

        if (decayed != oldScore) {
            s.value = decayed;
            s.lastUpdated = uint64(block.timestamp);
            emit ScoreDecayed(participant, role, oldScore, decayed);
        }
    }

    /// @notice Read the effective (decay-adjusted) score for a participant and role.
    function getScore(address participant, Role role) external view returns (uint8) {
        return _computeScore(scores[participant][role]);
    }

    /// @notice Read effective score plus the stored last-updated timestamp.
    function getScoreWithTimestamp(address participant, Role role)
        external
        view
        returns (uint8 value, uint64 lastUpdated)
    {
        Score storage s = scores[participant][role];
        value = _computeScore(s);
        lastUpdated = s.lastUpdated;
    }

    // ── Internal helpers ──────────────────────────────────────────────────────

    /// @dev Return score accounting for decay. Returns INITIAL_SCORE if never set.
    function _computeScore(Score storage s) internal view returns (uint8) {
        if (s.lastUpdated == 0) return INITIAL_SCORE;
        return _computeDecay(s);
    }

    /// @dev Apply the decay formula to an already-set score.
    function _computeDecay(Score storage s) internal view returns (uint8) {
        uint256 elapsed = block.timestamp - s.lastUpdated;
        if (elapsed < inactivityThreshold) return s.value;

        // Number of full decay periods elapsed beyond the threshold.
        uint256 periods = (elapsed - inactivityThreshold) / decayPeriod + 1;
        uint256 totalDecay = periods * uint256(decayAmount);

        if (totalDecay >= s.value) return MIN_SCORE;
        return uint8(s.value - totalDecay);
    }
}
