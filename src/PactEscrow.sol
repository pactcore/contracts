// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

contract PactEscrow is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint16 public constant WORKER_BPS = 8500;
    uint16 public constant VALIDATORS_BPS = 500;
    uint16 public constant TREASURY_BPS = 500;
    uint16 public constant ISSUER_BPS = 500;
    uint16 private constant BPS_DENOMINATOR = 10_000;

    IERC20 public immutable usdc;

    struct Escrow {
        address payer;
        uint256 amount;
        bool released;
        bool refunded;
    }

    struct Payouts {
        address worker;
        address validators;
        address treasury;
        address issuer;
    }

    mapping(uint256 taskId => Escrow) private escrows;

    event EscrowCreated(uint256 indexed taskId, address indexed payer, uint256 amount);
    event EscrowReleased(
        uint256 indexed taskId,
        uint256 workerAmount,
        uint256 validatorsAmount,
        uint256 treasuryAmount,
        uint256 issuerAmount
    );
    event EscrowRefunded(uint256 indexed taskId, address indexed payer, uint256 amount);

    error ZeroAddress();
    error InvalidAmount();
    error EscrowAlreadyExists();
    error EscrowNotFound();
    error EscrowAlreadyResolved();
    error UnauthorizedPayer();

    constructor(address usdcAddress) Ownable(msg.sender) {
        if (usdcAddress == address(0)) revert ZeroAddress();
        usdc = IERC20(usdcAddress);
    }

    function createEscrow(uint256 taskId, address payer, uint256 amount) external nonReentrant {
        if (payer == address(0)) revert ZeroAddress();
        if (msg.sender != payer) revert UnauthorizedPayer();
        if (amount == 0) revert InvalidAmount();

        Escrow storage escrow = escrows[taskId];
        if (escrow.amount != 0) revert EscrowAlreadyExists();

        escrow.payer = payer;
        escrow.amount = amount;

        usdc.safeTransferFrom(payer, address(this), amount);

        emit EscrowCreated(taskId, payer, amount);
    }

    function releaseEscrow(uint256 taskId, Payouts calldata payouts) external onlyOwner nonReentrant {
        Escrow storage escrow = escrows[taskId];
        if (escrow.amount == 0) revert EscrowNotFound();
        if (escrow.released || escrow.refunded) revert EscrowAlreadyResolved();
        if (
            payouts.worker == address(0) || payouts.validators == address(0) || payouts.treasury == address(0)
                || payouts.issuer == address(0)
        ) revert ZeroAddress();

        escrow.released = true;

        uint256 validatorsAmount = (escrow.amount * VALIDATORS_BPS) / BPS_DENOMINATOR;
        uint256 treasuryAmount = (escrow.amount * TREASURY_BPS) / BPS_DENOMINATOR;
        uint256 issuerAmount = (escrow.amount * ISSUER_BPS) / BPS_DENOMINATOR;
        uint256 workerAmount = escrow.amount - validatorsAmount - treasuryAmount - issuerAmount;

        usdc.safeTransfer(payouts.worker, workerAmount);
        usdc.safeTransfer(payouts.validators, validatorsAmount);
        usdc.safeTransfer(payouts.treasury, treasuryAmount);
        usdc.safeTransfer(payouts.issuer, issuerAmount);

        emit EscrowReleased(taskId, workerAmount, validatorsAmount, treasuryAmount, issuerAmount);
    }

    function refundEscrow(uint256 taskId) external onlyOwner nonReentrant {
        Escrow storage escrow = escrows[taskId];
        if (escrow.amount == 0) revert EscrowNotFound();
        if (escrow.released || escrow.refunded) revert EscrowAlreadyResolved();

        escrow.refunded = true;
        usdc.safeTransfer(escrow.payer, escrow.amount);

        emit EscrowRefunded(taskId, escrow.payer, escrow.amount);
    }

    function getEscrow(uint256 taskId) external view returns (Escrow memory) {
        return escrows[taskId];
    }
}
