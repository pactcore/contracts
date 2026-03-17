// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IPactGasSponsor
/// @notice Interface for the PACT gas sponsorship contract (whitepaper §5.2).
interface IPactGasSponsor {
    // ── Structs ──────────────────────────────────────────────────────────

    struct SponsorPool {
        address owner;
        string name;
        uint256 balance;
        uint256 dailyLimitPerUser;
        uint256 minReputation;
        uint256 minIdentityLevel;
        bool whitelistOnly;
        bool active;
    }

    // ── Events ───────────────────────────────────────────────────────────

    event PoolCreated(uint256 indexed poolId, address indexed owner, string name, uint256 deposit);
    event PoolFunded(uint256 indexed poolId, address indexed funder, uint256 amount);
    event GasSponsored(uint256 indexed poolId, address indexed user, address indexed relayer, uint256 amount);
    event PoolWithdrawn(uint256 indexed poolId, address indexed owner, uint256 amount);
    event WhitelistUpdated(uint256 indexed poolId, address[] users, bool added);
    event RelayerAuthorized(address indexed relayer, bool authorized);
    event PoolDeactivated(uint256 indexed poolId);

    // ── Errors ───────────────────────────────────────────────────────────

    error NotPoolOwner();
    error PoolNotActive();
    error PoolNotFound();
    error InsufficientPoolBalance();
    error DailyLimitExceeded();
    error NotEligible();
    error NotAuthorizedRelayer();
    error ZeroAmount();
    error WithdrawFailed();

    // ── Pool management ──────────────────────────────────────────────────

    function createPool(
        string calldata name,
        uint256 dailyLimitPerUser,
        uint256 minReputation,
        uint256 minIdentityLevel,
        bool whitelistOnly
    ) external payable returns (uint256 poolId);

    function fundPool(uint256 poolId) external payable;

    function withdrawPool(uint256 poolId, uint256 amount) external;

    function deactivatePool(uint256 poolId) external;

    // ── Whitelist ────────────────────────────────────────────────────────

    function addToWhitelist(uint256 poolId, address[] calldata users) external;

    function removeFromWhitelist(uint256 poolId, address[] calldata users) external;

    // ── Gas sponsorship ──────────────────────────────────────────────────

    function sponsorGas(uint256 poolId, address user, uint256 gasUsed) external;

    // ── Views ────────────────────────────────────────────────────────────

    function getPool(uint256 poolId) external view returns (SponsorPool memory);

    function getUserDailyUsage(uint256 poolId, address user) external view returns (uint256);

    function isEligible(uint256 poolId, address user) external view returns (bool);

    function isWhitelisted(uint256 poolId, address user) external view returns (bool);
}
