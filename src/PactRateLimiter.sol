// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";

/// @title PactRateLimiter
/// @notice On-chain rate limiting and anti-spam controls for PACT (§12).
///         Token-bucket per account with configurable refill rate.
///         Integrates with stake escalation: repeated offenders must increase
///         their anti-spam deposit to regain quota.
contract PactRateLimiter is Ownable {
    // ── Structs ───────────────────────────────────────────────────────────

    struct RateLimitConfig {
        uint256 maxTokens; // bucket capacity
        uint256 refillRate; // tokens per second
        uint256 windowSeconds; // sliding window for violation tracking
        uint256 violationThreshold; // violations before escalation
        uint256 baseStakeEscalation; // additional stake per escalation (cents)
        uint256 cooldownSeconds; // cooldown after hitting limit
    }

    struct AccountBucket {
        uint256 tokens; // current available tokens
        uint64 lastRefillAt; // last refill timestamp
        uint32 violations; // violation count in current window
        uint64 windowStart; // start of current violation window
        uint32 escalationLevel; // how many times escalated
        uint64 cooldownUntil; // timestamp until which account is rate-limited
        bool exists;
    }

    // ── State ─────────────────────────────────────────────────────────────
    RateLimitConfig public config;
    mapping(address => AccountBucket) public buckets;
    mapping(address => bool) public authorizedCallers;

    uint256 public totalViolations;
    uint256 public totalRequests;

    // ── Events ────────────────────────────────────────────────────────────
    event RequestAllowed(address indexed account, uint256 remainingTokens);
    event RequestDenied(address indexed account, uint256 cooldownUntil);
    event ViolationRecorded(address indexed account, uint32 totalViolations, uint32 escalationLevel);
    event EscalationApplied(address indexed account, uint32 newLevel, uint256 additionalStakeRequired);
    event BucketReset(address indexed account);
    event ConfigUpdated();
    event CallerAuthorizationChanged(address indexed caller, bool authorized);

    // ── Errors ────────────────────────────────────────────────────────────
    error ZeroAddress();
    error UnauthorizedCaller();
    error InvalidConfig();
    error AccountInCooldown(uint64 until);

    // ── Modifiers ─────────────────────────────────────────────────────────
    modifier onlyAuthorizedOrOwner() {
        if (msg.sender != owner() && !authorizedCallers[msg.sender]) revert UnauthorizedCaller();
        _;
    }

    // ── Constructor ───────────────────────────────────────────────────────
    constructor() Ownable(msg.sender) {
        config = RateLimitConfig({
            maxTokens: 100,
            refillRate: 1, // 1 token/sec → 100 sec to full bucket
            windowSeconds: 3600, // 1 hour violation window
            violationThreshold: 5, // 5 violations → escalation
            baseStakeEscalation: 500, // $5 per escalation level
            cooldownSeconds: 300 // 5 min cooldown
        });
    }

    // ── Admin ─────────────────────────────────────────────────────────────

    function setAuthorizedCaller(address caller, bool authorized) external onlyOwner {
        if (caller == address(0)) revert ZeroAddress();
        authorizedCallers[caller] = authorized;
        emit CallerAuthorizationChanged(caller, authorized);
    }

    function updateConfig(
        uint256 maxTokens,
        uint256 refillRate,
        uint256 windowSeconds,
        uint256 violationThreshold,
        uint256 baseStakeEscalation,
        uint256 cooldownSeconds
    ) external onlyOwner {
        if (maxTokens == 0 || refillRate == 0 || windowSeconds == 0 || violationThreshold == 0) {
            revert InvalidConfig();
        }
        config = RateLimitConfig({
            maxTokens: maxTokens,
            refillRate: refillRate,
            windowSeconds: windowSeconds,
            violationThreshold: violationThreshold,
            baseStakeEscalation: baseStakeEscalation,
            cooldownSeconds: cooldownSeconds
        });
        emit ConfigUpdated();
    }

    // ── Core ──────────────────────────────────────────────────────────────

    /// @notice Consume a rate-limit token for `account`. Returns true if allowed.
    function consumeToken(address account) external onlyAuthorizedOrOwner returns (bool allowed) {
        if (account == address(0)) revert ZeroAddress();

        AccountBucket storage b = buckets[account];
        _ensureInitialized(b);
        _refill(b);

        totalRequests += 1;

        // Check cooldown
        if (block.timestamp < b.cooldownUntil) {
            _recordViolation(b, account);
            emit RequestDenied(account, b.cooldownUntil);
            return false;
        }

        // Check tokens
        if (b.tokens == 0) {
            b.cooldownUntil = uint64(block.timestamp + config.cooldownSeconds);
            _recordViolation(b, account);
            emit RequestDenied(account, b.cooldownUntil);
            return false;
        }

        b.tokens -= 1;
        emit RequestAllowed(account, b.tokens);
        return true;
    }

    /// @notice Check available tokens without consuming.
    function availableTokens(address account) external view returns (uint256) {
        AccountBucket storage b = buckets[account];
        if (!b.exists) return config.maxTokens;

        uint256 elapsed = block.timestamp > b.lastRefillAt ? block.timestamp - b.lastRefillAt : 0;
        uint256 refilled = b.tokens + elapsed * config.refillRate;
        return refilled > config.maxTokens ? config.maxTokens : refilled;
    }

    /// @notice Check if account is currently in cooldown.
    function isInCooldown(address account) external view returns (bool) {
        return block.timestamp < buckets[account].cooldownUntil;
    }

    /// @notice Get the stake escalation amount for an account.
    function getRequiredStakeEscalation(address account) external view returns (uint256) {
        return uint256(buckets[account].escalationLevel) * config.baseStakeEscalation;
    }

    /// @notice Reset an account's bucket (admin recovery).
    function resetBucket(address account) external onlyOwner {
        if (account == address(0)) revert ZeroAddress();
        delete buckets[account];
        emit BucketReset(account);
    }

    /// @notice Get bucket info.
    function getBucket(address account)
        external
        view
        returns (
            uint256 tokens,
            uint64 lastRefillAt,
            uint32 violations,
            uint32 escalationLevel,
            uint64 cooldownUntil,
            bool exists
        )
    {
        AccountBucket storage b = buckets[account];
        return (b.tokens, b.lastRefillAt, b.violations, b.escalationLevel, b.cooldownUntil, b.exists);
    }

    // ── Internal ──────────────────────────────────────────────────────────

    function _ensureInitialized(AccountBucket storage b) internal {
        if (!b.exists) {
            b.tokens = config.maxTokens;
            b.lastRefillAt = uint64(block.timestamp);
            b.windowStart = uint64(block.timestamp);
            b.exists = true;
        }
    }

    function _refill(AccountBucket storage b) internal {
        if (block.timestamp <= b.lastRefillAt) return;

        uint256 elapsed = block.timestamp - b.lastRefillAt;
        uint256 refilled = b.tokens + elapsed * config.refillRate;
        b.tokens = refilled > config.maxTokens ? config.maxTokens : refilled;
        b.lastRefillAt = uint64(block.timestamp);
    }

    function _recordViolation(AccountBucket storage b, address account) internal {
        totalViolations += 1;

        // Reset window if expired
        if (block.timestamp > b.windowStart + config.windowSeconds) {
            b.violations = 0;
            b.windowStart = uint64(block.timestamp);
        }

        b.violations += 1;
        emit ViolationRecorded(account, b.violations, b.escalationLevel);

        // Escalate if threshold reached
        if (b.violations >= config.violationThreshold) {
            b.escalationLevel += 1;
            b.violations = 0;
            b.windowStart = uint64(block.timestamp);
            // Increase cooldown with escalation
            b.cooldownUntil = uint64(block.timestamp + config.cooldownSeconds * (1 + b.escalationLevel));
            emit EscalationApplied(account, b.escalationLevel, uint256(b.escalationLevel) * config.baseStakeEscalation);
        }
    }
}
