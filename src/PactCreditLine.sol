// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "openzeppelin-contracts/contracts/access/AccessControl.sol";

/// @title PactCreditLine — On-chain credit line management for PactPay
/// @notice Allows issuers to extend credit to borrowers with limits, interest, and expiry
contract PactCreditLine is AccessControl {
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    struct CreditLine {
        address issuer;
        address borrower;
        uint256 limitCents;
        uint256 usedCents;
        uint16 interestBps;
        uint64 createdAt;
        uint64 expiresAt;
        bool active;
    }

    uint256 private nextLineId = 1;
    mapping(uint256 lineId => CreditLine) private lines;
    mapping(address borrower => uint256[]) private borrowerLines;

    event LineOpened(
        uint256 indexed lineId,
        address indexed issuer,
        address indexed borrower,
        uint256 limitCents,
        uint16 interestBps,
        uint64 expiresAt
    );
    event LineUsed(uint256 indexed lineId, uint256 amountCents, uint256 newUsedCents);
    event LineRepaid(uint256 indexed lineId, uint256 amountCents, uint256 newUsedCents);
    event LineClosed(uint256 indexed lineId);

    error LineNotFound();
    error LineNotActive();
    error LineExpired();
    error LimitExceeded();
    error InvalidAmount();
    error InvalidParams();

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);
    }

    /// @notice Open a new credit line from issuer to borrower
    function openLine(
        address issuer,
        address borrower,
        uint256 limitCents,
        uint16 interestBps,
        uint64 expiresAt
    ) external onlyRole(DEFAULT_ADMIN_ROLE) returns (uint256 lineId) {
        if (issuer == address(0) || borrower == address(0)) revert InvalidParams();
        if (limitCents == 0) revert InvalidParams();

        lineId = nextLineId;
        nextLineId++;

        lines[lineId] = CreditLine({
            issuer: issuer,
            borrower: borrower,
            limitCents: limitCents,
            usedCents: 0,
            interestBps: interestBps,
            createdAt: uint64(block.timestamp),
            expiresAt: expiresAt,
            active: true
        });

        borrowerLines[borrower].push(lineId);

        emit LineOpened(lineId, issuer, borrower, limitCents, interestBps, expiresAt);
    }

    /// @notice Use credit from an active, non-expired line
    function useLine(uint256 lineId, uint256 amountCents) external onlyRole(OPERATOR_ROLE) {
        CreditLine storage line = _getActiveLine(lineId);
        if (amountCents == 0) revert InvalidAmount();
        if (line.expiresAt != 0 && block.timestamp > line.expiresAt) revert LineExpired();

        uint256 newUsed = line.usedCents + amountCents;
        if (newUsed > line.limitCents) revert LimitExceeded();

        line.usedCents = newUsed;
        emit LineUsed(lineId, amountCents, newUsed);
    }

    /// @notice Repay credit on a line
    function repayLine(uint256 lineId, uint256 amountCents) external onlyRole(OPERATOR_ROLE) {
        CreditLine storage line = lines[lineId];
        if (line.issuer == address(0)) revert LineNotFound();
        if (amountCents == 0) revert InvalidAmount();

        if (amountCents >= line.usedCents) {
            line.usedCents = 0;
        } else {
            line.usedCents -= amountCents;
        }

        emit LineRepaid(lineId, amountCents, line.usedCents);
    }

    /// @notice Close a credit line (admin only)
    function closeLine(uint256 lineId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        CreditLine storage line = lines[lineId];
        if (line.issuer == address(0)) revert LineNotFound();
        if (!line.active) revert LineNotActive();

        line.active = false;
        emit LineClosed(lineId);
    }

    /// @notice Get credit line details
    function getLine(uint256 lineId) external view returns (CreditLine memory) {
        CreditLine storage line = lines[lineId];
        if (line.issuer == address(0)) revert LineNotFound();
        return line;
    }

    /// @notice Get all line IDs for a borrower
    function getLinesByBorrower(address borrower) external view returns (uint256[] memory) {
        return borrowerLines[borrower];
    }

    function _getActiveLine(uint256 lineId) internal view returns (CreditLine storage) {
        CreditLine storage line = lines[lineId];
        if (line.issuer == address(0)) revert LineNotFound();
        if (!line.active) revert LineNotActive();
        return line;
    }
}
