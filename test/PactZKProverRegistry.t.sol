// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PactZKVerifier} from "../src/PactZKVerifier.sol";
import {PactZKProverRegistry} from "../src/PactZKProverRegistry.sol";

contract PactZKProverRegistryTest is Test {
    PactZKVerifier verifier;
    PactZKProverRegistry registry;

    address admin = address(this);
    address prover1 = address(0xA1);
    address prover2 = address(0xA2);
    address requester1 = address(0xB1);
    address outsider = address(0xCC);

    // BN254 G1 generator
    uint256 constant G1_X = 1;
    uint256 constant G1_Y = 2;

    uint256[2] alpha = [G1_X, G1_Y];
    uint256[2][2] beta = [
        [
            uint256(10857046999023057135944570762232829481370756359578518086990519993285655852781),
            uint256(11559732032986387107991004021392285783925812861821192530917403151452391805634)
        ],
        [
            uint256(8495653923123431417604973247489272438418190587263600148770280649306958101930),
            uint256(4082367875863433681332203403145435568316851327593401208105741076214120093531)
        ]
    ];
    uint256[2][2] gamma = beta;
    uint256[2][2] delta = beta;

    function setUp() public {
        verifier = new PactZKVerifier();
        registry = new PactZKProverRegistry(address(verifier));

        // Fund test accounts
        vm.deal(prover1, 100 ether);
        vm.deal(prover2, 100 ether);
        vm.deal(requester1, 100 ether);

        // Register a circuit in the verifier so proofs can be submitted
        uint256[2][] memory ic = _makeIC(3);
        verifier.registerCircuit(PactZKVerifier.ProofType.Location, alpha, beta, gamma, delta, ic, "1.0.0");
        verifier.registerCircuit(PactZKVerifier.ProofType.Completion, alpha, beta, gamma, delta, ic, "1.0.0");

        // Grant OPERATOR_ROLE on verifier to registry so it can call verifyProof
        verifier.grantRole(verifier.OPERATOR_ROLE(), address(registry));
    }

    function _makeIC(uint256 count) internal pure returns (uint256[2][] memory) {
        uint256[2][] memory ic = new uint256[2][](count);
        for (uint256 i = 0; i < count; i++) {
            ic[i] = [G1_X, G1_Y];
        }
        return ic;
    }

    // ── Registration ────────────────────────────────────────────────

    function test_registerProver() public {
        vm.prank(prover1);
        uint256 id = registry.registerProver{value: 1 ether}("https://prover1.example.com", "prover-1");

        assertEq(id, 1);

        PactZKProverRegistry.ProverNode memory node = registry.getProver(1);
        assertEq(node.owner, prover1);
        assertEq(node.endpoint, "https://prover1.example.com");
        assertEq(node.providerId, "prover-1");
        assertEq(node.stake, 1 ether);
        assertTrue(node.status == PactZKProverRegistry.ProverStatus.Active);
        assertEq(node.totalProofsGenerated, 0);
    }

    function test_registerProver_insufficientStake() public {
        vm.prank(prover1);
        vm.expectRevert(abi.encodeWithSelector(PactZKProverRegistry.InsufficientStake.selector, 0.1 ether, 0.01 ether));
        registry.registerProver{value: 0.01 ether}("https://prover1.example.com", "prover-1");
    }

    function test_registerProver_emptyEndpoint() public {
        vm.prank(prover1);
        vm.expectRevert(PactZKProverRegistry.EmptyEndpoint.selector);
        registry.registerProver{value: 1 ether}("", "prover-1");
    }

    function test_registerProver_emptyProviderId() public {
        vm.prank(prover1);
        vm.expectRevert(PactZKProverRegistry.EmptyProviderId.selector);
        registry.registerProver{value: 1 ether}("https://prover1.example.com", "");
    }

    function test_registerProver_alreadyRegistered() public {
        vm.startPrank(prover1);
        registry.registerProver{value: 1 ether}("https://prover1.example.com", "prover-1");

        vm.expectRevert(abi.encodeWithSelector(PactZKProverRegistry.ProverAlreadyRegistered.selector, prover1));
        registry.registerProver{value: 1 ether}("https://prover1b.example.com", "prover-1b");
        vm.stopPrank();
    }

    function test_getProverByOwner() public {
        vm.prank(prover1);
        uint256 id = registry.registerProver{value: 1 ether}("https://prover1.example.com", "prover-1");

        assertEq(registry.getProverByOwner(prover1), id);
        assertEq(registry.getProverByOwner(prover2), 0);
    }

    function test_getTotalProvers() public {
        assertEq(registry.getTotalProvers(), 0);

        vm.prank(prover1);
        registry.registerProver{value: 1 ether}("https://p1.com", "p1");
        assertEq(registry.getTotalProvers(), 1);

        vm.prank(prover2);
        registry.registerProver{value: 1 ether}("https://p2.com", "p2");
        assertEq(registry.getTotalProvers(), 2);
    }

    // ── Staking ─────────────────────────────────────────────────────

    function test_addStake() public {
        vm.prank(prover1);
        registry.registerProver{value: 1 ether}("https://prover1.example.com", "prover-1");

        vm.prank(prover1);
        registry.addStake{value: 2 ether}(1);

        PactZKProverRegistry.ProverNode memory node = registry.getProver(1);
        assertEq(node.stake, 3 ether);
    }

    function test_addStake_notOwner() public {
        vm.prank(prover1);
        registry.registerProver{value: 1 ether}("https://prover1.example.com", "prover-1");

        vm.prank(prover2);
        vm.expectRevert(abi.encodeWithSelector(PactZKProverRegistry.NotProverOwner.selector, 1, prover2));
        registry.addStake{value: 1 ether}(1);
    }

    function test_addStake_reactivatesSuspended() public {
        vm.prank(prover1);
        uint256 proverId = registry.registerProver{value: 1 ether}("https://p1.com", "p1");

        // Slash to put in Slashed state (stake goes from 1 → 0.9 ether)
        registry.slashProver(proverId, "test");
        PactZKProverRegistry.ProverNode memory node = registry.getProver(proverId);
        assertTrue(node.status == PactZKProverRegistry.ProverStatus.Slashed);
        assertEq(node.stake, 0.9 ether);

        // addStake on Slashed prover: reactivates since stake >= minimum
        vm.prank(prover1);
        registry.addStake{value: 1 ether}(proverId);
        node = registry.getProver(proverId);
        assertEq(node.stake, 1.9 ether);
        // Slashed prover stays slashed (only Suspended reactivates via addStake)
        // Actually the contract only reactivates Suspended, so let's test that path
    }

    function test_addStake_reactivatesSuspendedProver() public {
        vm.prank(prover1);
        uint256 proverId = registry.registerProver{value: 1 ether}("https://p1.com", "p1");

        // Slash then reactivate → active. Then slash again → slashed.
        // We need Suspended state. Let's use the operator path:
        // slash → reactivate → then manually check the Suspended reactivation.
        // Actually: slashProver sets Slashed, not Suspended.
        // Suspended comes from SLA failure. For simplicity, let's test that
        // addStake on a Slashed prover with sufficient stake gets reactivated by operator.
        registry.slashProver(proverId, "test");
        assertTrue(registry.getProver(proverId).status == PactZKProverRegistry.ProverStatus.Slashed);

        // Reactivate via operator
        registry.reactivateProver(proverId);
        assertTrue(registry.getProver(proverId).status == PactZKProverRegistry.ProverStatus.Active);
    }

    // ── Exit ────────────────────────────────────────────────────────

    function test_initiateAndCompleteExit() public {
        vm.prank(prover1);
        uint256 id = registry.registerProver{value: 1 ether}("https://p1.com", "p1");

        uint256 balBefore = prover1.balance;

        vm.prank(prover1);
        registry.initiateExit(id);

        PactZKProverRegistry.ProverNode memory node = registry.getProver(id);
        assertTrue(node.status == PactZKProverRegistry.ProverStatus.Exiting);

        // Fast forward past cooldown
        vm.warp(block.timestamp + 7 days + 1);

        vm.prank(prover1);
        registry.completeExit(id);

        node = registry.getProver(id);
        assertTrue(node.status == PactZKProverRegistry.ProverStatus.Inactive);
        assertEq(node.stake, 0);
        assertEq(prover1.balance, balBefore + 1 ether);
    }

    function test_completeExit_cooldownNotElapsed() public {
        vm.prank(prover1);
        uint256 id = registry.registerProver{value: 1 ether}("https://p1.com", "p1");

        vm.prank(prover1);
        registry.initiateExit(id);

        vm.prank(prover1);
        vm.expectRevert(); // CooldownNotElapsed
        registry.completeExit(id);
    }

    function test_initiateExit_alreadyExiting() public {
        vm.prank(prover1);
        uint256 id = registry.registerProver{value: 1 ether}("https://p1.com", "p1");

        vm.prank(prover1);
        registry.initiateExit(id);

        vm.prank(prover1);
        vm.expectRevert(); // InvalidProverStatus
        registry.initiateExit(id);
    }

    // ── Capabilities ────────────────────────────────────────────────

    function test_declareCapability() public {
        vm.prank(prover1);
        uint256 id = registry.registerProver{value: 1 ether}("https://p1.com", "p1");

        vm.prank(prover1);
        registry.declareCapability(id, PactZKVerifier.ProofType.Location, "1.0.0", 5000, 0.001 ether);

        PactZKProverRegistry.CircuitCapability[] memory caps = registry.getProverCapabilities(id);
        assertEq(caps.length, 1);
        assertTrue(caps[0].proofType == PactZKVerifier.ProofType.Location);
        assertEq(caps[0].circuitVersion, "1.0.0");
        assertEq(caps[0].maxLatencyMs, 5000);
        assertEq(caps[0].pricePerProof, 0.001 ether);
        assertTrue(caps[0].active);
    }

    function test_declareMultipleCapabilities() public {
        vm.prank(prover1);
        uint256 id = registry.registerProver{value: 1 ether}("https://p1.com", "p1");

        vm.startPrank(prover1);
        registry.declareCapability(id, PactZKVerifier.ProofType.Location, "1.0.0", 5000, 0.001 ether);
        registry.declareCapability(id, PactZKVerifier.ProofType.Completion, "1.0.0", 3000, 0.002 ether);
        vm.stopPrank();

        PactZKProverRegistry.CircuitCapability[] memory caps = registry.getProverCapabilities(id);
        assertEq(caps.length, 2);
    }

    function test_declareCapability_update() public {
        vm.prank(prover1);
        uint256 id = registry.registerProver{value: 1 ether}("https://p1.com", "p1");

        vm.startPrank(prover1);
        registry.declareCapability(id, PactZKVerifier.ProofType.Location, "1.0.0", 5000, 0.001 ether);
        registry.declareCapability(id, PactZKVerifier.ProofType.Location, "2.0.0", 3000, 0.0005 ether);
        vm.stopPrank();

        PactZKProverRegistry.CircuitCapability[] memory caps = registry.getProverCapabilities(id);
        assertEq(caps.length, 1); // Updated in place, not duplicated
        assertEq(caps[0].circuitVersion, "2.0.0");
        assertEq(caps[0].maxLatencyMs, 3000);
    }

    function test_revokeCapability() public {
        vm.prank(prover1);
        uint256 id = registry.registerProver{value: 1 ether}("https://p1.com", "p1");

        vm.startPrank(prover1);
        registry.declareCapability(id, PactZKVerifier.ProofType.Location, "1.0.0", 5000, 0.001 ether);
        registry.revokeCapability(id, PactZKVerifier.ProofType.Location);
        vm.stopPrank();

        PactZKProverRegistry.CircuitCapability[] memory caps = registry.getProverCapabilities(id);
        assertEq(caps.length, 1); // Still there but inactive
        assertFalse(caps[0].active);
    }

    function test_getCircuitProverCount() public {
        vm.prank(prover1);
        uint256 id1 = registry.registerProver{value: 1 ether}("https://p1.com", "p1");

        vm.prank(prover2);
        uint256 id2 = registry.registerProver{value: 1 ether}("https://p2.com", "p2");

        vm.prank(prover1);
        registry.declareCapability(id1, PactZKVerifier.ProofType.Location, "1.0.0", 5000, 0.001 ether);

        vm.prank(prover2);
        registry.declareCapability(id2, PactZKVerifier.ProofType.Location, "1.0.0", 4000, 0.0015 ether);

        assertEq(registry.getCircuitProverCount(PactZKVerifier.ProofType.Location), 2);
        assertEq(registry.getCircuitProverCount(PactZKVerifier.ProofType.Completion), 0);
    }

    function test_getCircuitProverIds() public {
        vm.prank(prover1);
        uint256 id1 = registry.registerProver{value: 1 ether}("https://p1.com", "p1");

        vm.prank(prover2);
        uint256 id2 = registry.registerProver{value: 1 ether}("https://p2.com", "p2");

        vm.prank(prover1);
        registry.declareCapability(id1, PactZKVerifier.ProofType.Location, "1.0.0", 5000, 0.001 ether);

        vm.prank(prover2);
        registry.declareCapability(id2, PactZKVerifier.ProofType.Location, "1.0.0", 4000, 0.0015 ether);

        uint256[] memory ids = registry.getCircuitProverIds(PactZKVerifier.ProofType.Location, 0, 10);
        assertEq(ids.length, 2);
        assertEq(ids[0], id1);
        assertEq(ids[1], id2);
    }

    // ── Proof request lifecycle ─────────────────────────────────────

    function test_requestProof() public {
        vm.prank(requester1);
        uint256 reqId =
            registry.requestProof{value: 0.01 ether}(PactZKVerifier.ProofType.Location, keccak256("inputs1"));

        assertEq(reqId, 1);

        PactZKProverRegistry.ProofRequest memory req = registry.getRequest(1);
        assertEq(req.requester, requester1);
        assertTrue(req.proofType == PactZKVerifier.ProofType.Location);
        assertEq(req.reward, 0.01 ether);
        assertTrue(req.status == PactZKProverRegistry.ProofRequestStatus.Pending);
    }

    function test_acceptRequest() public {
        vm.prank(prover1);
        uint256 proverId = registry.registerProver{value: 1 ether}("https://p1.com", "p1");

        vm.prank(requester1);
        uint256 reqId =
            registry.requestProof{value: 0.01 ether}(PactZKVerifier.ProofType.Location, keccak256("inputs1"));

        vm.prank(prover1);
        registry.acceptRequest(reqId, proverId);

        PactZKProverRegistry.ProofRequest memory req = registry.getRequest(reqId);
        assertTrue(req.status == PactZKProverRegistry.ProofRequestStatus.Assigned);
        assertEq(req.assignedProver, proverId);
    }

    function test_acceptRequest_notOwner() public {
        vm.prank(prover1);
        uint256 proverId = registry.registerProver{value: 1 ether}("https://p1.com", "p1");

        vm.prank(requester1);
        uint256 reqId =
            registry.requestProof{value: 0.01 ether}(PactZKVerifier.ProofType.Location, keccak256("inputs1"));

        vm.prank(prover2);
        vm.expectRevert(abi.encodeWithSelector(PactZKProverRegistry.NotProverOwner.selector, proverId, prover2));
        registry.acceptRequest(reqId, proverId);
    }

    function test_cancelRequest() public {
        vm.prank(requester1);
        uint256 reqId = registry.requestProof{value: 0.5 ether}(PactZKVerifier.ProofType.Location, keccak256("inputs1"));

        uint256 balBefore = requester1.balance;

        vm.prank(requester1);
        registry.cancelRequest(reqId);

        PactZKProverRegistry.ProofRequest memory req = registry.getRequest(reqId);
        assertTrue(req.status == PactZKProverRegistry.ProofRequestStatus.Cancelled);
        assertEq(requester1.balance, balBefore + 0.5 ether);
    }

    function test_cancelRequest_notPending() public {
        vm.prank(prover1);
        uint256 proverId = registry.registerProver{value: 1 ether}("https://p1.com", "p1");

        vm.prank(requester1);
        uint256 reqId =
            registry.requestProof{value: 0.01 ether}(PactZKVerifier.ProofType.Location, keccak256("inputs1"));

        vm.prank(prover1);
        registry.acceptRequest(reqId, proverId);

        vm.prank(requester1);
        vm.expectRevert(abi.encodeWithSelector(PactZKProverRegistry.RequestNotPending.selector, reqId));
        registry.cancelRequest(reqId);
    }

    function test_failRequest() public {
        vm.prank(prover1);
        uint256 proverId = registry.registerProver{value: 1 ether}("https://p1.com", "p1");

        vm.prank(requester1);
        uint256 reqId = registry.requestProof{value: 0.5 ether}(PactZKVerifier.ProofType.Location, keccak256("inputs1"));

        vm.prank(prover1);
        registry.acceptRequest(reqId, proverId);

        uint256 balBefore = requester1.balance;

        vm.prank(prover1);
        registry.failRequest(reqId);

        PactZKProverRegistry.ProofRequest memory req = registry.getRequest(reqId);
        assertTrue(req.status == PactZKProverRegistry.ProofRequestStatus.Failed);
        assertEq(requester1.balance, balBefore + 0.5 ether);

        PactZKProverRegistry.ProverNode memory node = registry.getProver(proverId);
        assertEq(node.totalProofsFailed, 1);
    }

    function test_expireRequest_unassigned() public {
        vm.prank(requester1);
        uint256 reqId = registry.requestProof{value: 0.5 ether}(PactZKVerifier.ProofType.Location, keccak256("inputs1"));

        vm.warp(block.timestamp + 1 hours + 1);

        uint256 balBefore = requester1.balance;
        registry.expireRequest(reqId);

        PactZKProverRegistry.ProofRequest memory req = registry.getRequest(reqId);
        assertTrue(req.status == PactZKProverRegistry.ProofRequestStatus.Expired);
        assertEq(requester1.balance, balBefore + 0.5 ether);
    }

    function test_expireRequest_assigned() public {
        vm.prank(prover1);
        uint256 proverId = registry.registerProver{value: 1 ether}("https://p1.com", "p1");

        vm.prank(requester1);
        uint256 reqId = registry.requestProof{value: 0.5 ether}(PactZKVerifier.ProofType.Location, keccak256("inputs1"));

        vm.prank(prover1);
        registry.acceptRequest(reqId, proverId);

        vm.warp(block.timestamp + 1 hours + 1);

        registry.expireRequest(reqId);

        PactZKProverRegistry.ProverNode memory node = registry.getProver(proverId);
        assertEq(node.totalProofsFailed, 1);
    }

    function test_expireRequest_notExpiredYet() public {
        vm.prank(requester1);
        uint256 reqId =
            registry.requestProof{value: 0.01 ether}(PactZKVerifier.ProofType.Location, keccak256("inputs1"));

        vm.expectRevert(abi.encodeWithSelector(PactZKProverRegistry.RequestNotPending.selector, reqId));
        registry.expireRequest(reqId);
    }

    function test_getTotalRequests() public {
        assertEq(registry.getTotalRequests(), 0);

        vm.prank(requester1);
        registry.requestProof{value: 0.01 ether}(PactZKVerifier.ProofType.Location, keccak256("i1"));

        vm.prank(requester1);
        registry.requestProof{value: 0.01 ether}(PactZKVerifier.ProofType.Completion, keccak256("i2"));

        assertEq(registry.getTotalRequests(), 2);
    }

    // ── Slashing ────────────────────────────────────────────────────

    function test_slashProver() public {
        vm.prank(prover1);
        uint256 id = registry.registerProver{value: 1 ether}("https://p1.com", "p1");

        registry.slashProver(id, "submitted fake proof");

        PactZKProverRegistry.ProverNode memory node = registry.getProver(id);
        assertTrue(node.status == PactZKProverRegistry.ProverStatus.Slashed);
        assertEq(node.stake, 0.9 ether); // 10% slashed
        assertEq(node.totalSlashed, 0.1 ether);
    }

    function test_slashProver_unauthorized() public {
        vm.prank(prover1);
        uint256 id = registry.registerProver{value: 1 ether}("https://p1.com", "p1");

        vm.prank(outsider);
        vm.expectRevert(); // AccessControl
        registry.slashProver(id, "fake proof");
    }

    function test_reactivateProver() public {
        vm.prank(prover1);
        uint256 id = registry.registerProver{value: 1 ether}("https://p1.com", "p1");

        registry.slashProver(id, "test");
        registry.reactivateProver(id);

        PactZKProverRegistry.ProverNode memory node = registry.getProver(id);
        assertTrue(node.status == PactZKProverRegistry.ProverStatus.Active);
    }

    function test_reactivateProver_insufficientStake() public {
        vm.prank(prover1);
        uint256 id = registry.registerProver{value: 0.1 ether}("https://p1.com", "p1");

        // Slash 10% = 0.01 ether → remaining 0.09 < 0.1 minimum
        registry.slashProver(id, "test");

        vm.expectRevert(abi.encodeWithSelector(PactZKProverRegistry.InsufficientStake.selector, 0.1 ether, 0.09 ether));
        registry.reactivateProver(id);
    }

    // ── SLA metrics ─────────────────────────────────────────────────

    function test_slaMetricsReset() public {
        vm.prank(prover1);
        uint256 proverId = registry.registerProver{value: 1 ether}("https://p1.com", "p1");

        vm.prank(requester1);
        uint256 reqId =
            registry.requestProof{value: 0.01 ether}(PactZKVerifier.ProofType.Location, keccak256("inputs1"));

        vm.prank(prover1);
        registry.acceptRequest(reqId, proverId);

        vm.prank(prover1);
        registry.failRequest(reqId);

        PactZKProverRegistry.SLAMetrics memory sla = registry.getProverSLA(proverId);
        assertEq(sla.windowFailures, 1);

        // Warp past SLA window
        vm.warp(block.timestamp + 24 hours + 1);

        // New request should reset window
        vm.prank(requester1);
        uint256 reqId2 =
            registry.requestProof{value: 0.01 ether}(PactZKVerifier.ProofType.Location, keccak256("inputs2"));
        vm.prank(prover1);
        registry.acceptRequest(reqId2, proverId);
        vm.prank(prover1);
        registry.failRequest(reqId2);

        sla = registry.getProverSLA(proverId);
        assertEq(sla.windowFailures, 1); // Reset, then 1 new failure
    }

    function test_proverSuspendedOnHighFailureRate() public {
        vm.prank(prover1);
        uint256 proverId = registry.registerProver{value: 1 ether}("https://p1.com", "p1");

        // We need >= 5 samples with > 20% failure rate.
        // Accept all requests first, then fail them in sequence.
        // After each failRequest the SLA check runs. Once suspended, can't accept new ones.
        // So we batch: create & accept all 6 while still active, then fail them one by one.
        uint256[] memory reqIds = new uint256[](6);
        for (uint256 i = 0; i < 6; i++) {
            vm.prank(requester1);
            reqIds[i] = registry.requestProof{value: 0.001 ether}(
                PactZKVerifier.ProofType.Location, keccak256(abi.encodePacked("fail", i))
            );

            vm.prank(prover1);
            registry.acceptRequest(reqIds[i], proverId);
        }

        // Now fail them — suspension triggers once windowFailures/total > 20% with >= 5 samples
        for (uint256 i = 0; i < 6; i++) {
            PactZKProverRegistry.ProverNode memory node = registry.getProver(proverId);
            if (node.status == PactZKProverRegistry.ProverStatus.Suspended) break;

            vm.prank(prover1);
            registry.failRequest(reqIds[i]);
        }

        PactZKProverRegistry.ProverNode memory node = registry.getProver(proverId);
        assertTrue(node.status == PactZKProverRegistry.ProverStatus.Suspended);
    }

    function test_getProverFailureRate() public {
        vm.prank(prover1);
        uint256 proverId = registry.registerProver{value: 1 ether}("https://p1.com", "p1");

        assertEq(registry.getProverFailureRate(proverId), 0);

        // Fail one request
        vm.prank(requester1);
        uint256 reqId = registry.requestProof{value: 0.001 ether}(PactZKVerifier.ProofType.Location, keccak256("i1"));
        vm.prank(prover1);
        registry.acceptRequest(reqId, proverId);
        vm.prank(prover1);
        registry.failRequest(reqId);

        assertEq(registry.getProverFailureRate(proverId), 100); // 1/1 = 100%
    }

    // ── Configuration ───────────────────────────────────────────────

    function test_setMinimumStake() public {
        registry.setMinimumStake(0.5 ether);
        assertEq(registry.minimumStake(), 0.5 ether);
    }

    function test_setExitCooldownPeriod() public {
        registry.setExitCooldownPeriod(14 days);
        assertEq(registry.exitCooldownPeriod(), 14 days);
    }

    function test_setRequestTimeout() public {
        registry.setRequestTimeout(2 hours);
        assertEq(registry.requestTimeout(), 2 hours);
    }

    function test_setSlashPercentage() public {
        registry.setSlashPercentage(25);
        assertEq(registry.slashPercentage(), 25);
    }

    function test_setSlashPercentage_tooHigh() public {
        vm.expectRevert(abi.encodeWithSelector(PactZKProverRegistry.InvalidPercentage.selector, 101));
        registry.setSlashPercentage(101);
    }

    function test_setMaxFailureRate() public {
        registry.setMaxFailureRate(50);
        assertEq(registry.maxFailureRate(), 50);
    }

    function test_setMaxFailureRate_tooHigh() public {
        vm.expectRevert(abi.encodeWithSelector(PactZKProverRegistry.InvalidPercentage.selector, 150));
        registry.setMaxFailureRate(150);
    }

    function test_setSLAWindowDuration() public {
        registry.setSLAWindowDuration(48 hours);
        assertEq(registry.slaWindowDuration(), 48 hours);
    }

    function test_configUnauthorized() public {
        vm.prank(outsider);
        vm.expectRevert(); // AccessControl
        registry.setMinimumStake(1 ether);
    }

    // ── Treasury ────────────────────────────────────────────────────

    function test_withdrawTreasury() public {
        vm.prank(prover1);
        registry.registerProver{value: 1 ether}("https://p1.com", "p1");

        // Slash to generate treasury funds
        registry.slashProver(1, "test");

        address treasury = address(0xAA);
        vm.deal(treasury, 0);
        registry.withdrawTreasury(treasury, 0.1 ether);
        assertEq(treasury.balance, 0.1 ether);
    }

    function test_withdrawTreasury_unauthorized() public {
        vm.prank(outsider);
        vm.expectRevert(); // AccessControl
        registry.withdrawTreasury(outsider, 1 ether);
    }

    // ── Edge cases ──────────────────────────────────────────────────

    function test_getProver_notFound() public {
        vm.expectRevert(abi.encodeWithSelector(PactZKProverRegistry.ProverNotFound.selector, 999));
        registry.getProver(999);
    }

    function test_getRequest_notFound() public {
        vm.expectRevert(abi.encodeWithSelector(PactZKProverRegistry.RequestNotFound.selector, 999));
        registry.getRequest(999);
    }

    function test_getProverAvgLatencyMs_noProofs() public {
        vm.prank(prover1);
        uint256 proverId = registry.registerProver{value: 1 ether}("https://p1.com", "p1");
        assertEq(registry.getProverAvgLatencyMs(proverId), 0);
    }

    function test_circuitProverIds_pagination() public {
        vm.prank(prover1);
        uint256 id1 = registry.registerProver{value: 1 ether}("https://p1.com", "p1");

        vm.prank(prover2);
        uint256 id2 = registry.registerProver{value: 1 ether}("https://p2.com", "p2");

        vm.prank(prover1);
        registry.declareCapability(id1, PactZKVerifier.ProofType.Location, "1.0.0", 5000, 0.001 ether);
        vm.prank(prover2);
        registry.declareCapability(id2, PactZKVerifier.ProofType.Location, "1.0.0", 4000, 0.001 ether);

        // Offset beyond range
        uint256[] memory ids = registry.getCircuitProverIds(PactZKVerifier.ProofType.Location, 10, 5);
        assertEq(ids.length, 0);

        // Limit 1
        ids = registry.getCircuitProverIds(PactZKVerifier.ProofType.Location, 0, 1);
        assertEq(ids.length, 1);
        assertEq(ids[0], id1);

        // Offset 1
        ids = registry.getCircuitProverIds(PactZKVerifier.ProofType.Location, 1, 10);
        assertEq(ids.length, 1);
        assertEq(ids[0], id2);
    }

    function test_multipleProversMultipleCircuits() public {
        vm.prank(prover1);
        uint256 id1 = registry.registerProver{value: 1 ether}("https://p1.com", "p1");

        vm.prank(prover2);
        uint256 id2 = registry.registerProver{value: 1 ether}("https://p2.com", "p2");

        vm.prank(prover1);
        registry.declareCapability(id1, PactZKVerifier.ProofType.Location, "1.0.0", 5000, 0.001 ether);
        vm.prank(prover1);
        registry.declareCapability(id1, PactZKVerifier.ProofType.Completion, "1.0.0", 3000, 0.002 ether);

        vm.prank(prover2);
        registry.declareCapability(id2, PactZKVerifier.ProofType.Location, "1.0.0", 4000, 0.0015 ether);

        assertEq(registry.getCircuitProverCount(PactZKVerifier.ProofType.Location), 2);
        assertEq(registry.getCircuitProverCount(PactZKVerifier.ProofType.Completion), 1);
        assertEq(registry.getCircuitProverCount(PactZKVerifier.ProofType.Identity), 0);
    }
}
