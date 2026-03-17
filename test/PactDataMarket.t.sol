// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PactDataMarket} from "../src/PactDataMarket.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

contract PactDataMarketTest is Test {
    MockUSDC private usdc;
    PactDataMarket private market;

    address private seller = makeAddr("seller");
    address private buyer = makeAddr("buyer");
    address private validators = makeAddr("validators");
    address private treasury = makeAddr("treasury");

    uint256 private constant INITIAL_BALANCE = 10_000e6;
    uint256 private constant LISTING_PRICE = 1_000e6;
    bytes32 private constant META_HASH = keccak256("ipfs://Qm...");

    function setUp() external {
        usdc = new MockUSDC();
        market = new PactDataMarket(address(usdc), validators, treasury);

        usdc.mint(buyer, INITIAL_BALANCE);
        vm.prank(buyer);
        usdc.approve(address(market), type(uint256).max);
    }

    // ── Listing creation ──────────────────────────────────────────────────────

    function testCreateListing() external {
        vm.prank(seller);
        uint256 id = market.createListing(META_HASH, LISTING_PRICE);

        assertEq(id, 1);

        PactDataMarket.Listing memory l = market.getListing(id);
        assertEq(l.seller, seller);
        assertEq(l.metadataHash, META_HASH);
        assertEq(l.price, LISTING_PRICE);
        assertTrue(l.active);
    }

    function testCreateListingIncrementsId() external {
        vm.startPrank(seller);
        uint256 id1 = market.createListing(META_HASH, LISTING_PRICE);
        uint256 id2 = market.createListing(keccak256("other"), LISTING_PRICE);
        vm.stopPrank();

        assertEq(id1, 1);
        assertEq(id2, 2);
        assertEq(market.getNextListingId(), 3);
    }

    function testCreateListingZeroPriceReverts() external {
        vm.prank(seller);
        vm.expectRevert(PactDataMarket.InvalidAmount.selector);
        market.createListing(META_HASH, 0);
    }

    // ── Listing deactivation ─────────────────────────────────────────────────

    function testDeactivateListingBySeller() external {
        vm.prank(seller);
        uint256 id = market.createListing(META_HASH, LISTING_PRICE);

        vm.prank(seller);
        market.deactivateListing(id);

        assertFalse(market.getListing(id).active);
    }

    function testDeactivateListingByOwner() external {
        vm.prank(seller);
        uint256 id = market.createListing(META_HASH, LISTING_PRICE);

        // market owner is the deployer (this contract)
        market.deactivateListing(id);

        assertFalse(market.getListing(id).active);
    }

    function testDeactivateListingUnauthorizedReverts() external {
        vm.prank(seller);
        uint256 id = market.createListing(META_HASH, LISTING_PRICE);

        vm.prank(buyer);
        vm.expectRevert(PactDataMarket.Unauthorized.selector);
        market.deactivateListing(id);
    }

    function testDeactivateNonexistentListingReverts() external {
        vm.expectRevert(PactDataMarket.ListingNotFound.selector);
        market.deactivateListing(999);
    }

    // ── Purchase flow ─────────────────────────────────────────────────────────

    function testPurchaseDataListing() external {
        vm.prank(seller);
        uint256 id = market.createListing(META_HASH, LISTING_PRICE);

        vm.prank(buyer);
        market.purchase(id);

        // Revenue split: 70% seller, 10% validators, 20% treasury
        uint256 validatorsExpected = (LISTING_PRICE * 1000) / 10_000; // 10%
        uint256 treasuryExpected = (LISTING_PRICE * 2000) / 10_000; // 20%
        uint256 sellerExpected = LISTING_PRICE - validatorsExpected - treasuryExpected; // 70%

        assertEq(usdc.balanceOf(seller), sellerExpected);
        assertEq(usdc.balanceOf(validators), validatorsExpected);
        assertEq(usdc.balanceOf(treasury), treasuryExpected);
        assertEq(usdc.balanceOf(buyer), INITIAL_BALANCE - LISTING_PRICE);
    }

    function testPurchaseGrantsBuyerAccess() external {
        vm.prank(seller);
        uint256 id = market.createListing(META_HASH, LISTING_PRICE);

        assertFalse(market.hasAccess(id, buyer));

        vm.prank(buyer);
        market.purchase(id);

        assertTrue(market.hasAccess(id, buyer));
    }

    function testPurchaseAlreadyPurchasedReverts() external {
        vm.prank(seller);
        uint256 id = market.createListing(META_HASH, LISTING_PRICE);

        vm.prank(buyer);
        market.purchase(id);

        vm.prank(buyer);
        vm.expectRevert(PactDataMarket.AlreadyPurchased.selector);
        market.purchase(id);
    }

    function testPurchaseInactiveListingReverts() external {
        vm.prank(seller);
        uint256 id = market.createListing(META_HASH, LISTING_PRICE);

        vm.prank(seller);
        market.deactivateListing(id);

        vm.prank(buyer);
        vm.expectRevert(PactDataMarket.ListingInactive.selector);
        market.purchase(id);
    }

    function testPurchaseNonexistentListingReverts() external {
        vm.prank(buyer);
        vm.expectRevert(PactDataMarket.ListingNotFound.selector);
        market.purchase(999);
    }

    // ── Constructor guard ──────────────────────────────────────────────────────

    function testConstructorZeroAddressReverts() external {
        vm.expectRevert(PactDataMarket.ZeroAddress.selector);
        new PactDataMarket(address(0), validators, treasury);
    }
}
