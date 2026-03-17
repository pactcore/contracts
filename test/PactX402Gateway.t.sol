// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PactX402Gateway} from "../src/PactX402Gateway.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

contract PactX402GatewayTest is Test {
    MockUSDC private usdc;
    PactX402Gateway private gateway;

    address private relayer = makeAddr("relayer");
    address private recipient = makeAddr("recipient");

    // Signer is the meta-tx payer; we need their private key.
    uint256 private signerKey;
    address private signer;

    uint256 private constant INITIAL_BALANCE = 10_000e6;
    uint256 private constant AMOUNT = 1_000e6;
    uint256 private constant RELAYER_FEE = 10e6;

    function setUp() external {
        (signer, signerKey) = makeAddrAndKey("signer");

        usdc = new MockUSDC();
        gateway = new PactX402Gateway(address(usdc));

        usdc.mint(signer, INITIAL_BALANCE);
        vm.prank(signer);
        usdc.approve(address(gateway), type(uint256).max);
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    function _signPayment(address from, address to, uint256 amount, uint256 fee, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest = gateway.paymentDigest(from, to, amount, fee, nonce, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        return abi.encodePacked(r, s, v);
    }

    // ── Relay success ─────────────────────────────────────────────────────────

    function testRelayPaymentWithFee() external {
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signPayment(signer, recipient, AMOUNT, RELAYER_FEE, 0, deadline);

        vm.prank(relayer);
        gateway.relay(signer, recipient, AMOUNT, RELAYER_FEE, deadline, sig);

        uint256 netAmount = AMOUNT - RELAYER_FEE;
        assertEq(usdc.balanceOf(recipient), netAmount);
        assertEq(usdc.balanceOf(relayer), RELAYER_FEE);
        assertEq(usdc.balanceOf(signer), INITIAL_BALANCE - AMOUNT);
    }

    function testRelayPaymentZeroFee() external {
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signPayment(signer, recipient, AMOUNT, 0, 0, deadline);

        vm.prank(relayer);
        gateway.relay(signer, recipient, AMOUNT, 0, deadline, sig);

        assertEq(usdc.balanceOf(recipient), AMOUNT);
        assertEq(usdc.balanceOf(relayer), 0);
    }

    // ── Nonce management ─────────────────────────────────────────────────────

    function testNonceIncrementsAfterRelay() external {
        assertEq(gateway.nonces(signer), 0);

        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signPayment(signer, recipient, AMOUNT, RELAYER_FEE, 0, deadline);

        vm.prank(relayer);
        gateway.relay(signer, recipient, AMOUNT, RELAYER_FEE, deadline, sig);

        assertEq(gateway.nonces(signer), 1);
    }

    function testReplayRevertsInvalidSignature() external {
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signPayment(signer, recipient, AMOUNT, RELAYER_FEE, 0, deadline);

        vm.prank(relayer);
        gateway.relay(signer, recipient, AMOUNT, RELAYER_FEE, deadline, sig);

        // Replay: same sig but nonce is now 1 on-chain → digest mismatch → InvalidSignature
        vm.prank(relayer);
        vm.expectRevert(PactX402Gateway.InvalidSignature.selector);
        gateway.relay(signer, recipient, AMOUNT, RELAYER_FEE, deadline, sig);
    }

    function testSecondRelayWithCorrectNonce() external {
        uint256 deadline = block.timestamp + 1 hours;

        // First relay (nonce 0)
        bytes memory sig0 = _signPayment(signer, recipient, AMOUNT, RELAYER_FEE, 0, deadline);
        vm.prank(relayer);
        gateway.relay(signer, recipient, AMOUNT, RELAYER_FEE, deadline, sig0);

        // Second relay (nonce 1)
        usdc.mint(signer, AMOUNT); // top up
        bytes memory sig1 = _signPayment(signer, recipient, AMOUNT, RELAYER_FEE, 1, deadline);
        vm.prank(relayer);
        gateway.relay(signer, recipient, AMOUNT, RELAYER_FEE, deadline, sig1);

        assertEq(gateway.nonces(signer), 2);
    }

    // ── Guard reverts ─────────────────────────────────────────────────────────

    function testRelayExpiredDeadlineReverts() external {
        uint256 deadline = block.timestamp - 1;
        bytes memory sig = _signPayment(signer, recipient, AMOUNT, RELAYER_FEE, 0, deadline);

        vm.expectRevert(PactX402Gateway.DeadlineExpired.selector);
        gateway.relay(signer, recipient, AMOUNT, RELAYER_FEE, deadline, sig);
    }

    function testRelayRelayerFeeTooHighReverts() external {
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signPayment(signer, recipient, AMOUNT, AMOUNT, 0, deadline);

        vm.expectRevert(PactX402Gateway.RelayerFeeTooHigh.selector);
        gateway.relay(signer, recipient, AMOUNT, AMOUNT, deadline, sig);
    }

    function testRelayInvalidSignatureReverts() external {
        uint256 deadline = block.timestamp + 1 hours;
        // Sign with the wrong key
        (, uint256 wrongKey) = makeAddrAndKey("wrong");
        bytes32 digest = gateway.paymentDigest(signer, recipient, AMOUNT, RELAYER_FEE, 0, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongKey, digest);
        bytes memory badSig = abi.encodePacked(r, s, v);

        vm.expectRevert(PactX402Gateway.InvalidSignature.selector);
        gateway.relay(signer, recipient, AMOUNT, RELAYER_FEE, deadline, badSig);
    }

    function testRelayZeroAmountReverts() external {
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signPayment(signer, recipient, 0, 0, 0, deadline);

        vm.expectRevert(PactX402Gateway.InvalidAmount.selector);
        gateway.relay(signer, recipient, 0, 0, deadline, sig);
    }

    function testConstructorZeroAddressReverts() external {
        vm.expectRevert(PactX402Gateway.ZeroAddress.selector);
        new PactX402Gateway(address(0));
    }
}
