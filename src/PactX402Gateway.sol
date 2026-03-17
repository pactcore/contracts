// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {EIP712} from "openzeppelin-contracts/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";

/// @title PactX402Gateway
/// @notice Gasless meta-transaction relay for USDC payments (§5.2).
///         Users sign an EIP-712 payment intent; any relayer submits it on-chain.
///         The relayer deducts a fee from the payment amount and forwards the net to the recipient.
contract PactX402Gateway is EIP712, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 private constant PAYMENT_TYPEHASH =
        keccak256("Payment(address from,address to,uint256 amount,uint256 relayerFee,uint256 nonce,uint256 deadline)");

    IERC20 public immutable usdc;

    /// @notice Per-address sequential nonce — incremented after every successful relay.
    mapping(address payer => uint256) public nonces;

    event PaymentRelayed(
        address indexed from, address indexed to, uint256 netAmount, uint256 relayerFee, address indexed relayer
    );

    error ZeroAddress();
    error InvalidAmount();
    error InvalidSignature();
    error DeadlineExpired();
    error RelayerFeeTooHigh();

    constructor(address usdcAddress) EIP712("PactX402Gateway", "1") {
        if (usdcAddress == address(0)) revert ZeroAddress();
        usdc = IERC20(usdcAddress);
    }

    /// @notice Relay a signed USDC payment.
    /// @param from     Payer who signed the payment intent.
    /// @param to       Recipient of the net payment.
    /// @param amount   Gross amount of USDC (including relayerFee).
    /// @param relayerFee Fee taken by the relayer (must be < amount).
    /// @param deadline Unix timestamp after which the signature is invalid.
    /// @param signature EIP-712 signature from `from`.
    function relay(
        address from,
        address to,
        uint256 amount,
        uint256 relayerFee,
        uint256 deadline,
        bytes calldata signature
    ) external nonReentrant {
        // Checks
        if (from == address(0) || to == address(0)) revert ZeroAddress();
        if (amount == 0) revert InvalidAmount();
        if (relayerFee >= amount) revert RelayerFeeTooHigh();
        if (block.timestamp > deadline) revert DeadlineExpired();

        uint256 nonce = nonces[from];
        bytes32 structHash = keccak256(abi.encode(PAYMENT_TYPEHASH, from, to, amount, relayerFee, nonce, deadline));
        bytes32 digest = _hashTypedDataV4(structHash);
        address signer = ECDSA.recover(digest, signature);
        if (signer != from) revert InvalidSignature();

        // Effects
        nonces[from] = nonce + 1;

        // Interactions
        uint256 netAmount = amount - relayerFee;
        usdc.safeTransferFrom(from, to, netAmount);
        if (relayerFee > 0) {
            usdc.safeTransferFrom(from, msg.sender, relayerFee);
        }

        emit PaymentRelayed(from, to, netAmount, relayerFee, msg.sender);
    }

    /// @notice Returns the EIP-712 domain separator for off-chain signing.
    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /// @notice Helper: compute the EIP-712 digest for a payment intent.
    ///         Sign this hash off-chain and pass the signature to `relay`.
    function paymentDigest(
        address from,
        address to,
        uint256 amount,
        uint256 relayerFee,
        uint256 nonce,
        uint256 deadline
    ) external view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(PAYMENT_TYPEHASH, from, to, amount, relayerFee, nonce, deadline));
        return _hashTypedDataV4(structHash);
    }
}
