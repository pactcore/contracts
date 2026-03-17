// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PactAuction} from "../src/PactAuction.sol";
import {IPactAuction} from "../src/interfaces/IPactAuction.sol";

contract PactAuctionTest is Test {
    PactAuction public auction;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address charlie = makeAddr("charlie");
    address dave = makeAddr("dave");

    uint256 constant JOB_ID = 42;

    function setUp() public {
        auction = new PactAuction(address(0)); // no reputation gating
    }

    // ── Helpers ──

    function _sealBid(address bidder, uint256 amount, bytes32 salt) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(bidder, amount, salt));
    }

    function _createDefaultAuction() internal returns (uint256 auctionId) {
        uint64 bidDeadline = uint64(block.timestamp + 1 hours);
        uint64 revealDeadline = uint64(block.timestamp + 2 hours);
        auctionId = auction.createAuction(JOB_ID, bidDeadline, revealDeadline, 0);
    }

    // ── Creation ──

    function test_createAuction_emitsEvent() public {
        uint64 bidDeadline = uint64(block.timestamp + 1 hours);
        uint64 revealDeadline = uint64(block.timestamp + 2 hours);

        vm.expectEmit(true, true, false, true);
        emit IPactAuction.AuctionCreated(1, JOB_ID, bidDeadline, revealDeadline);

        auction.createAuction(JOB_ID, bidDeadline, revealDeadline, 0);
    }

    function test_createAuction_storesCorrectData() public {
        uint256 id = _createDefaultAuction();
        IPactAuction.Auction memory a = auction.getAuction(id);

        assertEq(a.jobId, JOB_ID);
        assertEq(uint8(a.status), uint8(IPactAuction.AuctionStatus.Bidding));
        assertEq(a.winner, address(0));
        assertEq(a.winningPrice, 0);
    }

    function test_createAuction_revertsOnInvalidDeadlines() public {
        // bidDeadline in the past
        vm.expectRevert(PactAuction.InvalidDeadlines.selector);
        auction.createAuction(JOB_ID, uint64(block.timestamp - 1), uint64(block.timestamp + 1 hours), 0);

        // revealDeadline <= bidDeadline
        vm.expectRevert(PactAuction.InvalidDeadlines.selector);
        auction.createAuction(JOB_ID, uint64(block.timestamp + 1 hours), uint64(block.timestamp + 1 hours), 0);
    }

    function test_createAuction_incrementsId() public {
        uint256 id1 = _createDefaultAuction();
        uint256 id2 = _createDefaultAuction();
        assertEq(id1, 1);
        assertEq(id2, 2);
    }

    // ── Commit ──

    function test_commitBid_storesAndEmits() public {
        uint256 id = _createDefaultAuction();
        bytes32 seal = _sealBid(alice, 100, bytes32("salt1"));

        vm.prank(alice);
        vm.expectEmit(true, true, false, false);
        emit IPactAuction.BidCommitted(id, alice);
        auction.commitBid(id, seal);

        assertEq(auction.getCommit(id, alice), seal);
        assertEq(auction.getBidderCount(id), 1);
    }

    function test_commitBid_revertsIfAlreadyCommitted() public {
        uint256 id = _createDefaultAuction();
        bytes32 seal = _sealBid(alice, 100, bytes32("salt1"));

        vm.startPrank(alice);
        auction.commitBid(id, seal);

        vm.expectRevert(PactAuction.AlreadyCommitted.selector);
        auction.commitBid(id, seal);
        vm.stopPrank();
    }

    function test_commitBid_revertsAfterBidDeadline() public {
        uint256 id = _createDefaultAuction();
        bytes32 seal = _sealBid(alice, 100, bytes32("salt1"));

        // Warp past bid deadline
        vm.warp(block.timestamp + 1 hours + 1);
        vm.prank(alice);
        vm.expectRevert(PactAuction.AuctionNotInBiddingPhase.selector);
        auction.commitBid(id, seal);
    }

    // ── Reveal ──

    function test_revealBid_success() public {
        uint256 id = _createDefaultAuction();
        uint256 bidAmount = 100;
        bytes32 salt = bytes32("salt1");
        bytes32 seal = _sealBid(alice, bidAmount, salt);

        vm.prank(alice);
        auction.commitBid(id, seal);

        // Warp to reveal phase
        vm.warp(block.timestamp + 1 hours + 1);

        vm.prank(alice);
        vm.expectEmit(true, true, false, true);
        emit IPactAuction.BidRevealed(id, alice, bidAmount);
        auction.revealBid(id, bidAmount, salt);

        assertEq(auction.getRevealedBid(id, alice), bidAmount);
    }

    function test_revealBid_revertsBeforeBidDeadline() public {
        uint256 id = _createDefaultAuction();
        bytes32 salt = bytes32("salt1");
        bytes32 seal = _sealBid(alice, 100, salt);

        vm.prank(alice);
        auction.commitBid(id, seal);

        // Still in bidding phase
        vm.prank(alice);
        vm.expectRevert(PactAuction.AuctionNotInRevealPhase.selector);
        auction.revealBid(id, 100, salt);
    }

    function test_revealBid_revertsAfterRevealDeadline() public {
        uint256 id = _createDefaultAuction();
        bytes32 salt = bytes32("salt1");
        bytes32 seal = _sealBid(alice, 100, salt);

        vm.prank(alice);
        auction.commitBid(id, seal);

        // Warp past reveal deadline
        vm.warp(block.timestamp + 2 hours + 1);

        vm.prank(alice);
        vm.expectRevert(PactAuction.AuctionNotInRevealPhase.selector);
        auction.revealBid(id, 100, salt);
    }

    function test_revealBid_revertsOnInvalidReveal() public {
        uint256 id = _createDefaultAuction();
        bytes32 salt = bytes32("salt1");
        bytes32 seal = _sealBid(alice, 100, salt);

        vm.prank(alice);
        auction.commitBid(id, seal);

        vm.warp(block.timestamp + 1 hours + 1);

        // Wrong amount
        vm.prank(alice);
        vm.expectRevert(PactAuction.InvalidReveal.selector);
        auction.revealBid(id, 200, salt);
    }

    function test_revealBid_revertsIfNotCommitted() public {
        uint256 id = _createDefaultAuction();

        vm.warp(block.timestamp + 1 hours + 1);

        vm.prank(alice);
        vm.expectRevert(PactAuction.NotCommitted.selector);
        auction.revealBid(id, 100, bytes32("salt1"));
    }

    function test_revealBid_revertsIfAlreadyRevealed() public {
        uint256 id = _createDefaultAuction();
        bytes32 salt = bytes32("salt1");
        bytes32 seal = _sealBid(alice, 100, salt);

        vm.prank(alice);
        auction.commitBid(id, seal);

        vm.warp(block.timestamp + 1 hours + 1);

        vm.prank(alice);
        auction.revealBid(id, 100, salt);

        vm.prank(alice);
        vm.expectRevert(PactAuction.AlreadyRevealed.selector);
        auction.revealBid(id, 100, salt);
    }

    // ── Resolution ──

    function test_resolveAuction_vickreyRule_twoRevealedBidders() public {
        uint256 id = _createDefaultAuction();

        // Alice bids 150, Bob bids 100
        bytes32 saltA = bytes32("saltA");
        bytes32 saltB = bytes32("saltB");

        vm.prank(alice);
        auction.commitBid(id, _sealBid(alice, 150, saltA));
        vm.prank(bob);
        auction.commitBid(id, _sealBid(bob, 100, saltB));

        // Reveal
        vm.warp(block.timestamp + 1 hours + 1);
        vm.prank(alice);
        auction.revealBid(id, 150, saltA);
        vm.prank(bob);
        auction.revealBid(id, 100, saltB);

        // Resolve
        vm.warp(block.timestamp + 1 hours); // past reveal deadline

        vm.expectEmit(true, true, false, true);
        emit IPactAuction.AuctionResolved(id, alice, 100); // pays second-highest
        auction.resolveAuction(id);

        IPactAuction.Auction memory a = auction.getAuction(id);
        assertEq(a.winner, alice);
        assertEq(a.winningPrice, 100); // Vickrey: pays bob's bid
        assertEq(uint8(a.status), uint8(IPactAuction.AuctionStatus.Resolved));
    }

    function test_resolveAuction_singleBidder_payOwnBid() public {
        uint256 id = _createDefaultAuction();

        bytes32 salt = bytes32("salt1");
        vm.prank(alice);
        auction.commitBid(id, _sealBid(alice, 200, salt));

        vm.warp(block.timestamp + 1 hours + 1);
        vm.prank(alice);
        auction.revealBid(id, 200, salt);

        vm.warp(block.timestamp + 1 hours);
        auction.resolveAuction(id);

        IPactAuction.Auction memory a = auction.getAuction(id);
        assertEq(a.winner, alice);
        assertEq(a.winningPrice, 200); // single bidder pays own bid
    }

    function test_resolveAuction_noBids_noWinner() public {
        uint256 id = _createDefaultAuction();

        vm.warp(block.timestamp + 2 hours + 1);
        auction.resolveAuction(id);

        IPactAuction.Auction memory a = auction.getAuction(id);
        assertEq(a.winner, address(0));
        assertEq(a.winningPrice, 0);
        assertEq(uint8(a.status), uint8(IPactAuction.AuctionStatus.Resolved));
    }

    function test_resolveAuction_threeBidders_picksCorrectWinnerAndPrice() public {
        uint256 id = _createDefaultAuction();

        bytes32 saltA = bytes32("sA");
        bytes32 saltB = bytes32("sB");
        bytes32 saltC = bytes32("sC");

        // Alice=300, Bob=500, Charlie=400
        vm.prank(alice);
        auction.commitBid(id, _sealBid(alice, 300, saltA));
        vm.prank(bob);
        auction.commitBid(id, _sealBid(bob, 500, saltB));
        vm.prank(charlie);
        auction.commitBid(id, _sealBid(charlie, 400, saltC));

        vm.warp(block.timestamp + 1 hours + 1);
        vm.prank(alice);
        auction.revealBid(id, 300, saltA);
        vm.prank(bob);
        auction.revealBid(id, 500, saltB);
        vm.prank(charlie);
        auction.revealBid(id, 400, saltC);

        vm.warp(block.timestamp + 1 hours);
        auction.resolveAuction(id);

        IPactAuction.Auction memory a = auction.getAuction(id);
        assertEq(a.winner, bob);       // highest bidder
        assertEq(a.winningPrice, 400); // pays charlie's bid (second-highest)
    }

    function test_resolveAuction_revertsBeforeRevealDeadline() public {
        uint256 id = _createDefaultAuction();

        vm.expectRevert(PactAuction.AuctionNotResolvable.selector);
        auction.resolveAuction(id);
    }

    function test_resolveAuction_revertsIfAlreadyResolved() public {
        uint256 id = _createDefaultAuction();
        vm.warp(block.timestamp + 2 hours + 1);
        auction.resolveAuction(id);

        vm.expectRevert(PactAuction.AuctionAlreadyResolved.selector);
        auction.resolveAuction(id);
    }

    // ── Cancel ──

    function test_cancelAuction_byOwner() public {
        uint256 id = _createDefaultAuction();

        vm.expectEmit(true, false, false, false);
        emit IPactAuction.AuctionCancelled(id);
        auction.cancelAuction(id); // called by deployer who is also auction creator

        IPactAuction.Auction memory a = auction.getAuction(id);
        assertEq(uint8(a.status), uint8(IPactAuction.AuctionStatus.Cancelled));
    }

    function test_cancelAuction_revertsIfNotOwner() public {
        uint256 id = _createDefaultAuction();

        vm.prank(alice);
        vm.expectRevert(PactAuction.NotAuctionOwner.selector);
        auction.cancelAuction(id);
    }

    function test_cancelAuction_revertsIfAlreadyResolved() public {
        uint256 id = _createDefaultAuction();
        vm.warp(block.timestamp + 2 hours + 1);
        auction.resolveAuction(id);

        vm.expectRevert(PactAuction.AuctionAlreadyResolved.selector);
        auction.cancelAuction(id);
    }

    // ── Commit-reveal with unrevealed bids ──

    function test_resolveAuction_ignoresUnrevealedBids() public {
        uint256 id = _createDefaultAuction();

        bytes32 saltA = bytes32("sA");
        bytes32 saltB = bytes32("sB");

        // Alice commits but won't reveal; Bob commits and reveals
        vm.prank(alice);
        auction.commitBid(id, _sealBid(alice, 999, saltA));
        vm.prank(bob);
        auction.commitBid(id, _sealBid(bob, 50, saltB));

        vm.warp(block.timestamp + 1 hours + 1);
        // Only bob reveals
        vm.prank(bob);
        auction.revealBid(id, 50, saltB);

        vm.warp(block.timestamp + 1 hours);
        auction.resolveAuction(id);

        IPactAuction.Auction memory a = auction.getAuction(id);
        assertEq(a.winner, bob);
        assertEq(a.winningPrice, 50); // single revealed bidder
    }

    // ── Four bidders, equal bids ──

    function test_resolveAuction_equalBids_firstRevealerWins() public {
        uint256 id = _createDefaultAuction();

        bytes32 saltA = bytes32("eA");
        bytes32 saltB = bytes32("eB");

        vm.prank(alice);
        auction.commitBid(id, _sealBid(alice, 100, saltA));
        vm.prank(bob);
        auction.commitBid(id, _sealBid(bob, 100, saltB));

        vm.warp(block.timestamp + 1 hours + 1);
        vm.prank(alice);
        auction.revealBid(id, 100, saltA);
        vm.prank(bob);
        auction.revealBid(id, 100, saltB);

        vm.warp(block.timestamp + 1 hours);
        auction.resolveAuction(id);

        IPactAuction.Auction memory a = auction.getAuction(id);
        // First revealer (alice) has the initial highest, neither beats it
        // so alice stays winner with price = 100 (equal second)
        assertEq(a.winner, alice);
        assertEq(a.winningPrice, 100);
    }
}
