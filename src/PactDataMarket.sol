// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

/// @title PactDataMarket
/// @notice Data listing marketplace with escrow-based purchase flow.
///         Revenue split: 70% seller, 10% validators, 20% treasury (§5.4).
contract PactDataMarket is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint16 public constant SELLER_BPS = 7000;
    uint16 public constant VALIDATORS_BPS = 1000;
    uint16 public constant TREASURY_BPS = 2000;
    uint16 private constant BPS_DENOMINATOR = 10_000;

    IERC20 public immutable usdc;
    address public validators;
    address public treasury;

    uint256 private nextListingId = 1;

    struct Listing {
        address seller;
        bytes32 metadataHash;
        uint256 price;
        bool active;
    }

    mapping(uint256 listingId => Listing) private listings;
    mapping(uint256 listingId => mapping(address buyer => bool)) private buyerAccess;

    event ListingCreated(uint256 indexed listingId, address indexed seller, bytes32 metadataHash, uint256 price);
    event ListingDeactivated(uint256 indexed listingId);
    event DataPurchased(uint256 indexed listingId, address indexed buyer, uint256 price);

    error ZeroAddress();
    error InvalidAmount();
    error ListingNotFound();
    error ListingInactive();
    error AlreadyPurchased();
    error Unauthorized();

    constructor(address usdcAddress, address validatorsAddress, address treasuryAddress) Ownable(msg.sender) {
        if (usdcAddress == address(0) || validatorsAddress == address(0) || treasuryAddress == address(0)) {
            revert ZeroAddress();
        }
        usdc = IERC20(usdcAddress);
        validators = validatorsAddress;
        treasury = treasuryAddress;
    }

    /// @notice Create a new data listing.
    function createListing(bytes32 metadataHash, uint256 price) external returns (uint256 listingId) {
        if (price == 0) revert InvalidAmount();

        listingId = nextListingId;
        nextListingId++;

        listings[listingId] = Listing({seller: msg.sender, metadataHash: metadataHash, price: price, active: true});

        emit ListingCreated(listingId, msg.sender, metadataHash, price);
    }

    /// @notice Deactivate a listing. Caller must be seller or contract owner.
    function deactivateListing(uint256 listingId) external {
        Listing storage listing = listings[listingId];
        if (listing.seller == address(0)) revert ListingNotFound();
        if (msg.sender != listing.seller && msg.sender != owner()) revert Unauthorized();

        listing.active = false;
        emit ListingDeactivated(listingId);
    }

    /// @notice Purchase a data listing. USDC is split directly to seller, validators, and treasury.
    function purchase(uint256 listingId) external nonReentrant {
        Listing storage listing = listings[listingId];
        if (listing.seller == address(0)) revert ListingNotFound();
        if (!listing.active) revert ListingInactive();
        if (buyerAccess[listingId][msg.sender]) revert AlreadyPurchased();

        uint256 price = listing.price;
        address seller = listing.seller;

        // Effects before interactions (CEI)
        buyerAccess[listingId][msg.sender] = true;

        uint256 validatorsAmount = (price * VALIDATORS_BPS) / BPS_DENOMINATOR;
        uint256 treasuryAmount = (price * TREASURY_BPS) / BPS_DENOMINATOR;
        uint256 sellerAmount = price - validatorsAmount - treasuryAmount;

        usdc.safeTransferFrom(msg.sender, seller, sellerAmount);
        usdc.safeTransferFrom(msg.sender, validators, validatorsAmount);
        usdc.safeTransferFrom(msg.sender, treasury, treasuryAmount);

        emit DataPurchased(listingId, msg.sender, price);
    }

    /// @notice Check whether a buyer has purchased a listing.
    function hasAccess(uint256 listingId, address buyer) external view returns (bool) {
        return buyerAccess[listingId][buyer];
    }

    /// @notice Return listing metadata.
    function getListing(uint256 listingId) external view returns (Listing memory) {
        return listings[listingId];
    }

    /// @notice Return the next listing ID (useful for off-chain indexing).
    function getNextListingId() external view returns (uint256) {
        return nextListingId;
    }
}
