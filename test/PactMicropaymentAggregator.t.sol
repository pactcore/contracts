// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {PactMicropaymentAggregator} from "../src/PactMicropaymentAggregator.sol";
import {IPactMicropaymentAggregator} from "../src/interfaces/IPactMicropaymentAggregator.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

contract PactMicropaymentAggregatorTest is Test {
    PactMicropaymentAggregator agg;
    MockUSDC usdc;

    uint256 payerKey = 0xA11CE;
    address payer;
    address payee1 = address(0xBEEF);
    address payee2 = address(0xCAFE);
    address payee3 = address(0xFACE);

    bytes32 private constant BATCH_ENTRY_TYPEHASH = keccak256("BatchEntry(address payee,uint256 amount)");
    bytes32 private constant BATCH_SETTLEMENT_TYPEHASH = keccak256(
        "BatchSettlement(address payer,BatchEntry[] entries,uint256 totalAmount,uint256 nonce,uint256 deadline)BatchEntry(address payee,uint256 amount)"
    );

    function setUp() public {
        payer = vm.addr(payerKey);

        usdc = new MockUSDC();
        agg = new PactMicropaymentAggregator(address(usdc));

        usdc.mint(payer, 1_000_000e6);
        vm.prank(payer);
        usdc.approve(address(agg), type(uint256).max);
    }

    // ─── Helpers ────────────────────────────────────────────────────────

    function _signBatch(IPactMicropaymentAggregator.BatchSettlement memory batch, uint256 privKey)
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest = agg.batchDigest(batch);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _openChannel(address counterparty, uint256 deposit) internal {
        vm.prank(payer);
        agg.openChannel(counterparty, deposit);
    }

    function _makeBatch(address _payee, uint256 amount, uint256 nonce, uint256 deadline)
        internal
        view
        returns (IPactMicropaymentAggregator.BatchSettlement memory)
    {
        IPactMicropaymentAggregator.BatchEntry[] memory entries = new IPactMicropaymentAggregator.BatchEntry[](1);
        entries[0] = IPactMicropaymentAggregator.BatchEntry({payee: _payee, amount: amount});
        return IPactMicropaymentAggregator.BatchSettlement({
            payer: payer, entries: entries, totalAmount: amount, nonce: nonce, deadline: deadline
        });
    }

    // ─── Open Channel ───────────────────────────────────────────────────

    function test_openChannel() public {
        _openChannel(payee1, 100e6);

        IPactMicropaymentAggregator.Channel memory ch = agg.getChannel(payer, payee1);
        assertEq(ch.deposit, 100e6);
        assertEq(ch.spent, 0);
        assertEq(ch.nonce, 0);
        assertTrue(ch.open);
        assertEq(usdc.balanceOf(address(agg)), 100e6);
    }

    function test_openChannel_emitsEvent() public {
        vm.expectEmit(true, true, false, true);
        emit IPactMicropaymentAggregator.ChannelOpened(payer, payee1, 100e6);
        _openChannel(payee1, 100e6);
    }

    function test_openChannel_revertZeroCounterparty() public {
        vm.prank(payer);
        vm.expectRevert(PactMicropaymentAggregator.ZeroAddress.selector);
        agg.openChannel(address(0), 100e6);
    }

    function test_openChannel_revertZeroDeposit() public {
        vm.prank(payer);
        vm.expectRevert(PactMicropaymentAggregator.InvalidAmount.selector);
        agg.openChannel(payee1, 0);
    }

    function test_openChannel_revertAlreadyOpen() public {
        _openChannel(payee1, 100e6);
        vm.prank(payer);
        vm.expectRevert(PactMicropaymentAggregator.ChannelAlreadyOpen.selector);
        agg.openChannel(payee1, 50e6);
    }

    // ─── Settle Batch ───────────────────────────────────────────────────

    function test_settleBatch_single() public {
        _openChannel(payee1, 100e6);

        IPactMicropaymentAggregator.BatchSettlement memory batch =
            _makeBatch(payee1, 10e6, 0, block.timestamp + 1 hours);
        bytes memory sig = _signBatch(batch, payerKey);

        agg.settleBatch(batch, sig);

        IPactMicropaymentAggregator.Channel memory ch = agg.getChannel(payer, payee1);
        assertEq(ch.spent, 10e6);
        assertEq(ch.nonce, 1);
        assertEq(usdc.balanceOf(payee1), 10e6);
    }

    function test_settleBatch_multi() public {
        _openChannel(payee1, 100e6);

        IPactMicropaymentAggregator.BatchEntry[] memory entries = new IPactMicropaymentAggregator.BatchEntry[](3);
        entries[0] = IPactMicropaymentAggregator.BatchEntry({payee: payee1, amount: 5e6});
        entries[1] = IPactMicropaymentAggregator.BatchEntry({payee: payee2, amount: 3e6});
        entries[2] = IPactMicropaymentAggregator.BatchEntry({payee: payee3, amount: 2e6});

        IPactMicropaymentAggregator.BatchSettlement memory batch = IPactMicropaymentAggregator.BatchSettlement({
            payer: payer, entries: entries, totalAmount: 10e6, nonce: 0, deadline: block.timestamp + 1 hours
        });

        bytes memory sig = _signBatch(batch, payerKey);
        agg.settleBatch(batch, sig);

        assertEq(usdc.balanceOf(payee1), 5e6);
        assertEq(usdc.balanceOf(payee2), 3e6);
        assertEq(usdc.balanceOf(payee3), 2e6);
    }

    function test_settleBatch_emitsEvent() public {
        _openChannel(payee1, 100e6);

        IPactMicropaymentAggregator.BatchSettlement memory batch =
            _makeBatch(payee1, 10e6, 0, block.timestamp + 1 hours);
        bytes memory sig = _signBatch(batch, payerKey);

        vm.expectEmit(true, true, false, true);
        emit IPactMicropaymentAggregator.BatchSettled(payer, 0, 10e6, 1);
        agg.settleBatch(batch, sig);
    }

    function test_settleBatch_revertExpiredDeadline() public {
        _openChannel(payee1, 100e6);

        IPactMicropaymentAggregator.BatchSettlement memory batch = _makeBatch(payee1, 10e6, 0, block.timestamp - 1);
        bytes memory sig = _signBatch(batch, payerKey);

        vm.expectRevert(PactMicropaymentAggregator.DeadlineExpired.selector);
        agg.settleBatch(batch, sig);
    }

    function test_settleBatch_revertInvalidSignature() public {
        _openChannel(payee1, 100e6);

        uint256 wrongKey = 0xBAD;

        IPactMicropaymentAggregator.BatchSettlement memory batch =
            _makeBatch(payee1, 10e6, 0, block.timestamp + 1 hours);
        bytes memory sig = _signBatch(batch, wrongKey);

        vm.expectRevert(PactMicropaymentAggregator.InvalidSignature.selector);
        agg.settleBatch(batch, sig);
    }

    function test_settleBatch_revertInsufficientDeposit() public {
        _openChannel(payee1, 10e6);

        IPactMicropaymentAggregator.BatchSettlement memory batch =
            _makeBatch(payee1, 20e6, 0, block.timestamp + 1 hours);
        bytes memory sig = _signBatch(batch, payerKey);

        vm.expectRevert(PactMicropaymentAggregator.InsufficientDeposit.selector);
        agg.settleBatch(batch, sig);
    }

    function test_settleBatch_revertNonceMismatch() public {
        _openChannel(payee1, 100e6);

        IPactMicropaymentAggregator.BatchSettlement memory batch =
            _makeBatch(payee1, 10e6, 1, block.timestamp + 1 hours); // nonce 1, but channel is at 0
        bytes memory sig = _signBatch(batch, payerKey);

        vm.expectRevert(PactMicropaymentAggregator.NonceMismatch.selector);
        agg.settleBatch(batch, sig);
    }

    function test_settleBatch_revertEmptyBatch() public {
        _openChannel(payee1, 100e6);

        IPactMicropaymentAggregator.BatchEntry[] memory entries = new IPactMicropaymentAggregator.BatchEntry[](0);
        IPactMicropaymentAggregator.BatchSettlement memory batch = IPactMicropaymentAggregator.BatchSettlement({
            payer: payer, entries: entries, totalAmount: 0, nonce: 0, deadline: block.timestamp + 1 hours
        });
        bytes memory sig = _signBatch(batch, payerKey);

        vm.expectRevert(PactMicropaymentAggregator.EmptyBatch.selector);
        agg.settleBatch(batch, sig);
    }

    function test_settleBatch_revertTotalMismatch() public {
        _openChannel(payee1, 100e6);

        IPactMicropaymentAggregator.BatchSettlement memory batch =
            _makeBatch(payee1, 10e6, 0, block.timestamp + 1 hours);
        batch.totalAmount = 999e6; // wrong total
        bytes memory sig = _signBatch(batch, payerKey);

        vm.expectRevert(PactMicropaymentAggregator.TotalMismatch.selector);
        agg.settleBatch(batch, sig);
    }

    function test_settleBatch_revertChannelNotOpen() public {
        // No channel opened
        IPactMicropaymentAggregator.BatchSettlement memory batch =
            _makeBatch(payee1, 10e6, 0, block.timestamp + 1 hours);
        bytes memory sig = _signBatch(batch, payerKey);

        vm.expectRevert(PactMicropaymentAggregator.ChannelNotOpen.selector);
        agg.settleBatch(batch, sig);
    }

    function test_settleBatch_revertZeroPayeeInBatch() public {
        _openChannel(payee1, 100e6);

        // First entry is payee1 (used for channel lookup), second is zero address
        IPactMicropaymentAggregator.BatchEntry[] memory entries = new IPactMicropaymentAggregator.BatchEntry[](2);
        entries[0] = IPactMicropaymentAggregator.BatchEntry({payee: payee1, amount: 5e6});
        entries[1] = IPactMicropaymentAggregator.BatchEntry({payee: address(0), amount: 5e6});

        IPactMicropaymentAggregator.BatchSettlement memory batch = IPactMicropaymentAggregator.BatchSettlement({
            payer: payer, entries: entries, totalAmount: 10e6, nonce: 0, deadline: block.timestamp + 1 hours
        });
        bytes memory sig = _signBatch(batch, payerKey);

        vm.expectRevert(PactMicropaymentAggregator.ZeroAddress.selector);
        agg.settleBatch(batch, sig);
    }

    function test_settleBatch_revertZeroAmountEntry() public {
        _openChannel(payee1, 100e6);

        IPactMicropaymentAggregator.BatchSettlement memory batch = _makeBatch(payee1, 0, 0, block.timestamp + 1 hours);
        // This has totalAmount=0 with one entry of amount=0
        // But EmptyBatch only checks entries.length; let's make it one entry with zero amount
        IPactMicropaymentAggregator.BatchEntry[] memory entries = new IPactMicropaymentAggregator.BatchEntry[](1);
        entries[0] = IPactMicropaymentAggregator.BatchEntry({payee: payee1, amount: 0});
        batch = IPactMicropaymentAggregator.BatchSettlement({
            payer: payer, entries: entries, totalAmount: 0, nonce: 0, deadline: block.timestamp + 1 hours
        });
        bytes memory sig = _signBatch(batch, payerKey);

        vm.expectRevert(PactMicropaymentAggregator.InvalidAmount.selector);
        agg.settleBatch(batch, sig);
    }

    // ─── Sequential batches ─────────────────────────────────────────────

    function test_settleBatch_sequential() public {
        _openChannel(payee1, 100e6);

        // Batch 0
        IPactMicropaymentAggregator.BatchSettlement memory batch0 =
            _makeBatch(payee1, 10e6, 0, block.timestamp + 1 hours);
        agg.settleBatch(batch0, _signBatch(batch0, payerKey));

        // Batch 1
        IPactMicropaymentAggregator.BatchSettlement memory batch1 =
            _makeBatch(payee1, 20e6, 1, block.timestamp + 1 hours);
        agg.settleBatch(batch1, _signBatch(batch1, payerKey));

        // Batch 2
        IPactMicropaymentAggregator.BatchSettlement memory batch2 =
            _makeBatch(payee1, 30e6, 2, block.timestamp + 1 hours);
        agg.settleBatch(batch2, _signBatch(batch2, payerKey));

        IPactMicropaymentAggregator.Channel memory ch = agg.getChannel(payer, payee1);
        assertEq(ch.spent, 60e6);
        assertEq(ch.nonce, 3);
        assertEq(usdc.balanceOf(payee1), 60e6);
    }

    function test_settleBatch_sequentialExhausts() public {
        _openChannel(payee1, 20e6);

        // Batch 0 — 15e6
        IPactMicropaymentAggregator.BatchSettlement memory batch0 =
            _makeBatch(payee1, 15e6, 0, block.timestamp + 1 hours);
        agg.settleBatch(batch0, _signBatch(batch0, payerKey));

        // Batch 1 — 10e6 → should fail (15+10 > 20)
        IPactMicropaymentAggregator.BatchSettlement memory batch1 =
            _makeBatch(payee1, 10e6, 1, block.timestamp + 1 hours);
        bytes memory sig1 = _signBatch(batch1, payerKey);
        vm.expectRevert(PactMicropaymentAggregator.InsufficientDeposit.selector);
        agg.settleBatch(batch1, sig1);
    }

    // ─── Close Channel ──────────────────────────────────────────────────

    function test_closeChannel_fullRefund() public {
        _openChannel(payee1, 100e6);

        uint256 balBefore = usdc.balanceOf(payer);
        vm.prank(payer);
        agg.closeChannel(payee1);

        assertEq(usdc.balanceOf(payer), balBefore + 100e6);
        IPactMicropaymentAggregator.Channel memory ch = agg.getChannel(payer, payee1);
        assertFalse(ch.open);
    }

    function test_closeChannel_partialRefund() public {
        _openChannel(payee1, 100e6);

        IPactMicropaymentAggregator.BatchSettlement memory batch =
            _makeBatch(payee1, 40e6, 0, block.timestamp + 1 hours);
        agg.settleBatch(batch, _signBatch(batch, payerKey));

        uint256 balBefore = usdc.balanceOf(payer);
        vm.prank(payer);
        agg.closeChannel(payee1);

        assertEq(usdc.balanceOf(payer), balBefore + 60e6); // 100 - 40 = 60 refund
    }

    function test_closeChannel_emitsEvent() public {
        _openChannel(payee1, 100e6);

        vm.expectEmit(true, true, false, true);
        emit IPactMicropaymentAggregator.ChannelClosed(payer, payee1, 100e6);
        vm.prank(payer);
        agg.closeChannel(payee1);
    }

    function test_closeChannel_revertNotOpen() public {
        vm.prank(payer);
        vm.expectRevert(PactMicropaymentAggregator.ChannelNotOpen.selector);
        agg.closeChannel(payee1);
    }

    function test_closeChannel_revertDoubleClose() public {
        _openChannel(payee1, 100e6);
        vm.prank(payer);
        agg.closeChannel(payee1);

        vm.prank(payer);
        vm.expectRevert(PactMicropaymentAggregator.ChannelNotOpen.selector);
        agg.closeChannel(payee1);
    }

    function test_closeChannel_zeroRefundWhenFullySpent() public {
        _openChannel(payee1, 50e6);

        IPactMicropaymentAggregator.BatchSettlement memory batch =
            _makeBatch(payee1, 50e6, 0, block.timestamp + 1 hours);
        agg.settleBatch(batch, _signBatch(batch, payerKey));

        uint256 balBefore = usdc.balanceOf(payer);
        vm.prank(payer);
        agg.closeChannel(payee1);

        assertEq(usdc.balanceOf(payer), balBefore); // no refund
    }

    // ─── Reopen after close ─────────────────────────────────────────────

    function test_reopenAfterClose() public {
        _openChannel(payee1, 50e6);
        vm.prank(payer);
        agg.closeChannel(payee1);

        // Reopen
        _openChannel(payee1, 200e6);
        IPactMicropaymentAggregator.Channel memory ch = agg.getChannel(payer, payee1);
        assertEq(ch.deposit, 200e6);
        assertEq(ch.nonce, 0); // reset
        assertTrue(ch.open);
    }

    // ─── View helpers ───────────────────────────────────────────────────

    function test_domainSeparator() public view {
        bytes32 ds = agg.domainSeparator();
        assertTrue(ds != bytes32(0));
    }

    // ─── Constructor ────────────────────────────────────────────────────

    function test_constructor_revertZeroUsdc() public {
        vm.expectRevert(PactMicropaymentAggregator.ZeroAddress.selector);
        new PactMicropaymentAggregator(address(0));
    }
}
