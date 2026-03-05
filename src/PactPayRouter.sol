// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

contract PactPayRouter is ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable usdc;
    uint256 private nextBatchId = 1;

    struct TransferRequest {
        address from;
        address to;
        uint256 amount;
        bytes32 ref;
    }

    struct LedgerEntry {
        address from;
        address to;
        uint256 amount;
        bytes32 ref;
        uint64 timestamp;
    }

    mapping(address participant => LedgerEntry[]) private ledgers;

    event PaymentRouted(address indexed from, address indexed to, uint256 amount, bytes32 indexed ref);
    event BatchPaymentRouted(uint256 indexed batchId, uint256 transferCount, uint256 totalAmount);

    error ZeroAddress();
    error InvalidAmount();
    error UnauthorizedSender();

    constructor(address usdcAddress) {
        if (usdcAddress == address(0)) revert ZeroAddress();
        usdc = IERC20(usdcAddress);
    }

    function transfer(address from, address to, uint256 amount, bytes32 ref) external nonReentrant {
        _routePayment(from, to, amount, ref);
    }

    function batchTransfer(TransferRequest[] calldata transfers) external nonReentrant {
        uint256 totalAmount;
        uint256 length = transfers.length;

        for (uint256 i = 0; i < length; i++) {
            TransferRequest calldata request = transfers[i];
            _routePayment(request.from, request.to, request.amount, request.ref);
            totalAmount += request.amount;
        }

        uint256 batchId = nextBatchId;
        nextBatchId++;
        emit BatchPaymentRouted(batchId, length, totalAmount);
    }

    function getLedger(address participant) external view returns (LedgerEntry[] memory) {
        return ledgers[participant];
    }

    function _routePayment(address from, address to, uint256 amount, bytes32 ref) internal {
        if (from == address(0) || to == address(0)) revert ZeroAddress();
        if (amount == 0) revert InvalidAmount();
        if (msg.sender != from) revert UnauthorizedSender();

        usdc.safeTransferFrom(from, to, amount);

        LedgerEntry memory entry =
            LedgerEntry({from: from, to: to, amount: amount, ref: ref, timestamp: uint64(block.timestamp)});

        ledgers[from].push(entry);
        if (to != from) ledgers[to].push(entry);

        emit PaymentRouted(from, to, amount, ref);
    }
}
