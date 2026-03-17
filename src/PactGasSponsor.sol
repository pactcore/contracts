// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {IERC721} from "openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";
import {IPactGasSponsor} from "./interfaces/IPactGasSponsor.sol";

/// @title PactGasSponsor
/// @notice On-chain gas sponsorship pools for the PACT network (whitepaper §5.2).
///         Sponsors create ETH pools with eligibility criteria (reputation, identity level,
///         whitelist). Authorized relayers claim gas reimbursement on behalf of qualifying users.
contract PactGasSponsor is IPactGasSponsor, Ownable, ReentrancyGuard {
    // ── External contracts ───────────────────────────────────────────────

    /// @notice PactReputation contract for score lookups.
    address public immutable REPUTATION;

    /// @notice PactIdentitySBT contract for identity level lookups.
    address public immutable IDENTITY_SBT;

    // ── State ────────────────────────────────────────────────────────────

    uint256 private _nextPoolId = 1;

    /// @notice poolId → SponsorPool data.
    mapping(uint256 poolId => SponsorPool) private _pools;

    /// @notice poolId → user → whitelisted.
    mapping(uint256 poolId => mapping(address user => bool)) private _whitelist;

    /// @notice poolId → user → day → amount used.
    mapping(uint256 poolId => mapping(address user => mapping(uint256 day => uint256 used))) private _dailyUsage;

    /// @notice Authorized relayer addresses.
    mapping(address relayer => bool) public authorizedRelayers;

    // ── Constructor ──────────────────────────────────────────────────────

    constructor(address reputation, address identitySbt) Ownable(msg.sender) {
        REPUTATION = reputation;
        IDENTITY_SBT = identitySbt;
    }

    // ── Modifiers ────────────────────────────────────────────────────────

    modifier onlyPoolOwner(uint256 poolId) {
        if (_pools[poolId].owner == address(0)) revert PoolNotFound();
        if (_pools[poolId].owner != msg.sender) revert NotPoolOwner();
        _;
    }

    modifier onlyRelayer() {
        if (!authorizedRelayers[msg.sender]) revert NotAuthorizedRelayer();
        _;
    }

    modifier poolActive(uint256 poolId) {
        if (_pools[poolId].owner == address(0)) revert PoolNotFound();
        if (!_pools[poolId].active) revert PoolNotActive();
        _;
    }

    // ── Admin ────────────────────────────────────────────────────────────

    /// @notice Authorize or deauthorize a relayer address.
    function setRelayerAuthorization(address relayer, bool authorized) external onlyOwner {
        authorizedRelayers[relayer] = authorized;
        emit RelayerAuthorized(relayer, authorized);
    }

    // ── Pool management ──────────────────────────────────────────────────

    /// @inheritdoc IPactGasSponsor
    function createPool(
        string calldata name,
        uint256 dailyLimitPerUser,
        uint256 minReputation,
        uint256 minIdentityLevel,
        bool whitelistOnly
    ) external payable returns (uint256 poolId) {
        poolId = _nextPoolId++;

        _pools[poolId] = SponsorPool({
            owner: msg.sender,
            name: name,
            balance: msg.value,
            dailyLimitPerUser: dailyLimitPerUser,
            minReputation: minReputation,
            minIdentityLevel: minIdentityLevel,
            whitelistOnly: whitelistOnly,
            active: true
        });

        emit PoolCreated(poolId, msg.sender, name, msg.value);
    }

    /// @inheritdoc IPactGasSponsor
    function fundPool(uint256 poolId) external payable poolActive(poolId) {
        if (msg.value == 0) revert ZeroAmount();
        _pools[poolId].balance += msg.value;
        emit PoolFunded(poolId, msg.sender, msg.value);
    }

    /// @inheritdoc IPactGasSponsor
    function withdrawPool(uint256 poolId, uint256 amount) external nonReentrant onlyPoolOwner(poolId) {
        if (amount == 0) revert ZeroAmount();
        SponsorPool storage pool = _pools[poolId];
        if (pool.balance < amount) revert InsufficientPoolBalance();

        pool.balance -= amount;

        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert WithdrawFailed();

        emit PoolWithdrawn(poolId, msg.sender, amount);
    }

    /// @inheritdoc IPactGasSponsor
    function deactivatePool(uint256 poolId) external onlyPoolOwner(poolId) {
        _pools[poolId].active = false;
        emit PoolDeactivated(poolId);
    }

    // ── Whitelist ────────────────────────────────────────────────────────

    /// @inheritdoc IPactGasSponsor
    function addToWhitelist(uint256 poolId, address[] calldata users) external onlyPoolOwner(poolId) {
        for (uint256 i; i < users.length; ++i) {
            _whitelist[poolId][users[i]] = true;
        }
        emit WhitelistUpdated(poolId, users, true);
    }

    /// @inheritdoc IPactGasSponsor
    function removeFromWhitelist(uint256 poolId, address[] calldata users) external onlyPoolOwner(poolId) {
        for (uint256 i; i < users.length; ++i) {
            _whitelist[poolId][users[i]] = false;
        }
        emit WhitelistUpdated(poolId, users, false);
    }

    // ── Gas sponsorship ──────────────────────────────────────────────────

    /// @inheritdoc IPactGasSponsor
    function sponsorGas(uint256 poolId, address user, uint256 gasUsed)
        external
        nonReentrant
        onlyRelayer
        poolActive(poolId)
    {
        if (gasUsed == 0) revert ZeroAmount();

        SponsorPool storage pool = _pools[poolId];

        // Eligibility
        if (!_isEligible(poolId, pool, user)) revert NotEligible();

        // Daily limit
        uint256 today = block.timestamp / 86400;
        uint256 used = _dailyUsage[poolId][user][today];
        if (used + gasUsed > pool.dailyLimitPerUser) revert DailyLimitExceeded();

        // Pool balance
        if (pool.balance < gasUsed) revert InsufficientPoolBalance();

        // Execute
        _dailyUsage[poolId][user][today] = used + gasUsed;
        pool.balance -= gasUsed;

        // Reimburse relayer
        (bool ok,) = msg.sender.call{value: gasUsed}("");
        if (!ok) revert WithdrawFailed();

        emit GasSponsored(poolId, user, msg.sender, gasUsed);
    }

    // ── Views ────────────────────────────────────────────────────────────

    /// @inheritdoc IPactGasSponsor
    function getPool(uint256 poolId) external view returns (SponsorPool memory) {
        if (_pools[poolId].owner == address(0)) revert PoolNotFound();
        return _pools[poolId];
    }

    /// @inheritdoc IPactGasSponsor
    function getUserDailyUsage(uint256 poolId, address user) external view returns (uint256) {
        return _dailyUsage[poolId][user][block.timestamp / 86400];
    }

    /// @inheritdoc IPactGasSponsor
    function isEligible(uint256 poolId, address user) external view returns (bool) {
        SponsorPool storage pool = _pools[poolId];
        if (pool.owner == address(0)) revert PoolNotFound();
        return _isEligible(poolId, pool, user);
    }

    /// @inheritdoc IPactGasSponsor
    function isWhitelisted(uint256 poolId, address user) external view returns (bool) {
        return _whitelist[poolId][user];
    }

    // ── Internal ─────────────────────────────────────────────────────────

    function _isEligible(uint256 poolId, SponsorPool storage pool, address user) internal view returns (bool) {
        // Whitelist check
        if (pool.whitelistOnly && !_whitelist[poolId][user]) {
            return false;
        }

        // Reputation check (Worker role = 0)
        if (pool.minReputation > 0 && REPUTATION != address(0)) {
            // PactReputation.getScore(address, Role) returns uint8
            (bool ok, bytes memory data) =
                REPUTATION.staticcall(abi.encodeWithSignature("getScore(address,uint8)", user, uint8(0)));
            if (!ok || data.length < 32) return false;
            uint8 score = abi.decode(data, (uint8));
            if (score < pool.minReputation) return false;
        }

        // Identity level check
        if (pool.minIdentityLevel > 0 && IDENTITY_SBT != address(0)) {
            // Check user owns at least one SBT
            (bool ok, bytes memory data) = IDENTITY_SBT.staticcall(abi.encodeWithSignature("balanceOf(address)", user));
            if (!ok || data.length < 32) return false;
            uint256 balance = abi.decode(data, (uint256));
            if (balance == 0) return false;
        }

        return true;
    }
}
