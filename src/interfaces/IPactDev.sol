// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IPactDev
/// @notice Interface for the PactDev plugin marketplace and revenue share (§5.6).
interface IPactDev {
    // ── Enums ────────────────────────────────────────────────────────
    enum PluginStatus {
        Draft,
        Published,
        Deprecated
    }

    // ── Structs ──────────────────────────────────────────────────────
    struct Plugin {
        address developer;
        bytes32 metadataHash; // IPFS CID or content hash
        string name;
        uint256 price; // USDC in wei (6 decimals)
        PluginStatus status;
        uint256 totalInstalls;
        uint256 totalRevenue;
        uint256 createdAt;
        uint256 updatedAt;
    }

    struct RevenueRecord {
        uint256 pluginId;
        address buyer;
        uint256 grossAmount;
        uint256 developerPayout;
        uint256 protocolPayout;
        uint256 timestamp;
    }

    // ── Events ───────────────────────────────────────────────────────
    event PluginRegistered(uint256 indexed pluginId, address indexed developer, string name, bytes32 metadataHash);
    event PluginPublished(uint256 indexed pluginId, uint256 price);
    event PluginDeprecated(uint256 indexed pluginId);
    event PluginUpdated(uint256 indexed pluginId, bytes32 newMetadataHash, uint256 newPrice);
    event PluginPurchased(
        uint256 indexed pluginId,
        address indexed buyer,
        uint256 grossAmount,
        uint256 developerPayout,
        uint256 protocolPayout
    );

    // ── Views ────────────────────────────────────────────────────────
    function getPlugin(uint256 pluginId) external view returns (Plugin memory);
    function hasPurchased(uint256 pluginId, address buyer) external view returns (bool);
    function developerEarnings(address developer) external view returns (uint256);
}
