// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PactCompute} from "../src/PactCompute.sol";
import {IPactCompute} from "../src/interfaces/IPactCompute.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

contract PactComputeTest is Test {
    PactCompute public compute;
    MockUSDC public usdc;

    address owner = address(this);
    address treasury = makeAddr("treasury");
    address providerOwner = makeAddr("providerOwner");
    address requester = makeAddr("requester");
    address gateway = makeAddr("gateway");
    address nobody = makeAddr("nobody");

    uint256 constant INITIAL_BALANCE = 1_000_000e6; // 1M USDC

    function setUp() public {
        usdc = new MockUSDC();
        compute = new PactCompute(address(usdc), treasury);

        usdc.mint(requester, INITIAL_BALANCE);
        vm.prank(requester);
        usdc.approve(address(compute), type(uint256).max);
    }

    // ═══════════════════════════════════════════════════════════════
    //  Constructor
    // ═══════════════════════════════════════════════════════════════

    function test_constructor_sets_state() public view {
        assertEq(address(compute.usdc()), address(usdc));
        assertEq(compute.treasury(), treasury);
        assertEq(compute.getNextProviderId(), 1);
        assertEq(compute.getNextJobId(), 1);
    }

    function test_constructor_reverts_zero_usdc() public {
        vm.expectRevert(PactCompute.ZeroAddress.selector);
        new PactCompute(address(0), treasury);
    }

    function test_constructor_reverts_zero_treasury() public {
        vm.expectRevert(PactCompute.ZeroAddress.selector);
        new PactCompute(address(usdc), address(0));
    }

    // ═══════════════════════════════════════════════════════════════
    //  Admin
    // ═══════════════════════════════════════════════════════════════

    function test_setX402Gateway() public {
        compute.setX402Gateway(gateway);
        assertEq(compute.x402Gateway(), gateway);
    }

    function test_setX402Gateway_onlyOwner() public {
        vm.prank(nobody);
        vm.expectRevert();
        compute.setX402Gateway(gateway);
    }

    function test_setTreasury() public {
        address newTreasury = makeAddr("newTreasury");
        compute.setTreasury(newTreasury);
        assertEq(compute.treasury(), newTreasury);
    }

    function test_setTreasury_reverts_zero() public {
        vm.expectRevert(PactCompute.ZeroAddress.selector);
        compute.setTreasury(address(0));
    }

    // ═══════════════════════════════════════════════════════════════
    //  Provider Management
    // ═══════════════════════════════════════════════════════════════

    function test_registerProvider_serverless() public {
        vm.prank(providerOwner);
        uint256 id = compute.registerProvider(0, 0, 0, 1, IPactCompute.ResourceType.Serverless);

        assertEq(id, 1);
        IPactCompute.Provider memory p = compute.getProvider(id);
        assertEq(p.owner, providerOwner);
        assertEq(p.cpuCores, 0);
        assertEq(p.pricePerHourCents, 1);
        assertEq(uint8(p.resourceType), uint8(IPactCompute.ResourceType.Serverless));
        assertTrue(p.active);
    }

    function test_registerProvider_container() public {
        vm.prank(providerOwner);
        uint256 id = compute.registerProvider(2, 4096, 0, 4, IPactCompute.ResourceType.Container);

        IPactCompute.Provider memory p = compute.getProvider(id);
        assertEq(p.cpuCores, 2);
        assertEq(p.memoryMB, 4096);
        assertEq(uint8(p.resourceType), uint8(IPactCompute.ResourceType.Container));
    }

    function test_registerProvider_vm() public {
        vm.prank(providerOwner);
        uint256 id = compute.registerProvider(8, 32768, 0, 24, IPactCompute.ResourceType.VM);

        IPactCompute.Provider memory p = compute.getProvider(id);
        assertEq(uint8(p.resourceType), uint8(IPactCompute.ResourceType.VM));
    }

    function test_registerProvider_gpu() public {
        vm.prank(providerOwner);
        uint256 id = compute.registerProvider(16, 65536, 1, 180, IPactCompute.ResourceType.GPU);

        IPactCompute.Provider memory p = compute.getProvider(id);
        assertEq(p.gpuCount, 1);
        assertEq(uint8(p.resourceType), uint8(IPactCompute.ResourceType.GPU));
    }

    function test_registerProvider_reverts_zero_price() public {
        vm.prank(providerOwner);
        vm.expectRevert(PactCompute.InvalidAmount.selector);
        compute.registerProvider(1, 1024, 0, 0, IPactCompute.ResourceType.Container);
    }

    function test_registerProvider_increments_id() public {
        vm.startPrank(providerOwner);
        uint256 id1 = compute.registerProvider(1, 1024, 0, 1, IPactCompute.ResourceType.Container);
        uint256 id2 = compute.registerProvider(2, 2048, 0, 2, IPactCompute.ResourceType.Container);
        vm.stopPrank();

        assertEq(id1, 1);
        assertEq(id2, 2);
        assertEq(compute.getNextProviderId(), 3);
    }

    function test_deactivateProvider_by_owner() public {
        vm.prank(providerOwner);
        uint256 id = compute.registerProvider(1, 1024, 0, 5, IPactCompute.ResourceType.Container);

        vm.prank(providerOwner);
        compute.deactivateProvider(id);

        assertFalse(compute.getProvider(id).active);
    }

    function test_deactivateProvider_by_contract_owner() public {
        vm.prank(providerOwner);
        uint256 id = compute.registerProvider(1, 1024, 0, 5, IPactCompute.ResourceType.Container);

        // contract owner (this) can also deactivate
        compute.deactivateProvider(id);
        assertFalse(compute.getProvider(id).active);
    }

    function test_deactivateProvider_reverts_not_found() public {
        vm.expectRevert(PactCompute.ProviderNotFound.selector);
        compute.deactivateProvider(999);
    }

    function test_deactivateProvider_reverts_unauthorized() public {
        vm.prank(providerOwner);
        uint256 id = compute.registerProvider(1, 1024, 0, 5, IPactCompute.ResourceType.Container);

        vm.prank(nobody);
        vm.expectRevert(PactCompute.Unauthorized.selector);
        compute.deactivateProvider(id);
    }

    // ═══════════════════════════════════════════════════════════════
    //  Pricing
    // ═══════════════════════════════════════════════════════════════

    function test_quoteCost_one_hour() public {
        vm.prank(providerOwner);
        uint256 id = compute.registerProvider(4, 8192, 0, 800, IPactCompute.ResourceType.VM);

        // 800 cents/hour * 3600s / 3600 = 800 cents
        uint256 cost = compute.quoteCost(id, 3600);
        assertEq(cost, 800);
    }

    function test_quoteCost_half_hour() public {
        vm.prank(providerOwner);
        uint256 id = compute.registerProvider(4, 8192, 0, 800, IPactCompute.ResourceType.VM);

        // (800 * 1800 + 3599) / 3600 = 400
        uint256 cost = compute.quoteCost(id, 1800);
        assertEq(cost, 400);
    }

    function test_quoteCost_rounds_up() public {
        vm.prank(providerOwner);
        uint256 id = compute.registerProvider(1, 1024, 0, 100, IPactCompute.ResourceType.Container);

        // 1 second: (100 * 1 + 3599) / 3600 = 1 (rounded up)
        uint256 cost = compute.quoteCost(id, 1);
        assertEq(cost, 1);
    }

    function test_quoteCost_reverts_not_found() public {
        vm.expectRevert(PactCompute.ProviderNotFound.selector);
        compute.quoteCost(999, 3600);
    }

    function test_centsToUsdc() public view {
        // 100 cents = 1 USDC = 1_000_000 atomic units
        assertEq(compute.centsToUsdc(100), 1_000_000);
        // 1 cent = 10_000 atomic
        assertEq(compute.centsToUsdc(1), 10_000);
        assertEq(compute.centsToUsdc(0), 0);
    }

    // ═══════════════════════════════════════════════════════════════
    //  Job Lifecycle — Happy Path
    // ═══════════════════════════════════════════════════════════════

    function _createProviderAndJob(uint256 pricePerHour, uint256 maxDuration)
        internal
        returns (uint256 providerId, uint256 jobId, uint256 depositUsdc)
    {
        vm.prank(providerOwner);
        providerId = compute.registerProvider(4, 8192, 0, pricePerHour, IPactCompute.ResourceType.VM);

        uint256 costCents = (pricePerHour * maxDuration + 3599) / 3600;
        depositUsdc = costCents * 10_000;

        vm.prank(requester);
        jobId = compute.createJob(providerId, keccak256("image"), keccak256("cmd"), maxDuration, requester);
    }

    function test_createJob() public {
        (uint256 pid, uint256 jid, uint256 deposit) = _createProviderAndJob(800, 3600);

        assertEq(jid, 1);
        IPactCompute.Job memory job = compute.getJob(jid);
        assertEq(job.providerId, pid);
        assertEq(job.requester, requester);
        assertEq(job.depositAmount, deposit);
        assertEq(uint8(job.status), uint8(IPactCompute.JobStatus.Pending));
        assertEq(compute.totalEscrowed(), deposit);

        // USDC moved
        assertEq(usdc.balanceOf(address(compute)), deposit);
    }

    function test_createJob_via_x402() public {
        compute.setX402Gateway(gateway);

        vm.prank(providerOwner);
        uint256 pid = compute.registerProvider(4, 8192, 0, 800, IPactCompute.ResourceType.VM);

        vm.prank(gateway);
        uint256 jid = compute.createJob(pid, keccak256("img"), keccak256("cmd"), 3600, requester);

        assertEq(compute.getJob(jid).requester, requester);
    }

    function test_createJob_reverts_unauthorized_relay() public {
        vm.prank(providerOwner);
        uint256 pid = compute.registerProvider(4, 8192, 0, 800, IPactCompute.ResourceType.VM);

        // nobody tries to relay on behalf of requester
        vm.prank(nobody);
        vm.expectRevert(PactCompute.Unauthorized.selector);
        compute.createJob(pid, keccak256("img"), keccak256("cmd"), 3600, requester);
    }

    function test_createJob_reverts_zero_duration() public {
        vm.prank(providerOwner);
        uint256 pid = compute.registerProvider(1, 1024, 0, 100, IPactCompute.ResourceType.Container);

        vm.prank(requester);
        vm.expectRevert(PactCompute.InvalidDuration.selector);
        compute.createJob(pid, keccak256("img"), keccak256("cmd"), 0, requester);
    }

    function test_createJob_reverts_inactive_provider() public {
        vm.prank(providerOwner);
        uint256 pid = compute.registerProvider(1, 1024, 0, 100, IPactCompute.ResourceType.Container);

        vm.prank(providerOwner);
        compute.deactivateProvider(pid);

        vm.prank(requester);
        vm.expectRevert(PactCompute.ProviderInactive.selector);
        compute.createJob(pid, keccak256("img"), keccak256("cmd"), 3600, requester);
    }

    function test_startJob() public {
        (, uint256 jid,) = _createProviderAndJob(800, 3600);

        vm.prank(providerOwner);
        compute.startJob(jid);

        IPactCompute.Job memory job = compute.getJob(jid);
        assertEq(uint8(job.status), uint8(IPactCompute.JobStatus.Running));
        assertGt(job.startedAt, 0);
    }

    function test_startJob_reverts_unauthorized() public {
        (, uint256 jid,) = _createProviderAndJob(800, 3600);

        vm.prank(nobody);
        vm.expectRevert(PactCompute.Unauthorized.selector);
        compute.startJob(jid);
    }

    function test_startJob_reverts_not_pending() public {
        (, uint256 jid,) = _createProviderAndJob(800, 3600);

        vm.prank(providerOwner);
        compute.startJob(jid);

        // already running
        vm.prank(providerOwner);
        vm.expectRevert(PactCompute.InvalidJobStatus.selector);
        compute.startJob(jid);
    }

    function test_completeJob_full_duration() public {
        (, uint256 jid, uint256 deposit) = _createProviderAndJob(800, 3600);

        vm.prank(providerOwner);
        compute.startJob(jid);

        vm.prank(providerOwner);
        compute.completeJob(jid, 3600);

        IPactCompute.Job memory job = compute.getJob(jid);
        assertEq(uint8(job.status), uint8(IPactCompute.JobStatus.Completed));
        assertEq(compute.totalEscrowed(), 0);

        // Provider gets 90%, treasury gets 10%
        uint256 treasuryAmt = (deposit * 1000) / 10_000;
        uint256 providerAmt = deposit - treasuryAmt;

        assertEq(usdc.balanceOf(providerOwner), providerAmt);
        assertEq(usdc.balanceOf(treasury), treasuryAmt);
        assertEq(usdc.balanceOf(address(compute)), 0);
    }

    function test_completeJob_partial_duration_refunds() public {
        (, uint256 jid,) = _createProviderAndJob(800, 3600);

        vm.prank(providerOwner);
        compute.startJob(jid);

        // Only ran for 1800 seconds (half)
        vm.prank(providerOwner);
        compute.completeJob(jid, 1800);

        uint256 actualCostCents = 400; // (800 * 1800 + 3599) / 3600
        uint256 actualCostUsdc = actualCostCents * 10_000; // 4_000_000
        uint256 totalDepositCents = 800; // (800 * 3600 + 3599) / 3600
        uint256 totalDepositUsdc = totalDepositCents * 10_000; // 8_000_000
        uint256 refund = totalDepositUsdc - actualCostUsdc; // 4_000_000

        uint256 treasuryAmt = (actualCostUsdc * 1000) / 10_000;
        uint256 providerAmt = actualCostUsdc - treasuryAmt;

        assertEq(usdc.balanceOf(providerOwner), providerAmt);
        assertEq(usdc.balanceOf(treasury), treasuryAmt);
        assertEq(usdc.balanceOf(requester), INITIAL_BALANCE - totalDepositUsdc + refund);
    }

    function test_completeJob_exceeds_deposit_capped() public {
        // Provider charges 800 cents/hr, job max 1800s = 400 cents deposit
        (, uint256 jid, uint256 deposit) = _createProviderAndJob(800, 1800);

        vm.prank(providerOwner);
        compute.startJob(jid);

        // Claim 7200s actual → would be 1600 cents → capped at deposit
        vm.prank(providerOwner);
        compute.completeJob(jid, 7200);

        // No refund, everything goes to provider + treasury
        uint256 treasuryAmt = (deposit * 1000) / 10_000;
        uint256 providerAmt = deposit - treasuryAmt;
        assertEq(usdc.balanceOf(providerOwner), providerAmt);
        assertEq(usdc.balanceOf(treasury), treasuryAmt);
        assertEq(usdc.balanceOf(requester), INITIAL_BALANCE - deposit);
    }

    function test_completeJob_reverts_not_running() public {
        (, uint256 jid,) = _createProviderAndJob(800, 3600);

        // Still pending, not started
        vm.prank(providerOwner);
        vm.expectRevert(PactCompute.InvalidJobStatus.selector);
        compute.completeJob(jid, 3600);
    }

    // ═══════════════════════════════════════════════════════════════
    //  Failure / Cancellation
    // ═══════════════════════════════════════════════════════════════

    function test_failJob_pending() public {
        (, uint256 jid, uint256 deposit) = _createProviderAndJob(800, 3600);

        vm.prank(providerOwner);
        compute.failJob(jid, "hardware failure");

        assertEq(uint8(compute.getJob(jid).status), uint8(IPactCompute.JobStatus.Failed));
        // Full refund
        assertEq(usdc.balanceOf(requester), INITIAL_BALANCE);
        assertEq(compute.totalEscrowed(), 0);
    }

    function test_failJob_running() public {
        (, uint256 jid,) = _createProviderAndJob(800, 3600);

        vm.prank(providerOwner);
        compute.startJob(jid);

        vm.prank(providerOwner);
        compute.failJob(jid, "OOM");

        assertEq(uint8(compute.getJob(jid).status), uint8(IPactCompute.JobStatus.Failed));
        assertEq(usdc.balanceOf(requester), INITIAL_BALANCE);
    }

    function test_failJob_reverts_already_completed() public {
        (, uint256 jid,) = _createProviderAndJob(800, 3600);

        vm.prank(providerOwner);
        compute.startJob(jid);
        vm.prank(providerOwner);
        compute.completeJob(jid, 3600);

        vm.prank(providerOwner);
        vm.expectRevert(PactCompute.InvalidJobStatus.selector);
        compute.failJob(jid, "late fail");
    }

    function test_cancelJob() public {
        (, uint256 jid, uint256 deposit) = _createProviderAndJob(800, 3600);

        vm.prank(requester);
        compute.cancelJob(jid);

        assertEq(uint8(compute.getJob(jid).status), uint8(IPactCompute.JobStatus.Cancelled));
        assertEq(usdc.balanceOf(requester), INITIAL_BALANCE);
        assertEq(compute.totalEscrowed(), 0);
    }

    function test_cancelJob_reverts_not_pending() public {
        (, uint256 jid,) = _createProviderAndJob(800, 3600);

        vm.prank(providerOwner);
        compute.startJob(jid);

        vm.prank(requester);
        vm.expectRevert(PactCompute.InvalidJobStatus.selector);
        compute.cancelJob(jid);
    }

    function test_cancelJob_reverts_unauthorized() public {
        (, uint256 jid,) = _createProviderAndJob(800, 3600);

        vm.prank(nobody);
        vm.expectRevert(PactCompute.Unauthorized.selector);
        compute.cancelJob(jid);
    }

    // ═══════════════════════════════════════════════════════════════
    //  Multiple Jobs / Escrow Tracking
    // ═══════════════════════════════════════════════════════════════

    function test_multiple_jobs_escrow_tracking() public {
        vm.prank(providerOwner);
        uint256 pid = compute.registerProvider(4, 8192, 0, 100, IPactCompute.ResourceType.VM);

        vm.startPrank(requester);
        uint256 j1 = compute.createJob(pid, keccak256("a"), keccak256("a"), 3600, requester);
        uint256 j2 = compute.createJob(pid, keccak256("b"), keccak256("b"), 7200, requester);
        vm.stopPrank();

        uint256 deposit1 = compute.getJob(j1).depositAmount;
        uint256 deposit2 = compute.getJob(j2).depositAmount;
        assertEq(compute.totalEscrowed(), deposit1 + deposit2);

        vm.prank(providerOwner);
        compute.startJob(j1);
        vm.prank(providerOwner);
        compute.completeJob(j1, 1800);

        assertEq(compute.totalEscrowed(), deposit2);

        vm.prank(requester);
        compute.cancelJob(j2);
        assertEq(compute.totalEscrowed(), 0);
    }

    // ═══════════════════════════════════════════════════════════════
    //  Edge Cases
    // ═══════════════════════════════════════════════════════════════

    function test_getJob_nonexistent() public view {
        IPactCompute.Job memory job = compute.getJob(999);
        assertEq(job.requester, address(0));
    }

    function test_getProvider_nonexistent() public view {
        IPactCompute.Provider memory p = compute.getProvider(999);
        assertEq(p.owner, address(0));
    }

    function test_completeJob_zero_duration() public {
        (, uint256 jid,) = _createProviderAndJob(800, 3600);

        vm.prank(providerOwner);
        compute.startJob(jid);

        // 0 actual duration → 0 cost → full refund
        vm.prank(providerOwner);
        compute.completeJob(jid, 0);

        assertEq(usdc.balanceOf(requester), INITIAL_BALANCE);
        assertEq(usdc.balanceOf(providerOwner), 0);
        assertEq(usdc.balanceOf(treasury), 0);
    }

    function test_provider_registers_all_four_types() public {
        vm.startPrank(providerOwner);
        compute.registerProvider(0, 0, 0, 1, IPactCompute.ResourceType.Serverless);
        compute.registerProvider(2, 4096, 0, 4, IPactCompute.ResourceType.Container);
        compute.registerProvider(8, 32768, 0, 24, IPactCompute.ResourceType.VM);
        compute.registerProvider(16, 65536, 1, 180, IPactCompute.ResourceType.GPU);
        vm.stopPrank();

        assertEq(compute.getNextProviderId(), 5);
    }
}
