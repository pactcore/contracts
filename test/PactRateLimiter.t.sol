// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PactRateLimiter} from "../src/PactRateLimiter.sol";

contract PactRateLimiterTest is Test {
    PactRateLimiter public limiter;
    address public owner = address(this);
    address public caller = address(0xBEEF);
    address public alice = address(0x1);
    address public bob = address(0x2);
    address public unauthorized = address(0xDEAD);

    function setUp() public {
        limiter = new PactRateLimiter();
        limiter.setAuthorizedCaller(caller, true);
    }

    // ── Constructor / Config ──────────────────────────────────────────

    function test_constructor_defaults() public view {
        (
            uint256 maxTokens,
            uint256 refillRate,
            uint256 windowSeconds,
            uint256 violationThreshold,
            uint256 baseStakeEscalation,
            uint256 cooldownSeconds
        ) = limiter.config();

        assertEq(maxTokens, 100);
        assertEq(refillRate, 1);
        assertEq(windowSeconds, 3600);
        assertEq(violationThreshold, 5);
        assertEq(baseStakeEscalation, 500);
        assertEq(cooldownSeconds, 300);
    }

    function test_updateConfig() public {
        limiter.updateConfig(200, 2, 7200, 10, 1000, 600);
        (uint256 maxTokens, uint256 refillRate,,,,) = limiter.config();
        assertEq(maxTokens, 200);
        assertEq(refillRate, 2);
    }

    function test_updateConfig_revert_invalidZero() public {
        vm.expectRevert(PactRateLimiter.InvalidConfig.selector);
        limiter.updateConfig(0, 1, 3600, 5, 500, 300);
    }

    function test_updateConfig_revert_nonOwner() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        limiter.updateConfig(100, 1, 3600, 5, 500, 300);
    }

    // ── Authorization ─────────────────────────────────────────────────

    function test_setAuthorizedCaller() public {
        limiter.setAuthorizedCaller(alice, true);
        assertTrue(limiter.authorizedCallers(alice));
    }

    function test_setAuthorizedCaller_revert_zeroAddress() public {
        vm.expectRevert(PactRateLimiter.ZeroAddress.selector);
        limiter.setAuthorizedCaller(address(0), true);
    }

    // ── Token Consumption ─────────────────────────────────────────────

    function test_consumeToken_allowed() public {
        vm.prank(caller);
        bool allowed = limiter.consumeToken(alice);
        assertTrue(allowed);
    }

    function test_consumeToken_decrementsTokens() public {
        vm.prank(caller);
        limiter.consumeToken(alice);
        uint256 available = limiter.availableTokens(alice);
        assertEq(available, 99);
    }

    function test_consumeToken_exhaustBucket() public {
        // Consume all 100 tokens
        for (uint256 i = 0; i < 100; i++) {
            vm.prank(caller);
            assertTrue(limiter.consumeToken(alice));
        }
        // 101st should fail
        vm.prank(caller);
        assertFalse(limiter.consumeToken(alice));
    }

    function test_consumeToken_revert_zeroAddress() public {
        vm.prank(caller);
        vm.expectRevert(PactRateLimiter.ZeroAddress.selector);
        limiter.consumeToken(address(0));
    }

    function test_consumeToken_revert_unauthorized() public {
        vm.prank(unauthorized);
        vm.expectRevert(PactRateLimiter.UnauthorizedCaller.selector);
        limiter.consumeToken(alice);
    }

    // ── Refill ────────────────────────────────────────────────────────

    function test_refill_after_time() public {
        // Exhaust all tokens
        for (uint256 i = 0; i < 100; i++) {
            vm.prank(caller);
            limiter.consumeToken(alice);
        }

        // Wait past cooldown (300s) + some refill time
        vm.warp(block.timestamp + 400);

        vm.prank(caller);
        bool allowed = limiter.consumeToken(alice);
        assertTrue(allowed);
    }

    function test_availableTokens_uninitialized() public view {
        uint256 available = limiter.availableTokens(alice);
        assertEq(available, 100); // config.maxTokens
    }

    function test_availableTokens_partial_refill() public {
        vm.prank(caller);
        limiter.consumeToken(alice); // 99 tokens left

        // Advance 10 seconds → 10 tokens refilled → min(109, 100) = 100
        vm.warp(block.timestamp + 10);
        uint256 available = limiter.availableTokens(alice);
        assertEq(available, 100);
    }

    // ── Cooldown ──────────────────────────────────────────────────────

    function test_cooldown_applied_on_exhaust() public {
        for (uint256 i = 0; i < 100; i++) {
            vm.prank(caller);
            limiter.consumeToken(alice);
        }
        // 101st triggers cooldown
        vm.prank(caller);
        limiter.consumeToken(alice);

        assertTrue(limiter.isInCooldown(alice));
    }

    function test_cooldown_denies_during() public {
        for (uint256 i = 0; i < 100; i++) {
            vm.prank(caller);
            limiter.consumeToken(alice);
        }
        vm.prank(caller);
        limiter.consumeToken(alice); // triggers cooldown

        // Still in cooldown
        vm.warp(block.timestamp + 100);
        vm.prank(caller);
        assertFalse(limiter.consumeToken(alice));
    }

    function test_cooldown_expires() public {
        for (uint256 i = 0; i < 100; i++) {
            vm.prank(caller);
            limiter.consumeToken(alice);
        }
        vm.prank(caller);
        limiter.consumeToken(alice); // triggers cooldown

        // Past cooldown (300s) and refill
        vm.warp(block.timestamp + 400);
        assertFalse(limiter.isInCooldown(alice));
    }

    // ── Violations & Escalation ───────────────────────────────────────

    function test_violations_tracked() public {
        // Use a small bucket so exhaustion is fast
        limiter.updateConfig(3, 1, 3600, 5, 500, 300);

        // Exhaust 3 tokens
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(caller);
            limiter.consumeToken(alice);
        }
        // Next call fails → violation recorded (no time warp so no refill)
        vm.prank(caller);
        limiter.consumeToken(alice);
        assertGt(limiter.totalViolations(), 0);
    }

    function test_escalation_increases_cooldown() public {
        // Fast config for testing
        limiter.updateConfig(5, 1, 3600, 2, 500, 10);

        // Exhaust 5 tokens
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(caller);
            limiter.consumeToken(alice);
        }

        // 2 violations → escalation
        vm.prank(caller);
        limiter.consumeToken(alice); // violation 1 + cooldown set
        vm.prank(caller);
        limiter.consumeToken(alice); // violation 2 → escalation

        (,,, uint32 escalationLevel,,) = limiter.getBucket(alice);
        assertEq(escalationLevel, 1);
    }

    function test_stakeEscalation_increases() public {
        limiter.updateConfig(2, 1, 3600, 1, 500, 10);

        // Exhaust and trigger
        vm.prank(caller);
        limiter.consumeToken(alice);
        vm.prank(caller);
        limiter.consumeToken(alice);
        vm.prank(caller);
        limiter.consumeToken(alice); // violation + escalation

        uint256 requiredStake = limiter.getRequiredStakeEscalation(alice);
        assertGt(requiredStake, 0);
    }

    // ── Reset ─────────────────────────────────────────────────────────

    function test_resetBucket() public {
        vm.prank(caller);
        limiter.consumeToken(alice);

        limiter.resetBucket(alice);
        (,,,,, bool exists) = limiter.getBucket(alice);
        assertFalse(exists);
    }

    function test_resetBucket_revert_zeroAddress() public {
        vm.expectRevert(PactRateLimiter.ZeroAddress.selector);
        limiter.resetBucket(address(0));
    }

    function test_resetBucket_revert_nonOwner() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        limiter.resetBucket(alice);
    }

    // ── Independent Accounts ──────────────────────────────────────────

    function test_independentBuckets() public {
        vm.prank(caller);
        limiter.consumeToken(alice);

        // Bob's bucket is independent
        uint256 bobTokens = limiter.availableTokens(bob);
        assertEq(bobTokens, 100);
    }

    // ── Counters ──────────────────────────────────────────────────────

    function test_totalRequests_tracked() public {
        vm.prank(caller);
        limiter.consumeToken(alice);
        vm.prank(caller);
        limiter.consumeToken(bob);

        assertEq(limiter.totalRequests(), 2);
    }

    // ── Owner direct calls ────────────────────────────────────────────

    function test_ownerCanConsumeToken() public {
        bool allowed = limiter.consumeToken(alice);
        assertTrue(allowed);
    }
}
