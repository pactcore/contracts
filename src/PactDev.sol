// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {IPactDev} from "./interfaces/IPactDev.sol";

/// @title PactDev
/// @notice On-chain plugin marketplace with revenue sharing (§5.6).
///         Developers register plugins, set prices, and receive 80% of purchase revenue.
///         Protocol treasury receives 20%. Mirrors core domain `plugin-marketplace.ts`.
contract PactDev is IPactDev, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ── Revenue split ────────────────────────────────────────────────
    uint16 public constant DEVELOPER_BPS = 8000; // 80%
    uint16 public constant PROTOCOL_BPS = 2000; // 20%
    uint16 private constant BPS_DENOMINATOR = 10_000;

    // ── State ────────────────────────────────────────────────────────
    IERC20 public immutable usdc;
    address public treasury;

    uint256 private nextPluginId = 1;

    mapping(uint256 pluginId => Plugin) private plugins;
    mapping(uint256 pluginId => mapping(address buyer => bool)) private purchases;
    mapping(address developer => uint256 totalEarned) private earnings;

    // ── Errors ───────────────────────────────────────────────────────
    error ZeroAddress();
    error InvalidAmount();
    error EmptyName();
    error PluginNotFound();
    error PluginNotPublished();
    error PluginDeprecatedError();
    error AlreadyPurchased();
    error AlreadyPublished();
    error NotDraft();
    error Unauthorized();

    // ── Constructor ──────────────────────────────────────────────────
    constructor(address usdcAddress, address treasuryAddress) Ownable(msg.sender) {
        if (usdcAddress == address(0) || treasuryAddress == address(0)) revert ZeroAddress();
        usdc = IERC20(usdcAddress);
        treasury = treasuryAddress;
    }

    // ── Admin ────────────────────────────────────────────────────────
    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert ZeroAddress();
        treasury = newTreasury;
    }

    // ── Plugin lifecycle ─────────────────────────────────────────────

    /// @notice Register a new plugin in Draft status.
    function registerPlugin(string calldata name, bytes32 metadataHash) external returns (uint256 pluginId) {
        if (bytes(name).length == 0) revert EmptyName();

        pluginId = nextPluginId++;
        plugins[pluginId] = Plugin({
            developer: msg.sender,
            metadataHash: metadataHash,
            name: name,
            price: 0,
            status: PluginStatus.Draft,
            totalInstalls: 0,
            totalRevenue: 0,
            createdAt: block.timestamp,
            updatedAt: block.timestamp
        });

        emit PluginRegistered(pluginId, msg.sender, name, metadataHash);
    }

    /// @notice Publish a Draft plugin with a price. Free plugins (price=0) are allowed.
    function publishPlugin(uint256 pluginId, uint256 price) external {
        Plugin storage p = _pluginMustExist(pluginId);
        if (p.developer != msg.sender) revert Unauthorized();
        if (p.status != PluginStatus.Draft) revert NotDraft();

        p.price = price;
        p.status = PluginStatus.Published;
        p.updatedAt = block.timestamp;

        emit PluginPublished(pluginId, price);
    }

    /// @notice Update metadata and/or price of a Published plugin.
    function updatePlugin(uint256 pluginId, bytes32 newMetadataHash, uint256 newPrice) external {
        Plugin storage p = _pluginMustExist(pluginId);
        if (p.developer != msg.sender) revert Unauthorized();
        if (p.status == PluginStatus.Deprecated) revert PluginDeprecatedError();

        p.metadataHash = newMetadataHash;
        p.price = newPrice;
        p.updatedAt = block.timestamp;

        emit PluginUpdated(pluginId, newMetadataHash, newPrice);
    }

    /// @notice Deprecate a plugin so it can no longer be purchased.
    function deprecatePlugin(uint256 pluginId) external {
        Plugin storage p = _pluginMustExist(pluginId);
        if (p.developer != msg.sender) revert Unauthorized();

        p.status = PluginStatus.Deprecated;
        p.updatedAt = block.timestamp;

        emit PluginDeprecated(pluginId);
    }

    // ── Purchase ─────────────────────────────────────────────────────

    /// @notice Purchase/install a published plugin. Splits revenue 80/20.
    function purchasePlugin(uint256 pluginId) external nonReentrant {
        Plugin storage p = _pluginMustExist(pluginId);
        if (p.status != PluginStatus.Published) revert PluginNotPublished();
        if (purchases[pluginId][msg.sender]) revert AlreadyPurchased();

        purchases[pluginId][msg.sender] = true;
        p.totalInstalls++;

        uint256 gross = p.price;
        uint256 devPayout;
        uint256 protocolPayout;

        if (gross > 0) {
            devPayout = (gross * DEVELOPER_BPS) / BPS_DENOMINATOR;
            protocolPayout = gross - devPayout;

            // Pull USDC from buyer
            usdc.safeTransferFrom(msg.sender, p.developer, devPayout);
            usdc.safeTransferFrom(msg.sender, treasury, protocolPayout);

            p.totalRevenue += gross;
            earnings[p.developer] += devPayout;
        }

        emit PluginPurchased(pluginId, msg.sender, gross, devPayout, protocolPayout);
    }

    // ── Views ────────────────────────────────────────────────────────

    function getPlugin(uint256 pluginId) external view returns (Plugin memory) {
        return _pluginMustExist(pluginId);
    }

    function hasPurchased(uint256 pluginId, address buyer) external view returns (bool) {
        return purchases[pluginId][buyer];
    }

    function developerEarnings(address developer) external view returns (uint256) {
        return earnings[developer];
    }

    // ── Internal ─────────────────────────────────────────────────────

    function _pluginMustExist(uint256 pluginId) internal view returns (Plugin storage p) {
        p = plugins[pluginId];
        if (p.developer == address(0)) revert PluginNotFound();
    }
}
