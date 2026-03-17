// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {IPactAuction} from "./interfaces/IPactAuction.sol";

/// @title PactAuction — Vickrey (sealed-bid second-price) auction for task pricing (§8.3)
/// @notice Implements commit-reveal Vickrey auctions where:
///   1. Bidders commit hashed bids during the bidding phase
///   2. Bidders reveal actual bids during the reveal phase
///   3. Winner pays the second-highest bid price (Vickrey rule)
///   4. Integrates with PactReputation for minimum reputation gating
contract PactAuction is IPactAuction, Ownable {
    /// @dev Reputation contract for gating (optional, address(0) = no gating)
    address public immutable reputationContract;

    uint256 private _nextAuctionId = 1;

    /// @dev Core auction data
    mapping(uint256 => Auction) private _auctions;
    /// @dev auctionId => jobId creator
    mapping(uint256 => address) private _auctionOwners;
    /// @dev auctionId => bidder => sealed commit hash
    mapping(uint256 => mapping(address => bytes32)) private _commits;
    /// @dev auctionId => bidder => revealed bid amount (0 = not revealed)
    mapping(uint256 => mapping(address => uint256)) private _revealedBids;
    /// @dev auctionId => bidder => whether they revealed
    mapping(uint256 => mapping(address => bool)) private _hasRevealed;
    /// @dev auctionId => list of bidders who committed
    mapping(uint256 => address[]) private _bidders;
    /// @dev auctionId => list of bidders who revealed
    mapping(uint256 => address[]) private _revealedBidders;

    error AuctionNotInBiddingPhase();
    error AuctionNotInRevealPhase();
    error AuctionNotResolvable();
    error AuctionAlreadyResolved();
    error InvalidDeadlines();
    error AlreadyCommitted();
    error NotCommitted();
    error AlreadyRevealed();
    error InvalidReveal();
    error NotAuctionOwner();
    error BelowMinimumReputation();

    constructor(address _reputationContract) Ownable(msg.sender) {
        reputationContract = _reputationContract;
    }

    /// @inheritdoc IPactAuction
    function createAuction(
        uint256 jobId,
        uint64 bidDeadline,
        uint64 revealDeadline,
        uint256 minimumReputation
    ) external returns (uint256 auctionId) {
        if (bidDeadline <= block.timestamp || revealDeadline <= bidDeadline) {
            revert InvalidDeadlines();
        }

        auctionId = _nextAuctionId++;
        _auctions[auctionId] = Auction({
            jobId: jobId,
            minimumReputation: minimumReputation,
            bidDeadline: bidDeadline,
            revealDeadline: revealDeadline,
            status: AuctionStatus.Bidding,
            winner: address(0),
            winningPrice: 0
        });
        _auctionOwners[auctionId] = msg.sender;

        emit AuctionCreated(auctionId, jobId, bidDeadline, revealDeadline);
    }

    /// @inheritdoc IPactAuction
    function commitBid(uint256 auctionId, bytes32 sealedBid) external {
        Auction storage auction = _auctions[auctionId];
        if (auction.status != AuctionStatus.Bidding || block.timestamp > auction.bidDeadline) {
            revert AuctionNotInBiddingPhase();
        }
        if (_commits[auctionId][msg.sender] != bytes32(0)) {
            revert AlreadyCommitted();
        }

        // Check reputation if configured
        if (auction.minimumReputation > 0 && reputationContract != address(0)) {
            _checkReputation(msg.sender, auction.minimumReputation);
        }

        _commits[auctionId][msg.sender] = sealedBid;
        _bidders[auctionId].push(msg.sender);

        emit BidCommitted(auctionId, msg.sender);
    }

    /// @inheritdoc IPactAuction
    function revealBid(uint256 auctionId, uint256 bidAmount, bytes32 salt) external {
        Auction storage auction = _auctions[auctionId];

        // Transition to Revealing if bid deadline passed
        if (auction.status == AuctionStatus.Bidding && block.timestamp > auction.bidDeadline) {
            auction.status = AuctionStatus.Revealing;
        }

        if (auction.status != AuctionStatus.Revealing || block.timestamp > auction.revealDeadline) {
            revert AuctionNotInRevealPhase();
        }

        bytes32 commit = _commits[auctionId][msg.sender];
        if (commit == bytes32(0)) {
            revert NotCommitted();
        }
        if (_hasRevealed[auctionId][msg.sender]) {
            revert AlreadyRevealed();
        }

        // Verify the revealed bid matches the commit
        bytes32 expected = keccak256(abi.encodePacked(msg.sender, bidAmount, salt));
        if (expected != commit) {
            revert InvalidReveal();
        }

        _revealedBids[auctionId][msg.sender] = bidAmount;
        _hasRevealed[auctionId][msg.sender] = true;
        _revealedBidders[auctionId].push(msg.sender);

        emit BidRevealed(auctionId, msg.sender, bidAmount);
    }

    /// @inheritdoc IPactAuction
    function resolveAuction(uint256 auctionId) external {
        Auction storage auction = _auctions[auctionId];

        // Transition to Revealing if needed
        if (auction.status == AuctionStatus.Bidding && block.timestamp > auction.bidDeadline) {
            auction.status = AuctionStatus.Revealing;
        }

        if (auction.status == AuctionStatus.Resolved || auction.status == AuctionStatus.Cancelled) {
            revert AuctionAlreadyResolved();
        }

        // Can only resolve after reveal deadline
        if (block.timestamp <= auction.revealDeadline) {
            revert AuctionNotResolvable();
        }

        address[] storage revealers = _revealedBidders[auctionId];
        uint256 len = revealers.length;

        if (len == 0) {
            // No valid bids — resolve with no winner
            auction.status = AuctionStatus.Resolved;
            emit AuctionResolved(auctionId, address(0), 0);
            return;
        }

        // Find highest and second-highest bid
        // In Vickrey: highest bid wins, pays second-highest price
        address highestBidder = revealers[0];
        uint256 highestBid = _revealedBids[auctionId][highestBidder];
        uint256 secondHighestBid = 0;

        for (uint256 i = 1; i < len; i++) {
            address bidder = revealers[i];
            uint256 bid = _revealedBids[auctionId][bidder];
            if (bid > highestBid) {
                secondHighestBid = highestBid;
                highestBidder = bidder;
                highestBid = bid;
            } else if (bid > secondHighestBid) {
                secondHighestBid = bid;
            }
        }

        // Vickrey rule: winner pays second-highest price
        // If only one bidder, they pay their own bid
        uint256 winningPrice = len == 1 ? highestBid : secondHighestBid;

        auction.winner = highestBidder;
        auction.winningPrice = winningPrice;
        auction.status = AuctionStatus.Resolved;

        emit AuctionResolved(auctionId, highestBidder, winningPrice);
    }

    /// @inheritdoc IPactAuction
    function cancelAuction(uint256 auctionId) external {
        if (_auctionOwners[auctionId] != msg.sender && msg.sender != owner()) {
            revert NotAuctionOwner();
        }
        Auction storage auction = _auctions[auctionId];
        if (auction.status == AuctionStatus.Resolved || auction.status == AuctionStatus.Cancelled) {
            revert AuctionAlreadyResolved();
        }

        auction.status = AuctionStatus.Cancelled;
        emit AuctionCancelled(auctionId);
    }

    /// @inheritdoc IPactAuction
    function getAuction(uint256 auctionId) external view returns (Auction memory) {
        return _auctions[auctionId];
    }

    /// @inheritdoc IPactAuction
    function getCommit(uint256 auctionId, address bidder) external view returns (bytes32) {
        return _commits[auctionId][bidder];
    }

    /// @inheritdoc IPactAuction
    function getRevealedBid(uint256 auctionId, address bidder) external view returns (uint256) {
        return _revealedBids[auctionId][bidder];
    }

    /// @inheritdoc IPactAuction
    function getBidderCount(uint256 auctionId) external view returns (uint256) {
        return _bidders[auctionId].length;
    }

    /// @notice Returns the next auction ID to be assigned.
    function getNextAuctionId() external view returns (uint256) {
        return _nextAuctionId;
    }

    /// @dev Check reputation via the PactReputation contract.
    ///      Uses a static call to getScore(Worker, bidder) and checks >= minimum.
    function _checkReputation(address bidder, uint256 minimumReputation) internal view {
        // PactReputation.getScore(Role role, address account) → uint8
        (bool success, bytes memory data) = reputationContract.staticcall(
            abi.encodeWithSignature("getScore(uint8,address)", 0, bidder) // 0 = Worker role
        );
        if (success && data.length >= 32) {
            uint8 score = abi.decode(data, (uint8));
            if (uint256(score) < minimumReputation) {
                revert BelowMinimumReputation();
            }
        }
        // If reputation call fails, skip gating (graceful degradation)
    }
}
