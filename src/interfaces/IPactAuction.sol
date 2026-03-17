// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IPactAuction — Vickrey (sealed-bid second-price) auction for task pricing (§8.3)
interface IPactAuction {
    enum AuctionStatus {
        Bidding, // accepting sealed bids
        Revealing, // bid window closed, reveal window open
        Resolved, // winner determined
        Cancelled // cancelled by owner
    }

    struct Auction {
        uint256 jobId;
        uint256 minimumReputation;
        uint64 bidDeadline;
        uint64 revealDeadline;
        AuctionStatus status;
        address winner;
        uint256 winningPrice; // second-highest bid (Vickrey rule)
    }

    event AuctionCreated(uint256 indexed auctionId, uint256 indexed jobId, uint64 bidDeadline, uint64 revealDeadline);
    event BidCommitted(uint256 indexed auctionId, address indexed bidder);
    event BidRevealed(uint256 indexed auctionId, address indexed bidder, uint256 bidAmount);
    event AuctionResolved(uint256 indexed auctionId, address indexed winner, uint256 winningPrice);
    event AuctionCancelled(uint256 indexed auctionId);

    function createAuction(uint256 jobId, uint64 bidDeadline, uint64 revealDeadline, uint256 minimumReputation)
        external
        returns (uint256 auctionId);

    function commitBid(uint256 auctionId, bytes32 sealedBid) external;

    function revealBid(uint256 auctionId, uint256 bidAmount, bytes32 salt) external;

    function resolveAuction(uint256 auctionId) external;

    function cancelAuction(uint256 auctionId) external;

    function getAuction(uint256 auctionId) external view returns (Auction memory);
    function getCommit(uint256 auctionId, address bidder) external view returns (bytes32);
    function getRevealedBid(uint256 auctionId, address bidder) external view returns (uint256);
    function getBidderCount(uint256 auctionId) external view returns (uint256);
}
