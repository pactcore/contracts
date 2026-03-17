// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PactCreditLine} from "../src/PactCreditLine.sol";

contract PactCreditLineTest is Test {
    PactCreditLine creditLine;
    address admin = address(this);
    address issuer = address(0xA1);
    address borrower = address(0xB1);
    address borrower2 = address(0xB2);
    address operator = address(0xC1);

    function setUp() public {
        creditLine = new PactCreditLine();
        creditLine.grantRole(creditLine.OPERATOR_ROLE(), operator);
    }

    function test_openLine() public {
        uint256 lineId = creditLine.openLine(issuer, borrower, 10_000, 500, 0);
        assertEq(lineId, 1);

        PactCreditLine.CreditLine memory line = creditLine.getLine(lineId);
        assertEq(line.issuer, issuer);
        assertEq(line.borrower, borrower);
        assertEq(line.limitCents, 10_000);
        assertEq(line.usedCents, 0);
        assertEq(line.interestBps, 500);
        assertTrue(line.active);
        assertEq(line.expiresAt, 0);
    }

    function test_openLine_withExpiry() public {
        uint64 expiry = uint64(block.timestamp + 30 days);
        uint256 lineId = creditLine.openLine(issuer, borrower, 5_000, 250, expiry);

        PactCreditLine.CreditLine memory line = creditLine.getLine(lineId);
        assertEq(line.expiresAt, expiry);
    }

    function test_openLine_revertsZeroIssuer() public {
        vm.expectRevert(PactCreditLine.InvalidParams.selector);
        creditLine.openLine(address(0), borrower, 10_000, 500, 0);
    }

    function test_openLine_revertsZeroBorrower() public {
        vm.expectRevert(PactCreditLine.InvalidParams.selector);
        creditLine.openLine(issuer, address(0), 10_000, 500, 0);
    }

    function test_openLine_revertsZeroLimit() public {
        vm.expectRevert(PactCreditLine.InvalidParams.selector);
        creditLine.openLine(issuer, borrower, 0, 500, 0);
    }

    function test_useLine() public {
        uint256 lineId = creditLine.openLine(issuer, borrower, 10_000, 500, 0);

        vm.prank(operator);
        creditLine.useLine(lineId, 3_000);

        PactCreditLine.CreditLine memory line = creditLine.getLine(lineId);
        assertEq(line.usedCents, 3_000);
    }

    function test_useLine_multipleUses() public {
        uint256 lineId = creditLine.openLine(issuer, borrower, 10_000, 500, 0);

        vm.startPrank(operator);
        creditLine.useLine(lineId, 3_000);
        creditLine.useLine(lineId, 4_000);
        vm.stopPrank();

        PactCreditLine.CreditLine memory line = creditLine.getLine(lineId);
        assertEq(line.usedCents, 7_000);
    }

    function test_useLine_revertsLimitExceeded() public {
        uint256 lineId = creditLine.openLine(issuer, borrower, 10_000, 500, 0);

        vm.prank(operator);
        vm.expectRevert(PactCreditLine.LimitExceeded.selector);
        creditLine.useLine(lineId, 10_001);
    }

    function test_useLine_revertsZeroAmount() public {
        uint256 lineId = creditLine.openLine(issuer, borrower, 10_000, 500, 0);

        vm.prank(operator);
        vm.expectRevert(PactCreditLine.InvalidAmount.selector);
        creditLine.useLine(lineId, 0);
    }

    function test_useLine_revertsExpired() public {
        uint64 expiry = uint64(block.timestamp + 1 hours);
        uint256 lineId = creditLine.openLine(issuer, borrower, 10_000, 500, expiry);

        vm.warp(block.timestamp + 2 hours);

        vm.prank(operator);
        vm.expectRevert(PactCreditLine.LineExpired.selector);
        creditLine.useLine(lineId, 1_000);
    }

    function test_useLine_revertsClosedLine() public {
        uint256 lineId = creditLine.openLine(issuer, borrower, 10_000, 500, 0);
        creditLine.closeLine(lineId);

        vm.prank(operator);
        vm.expectRevert(PactCreditLine.LineNotActive.selector);
        creditLine.useLine(lineId, 1_000);
    }

    function test_repayLine() public {
        uint256 lineId = creditLine.openLine(issuer, borrower, 10_000, 500, 0);

        vm.startPrank(operator);
        creditLine.useLine(lineId, 5_000);
        creditLine.repayLine(lineId, 2_000);
        vm.stopPrank();

        PactCreditLine.CreditLine memory line = creditLine.getLine(lineId);
        assertEq(line.usedCents, 3_000);
    }

    function test_repayLine_fullRepay() public {
        uint256 lineId = creditLine.openLine(issuer, borrower, 10_000, 500, 0);

        vm.startPrank(operator);
        creditLine.useLine(lineId, 5_000);
        creditLine.repayLine(lineId, 5_000);
        vm.stopPrank();

        PactCreditLine.CreditLine memory line = creditLine.getLine(lineId);
        assertEq(line.usedCents, 0);
    }

    function test_repayLine_overpayClamps() public {
        uint256 lineId = creditLine.openLine(issuer, borrower, 10_000, 500, 0);

        vm.startPrank(operator);
        creditLine.useLine(lineId, 3_000);
        creditLine.repayLine(lineId, 5_000);
        vm.stopPrank();

        PactCreditLine.CreditLine memory line = creditLine.getLine(lineId);
        assertEq(line.usedCents, 0);
    }

    function test_repayLine_revertsZeroAmount() public {
        uint256 lineId = creditLine.openLine(issuer, borrower, 10_000, 500, 0);

        vm.prank(operator);
        vm.expectRevert(PactCreditLine.InvalidAmount.selector);
        creditLine.repayLine(lineId, 0);
    }

    function test_closeLine() public {
        uint256 lineId = creditLine.openLine(issuer, borrower, 10_000, 500, 0);
        creditLine.closeLine(lineId);

        PactCreditLine.CreditLine memory line = creditLine.getLine(lineId);
        assertFalse(line.active);
    }

    function test_closeLine_revertsAlreadyClosed() public {
        uint256 lineId = creditLine.openLine(issuer, borrower, 10_000, 500, 0);
        creditLine.closeLine(lineId);

        vm.expectRevert(PactCreditLine.LineNotActive.selector);
        creditLine.closeLine(lineId);
    }

    function test_closeLine_revertsNotFound() public {
        vm.expectRevert(PactCreditLine.LineNotFound.selector);
        creditLine.closeLine(999);
    }

    function test_getLinesByBorrower() public {
        creditLine.openLine(issuer, borrower, 10_000, 500, 0);
        creditLine.openLine(issuer, borrower, 20_000, 300, 0);
        creditLine.openLine(issuer, borrower2, 5_000, 100, 0);

        uint256[] memory b1Lines = creditLine.getLinesByBorrower(borrower);
        assertEq(b1Lines.length, 2);
        assertEq(b1Lines[0], 1);
        assertEq(b1Lines[1], 2);

        uint256[] memory b2Lines = creditLine.getLinesByBorrower(borrower2);
        assertEq(b2Lines.length, 1);
        assertEq(b2Lines[0], 3);
    }

    function test_getLine_revertsNotFound() public {
        vm.expectRevert(PactCreditLine.LineNotFound.selector);
        creditLine.getLine(999);
    }

    function test_useLine_revertsNotFound() public {
        vm.prank(operator);
        vm.expectRevert(PactCreditLine.LineNotFound.selector);
        creditLine.useLine(999, 1_000);
    }

    function test_repayLine_revertsNotFound() public {
        vm.prank(operator);
        vm.expectRevert(PactCreditLine.LineNotFound.selector);
        creditLine.repayLine(999, 1_000);
    }

    function test_useLine_exactLimit() public {
        uint256 lineId = creditLine.openLine(issuer, borrower, 10_000, 500, 0);

        vm.prank(operator);
        creditLine.useLine(lineId, 10_000);

        PactCreditLine.CreditLine memory line = creditLine.getLine(lineId);
        assertEq(line.usedCents, 10_000);
    }

    function test_sequentialLineIds() public {
        uint256 id1 = creditLine.openLine(issuer, borrower, 1_000, 100, 0);
        uint256 id2 = creditLine.openLine(issuer, borrower, 2_000, 200, 0);
        uint256 id3 = creditLine.openLine(issuer, borrower2, 3_000, 300, 0);

        assertEq(id1, 1);
        assertEq(id2, 2);
        assertEq(id3, 3);
    }
}
