// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {EIP712} from "openzeppelin-contracts/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";
import {IPactMicropaymentAggregator} from "./interfaces/IPactMicropaymentAggregator.sol";

/// @title PactMicropaymentAggregator
/// @notice On-chain micropayment aggregation via payment channels (whitepaper §5.2).
///         Users deposit USDC into a channel. Multiple micro-transfers accumulate
///         off-chain via signed state updates. Only final batch settlement hits on-chain,
///         dramatically reducing gas costs for high-frequency low-value payments.
contract PactMicropaymentAggregator is IPactMicropaymentAggregator, EIP712, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─── EIP-712 type hashes ────────────────────────────────────────────

    bytes32 private constant BATCH_ENTRY_TYPEHASH = keccak256("BatchEntry(address payee,uint256 amount)");

    bytes32 private constant BATCH_SETTLEMENT_TYPEHASH = keccak256(
        "BatchSettlement(address payer,BatchEntry[] entries,uint256 totalAmount,uint256 nonce,uint256 deadline)BatchEntry(address payee,uint256 amount)"
    );

    // ─── State ──────────────────────────────────────────────────────────

    IERC20 public immutable usdc;

    /// @dev payer → counterparty → Channel
    mapping(address => mapping(address => Channel)) private channels;

    // ─── Errors ─────────────────────────────────────────────────────────

    error ZeroAddress();
    error InvalidAmount();
    error ChannelAlreadyOpen();
    error ChannelNotOpen();
    error InsufficientDeposit();
    error InvalidSignature();
    error DeadlineExpired();
    error NonceMismatch();
    error TotalMismatch();
    error EmptyBatch();
    error NotChannelParty();

    // ─── Constructor ────────────────────────────────────────────────────

    constructor(address usdcAddress) EIP712("PactMicropaymentAggregator", "1") {
        if (usdcAddress == address(0)) revert ZeroAddress();
        usdc = IERC20(usdcAddress);
    }

    // ─── Channel management ─────────────────────────────────────────────

    /// @inheritdoc IPactMicropaymentAggregator
    function openChannel(address counterparty, uint256 deposit) external nonReentrant {
        if (counterparty == address(0)) revert ZeroAddress();
        if (deposit == 0) revert InvalidAmount();

        Channel storage ch = channels[msg.sender][counterparty];
        if (ch.open) revert ChannelAlreadyOpen();

        ch.deposit = deposit;
        ch.spent = 0;
        ch.nonce = 0;
        ch.open = true;

        usdc.safeTransferFrom(msg.sender, address(this), deposit);

        emit ChannelOpened(msg.sender, counterparty, deposit);
    }

    /// @inheritdoc IPactMicropaymentAggregator
    function settleBatch(BatchSettlement calldata batch, bytes calldata signature) external nonReentrant {
        // --- Checks ---
        if (batch.entries.length == 0) revert EmptyBatch();
        if (block.timestamp > batch.deadline) revert DeadlineExpired();

        // We need at least one payee to identify the counterparty for nonce tracking.
        // For simplicity the channel key is payer→first-payee; multi-payee batches are
        // allowed as long as the channel has enough deposit.
        address counterparty = batch.entries[0].payee;
        Channel storage ch = channels[batch.payer][counterparty];
        if (!ch.open) revert ChannelNotOpen();
        if (batch.nonce != ch.nonce) revert NonceMismatch();

        // Verify declared total matches entries
        uint256 computedTotal;
        for (uint256 i; i < batch.entries.length; i++) {
            computedTotal += batch.entries[i].amount;
        }
        if (computedTotal != batch.totalAmount) revert TotalMismatch();

        // Check deposit covers it
        if (ch.spent + batch.totalAmount > ch.deposit) revert InsufficientDeposit();

        // Verify EIP-712 signature from payer
        bytes32 digest = _batchDigest(batch);
        address signer = ECDSA.recover(digest, signature);
        if (signer != batch.payer) revert InvalidSignature();

        // --- Effects ---
        ch.spent += batch.totalAmount;
        ch.nonce += 1;

        // --- Interactions ---
        for (uint256 i; i < batch.entries.length; i++) {
            if (batch.entries[i].payee == address(0)) revert ZeroAddress();
            if (batch.entries[i].amount == 0) revert InvalidAmount();
            usdc.safeTransfer(batch.entries[i].payee, batch.entries[i].amount);
        }

        emit BatchSettled(batch.payer, batch.nonce, batch.totalAmount, batch.entries.length);
    }

    /// @inheritdoc IPactMicropaymentAggregator
    function closeChannel(address counterparty) external nonReentrant {
        Channel storage ch = channels[msg.sender][counterparty];
        if (!ch.open) revert ChannelNotOpen();

        ch.open = false;

        uint256 refund = ch.deposit - ch.spent;
        if (refund > 0) {
            usdc.safeTransfer(msg.sender, refund);
        }

        emit ChannelClosed(msg.sender, counterparty, refund);
    }

    /// @inheritdoc IPactMicropaymentAggregator
    function getChannel(address payer, address counterparty) external view returns (Channel memory) {
        return channels[payer][counterparty];
    }

    // ─── EIP-712 helpers ────────────────────────────────────────────────

    /// @notice Returns the EIP-712 domain separator.
    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /// @notice Compute the EIP-712 digest for a batch settlement.
    ///         Sign this hash off-chain and pass the signature to `settleBatch`.
    function batchDigest(BatchSettlement calldata batch) external view returns (bytes32) {
        return _batchDigest(batch);
    }

    function _batchDigest(BatchSettlement calldata batch) internal view returns (bytes32) {
        bytes32[] memory entryHashes = new bytes32[](batch.entries.length);
        for (uint256 i; i < batch.entries.length; i++) {
            entryHashes[i] = keccak256(abi.encode(BATCH_ENTRY_TYPEHASH, batch.entries[i].payee, batch.entries[i].amount));
        }

        bytes32 structHash = keccak256(
            abi.encode(
                BATCH_SETTLEMENT_TYPEHASH,
                batch.payer,
                keccak256(abi.encodePacked(entryHashes)),
                batch.totalAmount,
                batch.nonce,
                batch.deadline
            )
        );

        return _hashTypedDataV4(structHash);
    }
}
