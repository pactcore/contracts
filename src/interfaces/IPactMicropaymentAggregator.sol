// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IPactMicropaymentAggregator
/// @notice Interface for the PACT micropayment aggregation channel (§5.2).
interface IPactMicropaymentAggregator {
    struct BatchEntry {
        address payee;
        uint256 amount;
    }

    struct BatchSettlement {
        address payer;
        BatchEntry[] entries;
        uint256 totalAmount;
        uint256 nonce;
        uint256 deadline;
    }

    struct Channel {
        uint256 deposit;
        uint256 spent;
        uint256 nonce;
        bool open;
    }

    event ChannelOpened(address indexed payer, address indexed counterparty, uint256 deposit);
    event BatchSettled(address indexed payer, uint256 indexed nonce, uint256 totalAmount, uint256 entryCount);
    event ChannelClosed(address indexed payer, address indexed counterparty, uint256 refund);

    function openChannel(address counterparty, uint256 deposit) external;
    function settleBatch(BatchSettlement calldata batch, bytes calldata signature) external;
    function closeChannel(address counterparty) external;
    function getChannel(address payer, address counterparty) external view returns (Channel memory);
}
