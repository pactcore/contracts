// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PactZKVerifier} from "../src/PactZKVerifier.sol";

contract PactZKVerifierTest is Test {
    PactZKVerifier verifier;
    address admin = address(this);
    address prover1 = address(0xA1);
    address prover2 = address(0xA2);
    address outsider = address(0xBB);

    // BN254 G1 generator (1, 2) — a valid curve point
    uint256 constant G1_X = 1;
    uint256 constant G1_Y = 2;

    // Dummy VK values using valid G1 point (1,2) for alpha
    // G2 points use the BN254 generator (valid on-curve point)
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
    uint256[2][2] gamma = [
        [
            uint256(10857046999023057135944570762232829481370756359578518086990519993285655852781),
            uint256(11559732032986387107991004021392285783925812861821192530917403151452391805634)
        ],
        [
            uint256(8495653923123431417604973247489272438418190587263600148770280649306958101930),
            uint256(4082367875863433681332203403145435568316851327593401208105741076214120093531)
        ]
    ];
    uint256[2][2] delta = [
        [
            uint256(10857046999023057135944570762232829481370756359578518086990519993285655852781),
            uint256(11559732032986387107991004021392285783925812861821192530917403151452391805634)
        ],
        [
            uint256(8495653923123431417604973247489272438418190587263600148770280649306958101930),
            uint256(4082367875863433681332203403145435568316851327593401208105741076214120093531)
        ]
    ];

    function setUp() public {
        verifier = new PactZKVerifier();
    }

    // ── Helper to build IC array using valid G1 generator ───────────
    function _makeIC(uint256 count) internal pure returns (uint256[2][] memory) {
        uint256[2][] memory ic = new uint256[2][](count);
        for (uint256 i = 0; i < count; i++) {
            ic[i] = [G1_X, G1_Y];
        }
        return ic;
    }

    function _dummyProof() internal pure returns (PactZKVerifier.Groth16Proof memory) {
        return PactZKVerifier.Groth16Proof({
            a: [uint256(1), uint256(2)],
            b: [[uint256(1), uint256(2)], [uint256(3), uint256(4)]],
            c: [uint256(1), uint256(2)]
        });
    }

    // ── Circuit registration ────────────────────────────────────────

    function test_registerCircuit_location() public {
        uint256[2][] memory ic = _makeIC(5); // 4 public inputs + 1
        verifier.registerCircuit(PactZKVerifier.ProofType.Location, alpha, beta, gamma, delta, ic, "1.0.0");
        assertTrue(verifier.isCircuitActive(PactZKVerifier.ProofType.Location));
        assertEq(verifier.getCircuitVersion(PactZKVerifier.ProofType.Location), "1.0.0");
        assertEq(verifier.getCircuitICLength(PactZKVerifier.ProofType.Location), 5);
    }

    function test_registerCircuit_completion() public {
        uint256[2][] memory ic = _makeIC(4); // 3 public inputs + 1
        verifier.registerCircuit(PactZKVerifier.ProofType.Completion, alpha, beta, gamma, delta, ic, "1.0.0");
        assertTrue(verifier.isCircuitActive(PactZKVerifier.ProofType.Completion));
    }

    function test_registerCircuit_identity() public {
        uint256[2][] memory ic = _makeIC(3); // 2 public inputs + 1
        verifier.registerCircuit(PactZKVerifier.ProofType.Identity, alpha, beta, gamma, delta, ic, "1.0.0");
        assertTrue(verifier.isCircuitActive(PactZKVerifier.ProofType.Identity));
    }

    function test_registerCircuit_reputation() public {
        uint256[2][] memory ic = _makeIC(4); // 3 public inputs + 1
        verifier.registerCircuit(PactZKVerifier.ProofType.Reputation, alpha, beta, gamma, delta, ic, "1.0.0");
        assertTrue(verifier.isCircuitActive(PactZKVerifier.ProofType.Reputation));
    }

    function test_registerCircuit_emptyIC_reverts() public {
        uint256[2][] memory emptyIC = new uint256[2][](0);
        vm.expectRevert(abi.encodeWithSelector(PactZKVerifier.EmptyIC.selector));
        verifier.registerCircuit(PactZKVerifier.ProofType.Location, alpha, beta, gamma, delta, emptyIC, "1.0.0");
    }

    function test_registerCircuit_unauthorized_reverts() public {
        uint256[2][] memory ic = _makeIC(3);
        vm.prank(outsider);
        vm.expectRevert();
        verifier.registerCircuit(PactZKVerifier.ProofType.Location, alpha, beta, gamma, delta, ic, "1.0.0");
    }

    function test_registerCircuit_update() public {
        uint256[2][] memory ic3 = _makeIC(3);
        verifier.registerCircuit(PactZKVerifier.ProofType.Identity, alpha, beta, gamma, delta, ic3, "1.0.0");
        assertEq(verifier.getCircuitICLength(PactZKVerifier.ProofType.Identity), 3);

        uint256[2][] memory ic4 = _makeIC(4);
        verifier.registerCircuit(PactZKVerifier.ProofType.Identity, alpha, beta, gamma, delta, ic4, "2.0.0");
        assertEq(verifier.getCircuitICLength(PactZKVerifier.ProofType.Identity), 4);
        assertEq(verifier.getCircuitVersion(PactZKVerifier.ProofType.Identity), "2.0.0");
    }

    // ── Circuit deactivation ────────────────────────────────────────

    function test_deactivateCircuit() public {
        uint256[2][] memory ic = _makeIC(3);
        verifier.registerCircuit(PactZKVerifier.ProofType.Identity, alpha, beta, gamma, delta, ic, "1.0.0");
        assertTrue(verifier.isCircuitActive(PactZKVerifier.ProofType.Identity));

        verifier.deactivateCircuit(PactZKVerifier.ProofType.Identity);
        assertFalse(verifier.isCircuitActive(PactZKVerifier.ProofType.Identity));
    }

    function test_deactivateCircuit_alreadyInactive_reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(PactZKVerifier.CircuitNotActive.selector, PactZKVerifier.ProofType.Location)
        );
        verifier.deactivateCircuit(PactZKVerifier.ProofType.Location);
    }

    // ── Proof verification ──────────────────────────────────────────

    function test_verifyProof_records_proof() public {
        // Register circuit with 2 public inputs
        uint256[2][] memory ic = _makeIC(3);
        verifier.registerCircuit(PactZKVerifier.ProofType.Identity, alpha, beta, gamma, delta, ic, "1.0.0");

        uint256[] memory inputs = new uint256[](2);
        inputs[0] = 42;
        inputs[1] = 1;

        vm.prank(prover1);
        uint256 proofId = verifier.verifyProof(PactZKVerifier.ProofType.Identity, _dummyProof(), inputs);
        assertEq(proofId, 1);

        PactZKVerifier.ProofRecord memory record = verifier.getProof(proofId);
        assertEq(uint8(record.proofType), uint8(PactZKVerifier.ProofType.Identity));
        assertEq(record.prover, prover1);
        assertGt(record.verifiedAt, 0);
        assertEq(record.circuitVersion, "1.0.0");
    }

    function test_verifyProof_inactive_circuit_reverts() public {
        uint256[] memory inputs = new uint256[](2);
        inputs[0] = 1;
        inputs[1] = 2;

        vm.expectRevert(
            abi.encodeWithSelector(PactZKVerifier.CircuitNotActive.selector, PactZKVerifier.ProofType.Reputation)
        );
        verifier.verifyProof(PactZKVerifier.ProofType.Reputation, _dummyProof(), inputs);
    }

    function test_verifyProof_wrongInputsLength_reverts() public {
        uint256[2][] memory ic = _makeIC(4); // expects 3 inputs
        verifier.registerCircuit(PactZKVerifier.ProofType.Completion, alpha, beta, gamma, delta, ic, "1.0.0");

        uint256[] memory inputs = new uint256[](2); // wrong — should be 3
        inputs[0] = 1;
        inputs[1] = 2;

        vm.expectRevert(abi.encodeWithSelector(PactZKVerifier.InvalidPublicInputsLength.selector, 3, 2));
        verifier.verifyProof(PactZKVerifier.ProofType.Completion, _dummyProof(), inputs);
    }

    function test_verifyProof_duplicate_reverts() public {
        uint256[2][] memory ic = _makeIC(3);
        verifier.registerCircuit(PactZKVerifier.ProofType.Identity, alpha, beta, gamma, delta, ic, "1.0.0");

        uint256[] memory inputs = new uint256[](2);
        inputs[0] = 42;
        inputs[1] = 1;

        vm.prank(prover1);
        verifier.verifyProof(PactZKVerifier.ProofType.Identity, _dummyProof(), inputs);

        // Same inputs again → revert
        vm.prank(prover2);
        vm.expectRevert(
            abi.encodeWithSelector(
                PactZKVerifier.ProofAlreadyVerified.selector,
                keccak256(abi.encodePacked(PactZKVerifier.ProofType.Identity, inputs))
            )
        );
        verifier.verifyProof(PactZKVerifier.ProofType.Identity, _dummyProof(), inputs);
    }

    // ── Proof queries ───────────────────────────────────────────────

    function test_getProof_notFound_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(PactZKVerifier.ProofNotFound.selector, 999));
        verifier.getProof(999);
    }

    function test_getProofByInputs() public {
        uint256[2][] memory ic = _makeIC(3);
        verifier.registerCircuit(PactZKVerifier.ProofType.Identity, alpha, beta, gamma, delta, ic, "1.0.0");

        uint256[] memory inputs = new uint256[](2);
        inputs[0] = 100;
        inputs[1] = 1;

        vm.prank(prover1);
        verifier.verifyProof(PactZKVerifier.ProofType.Identity, _dummyProof(), inputs);

        PactZKVerifier.ProofRecord memory record = verifier.getProofByInputs(PactZKVerifier.ProofType.Identity, inputs);
        assertEq(record.prover, prover1);
    }

    function test_getProofByInputs_notFound_reverts() public {
        uint256[] memory inputs = new uint256[](2);
        inputs[0] = 1;
        inputs[1] = 2;

        vm.expectRevert(abi.encodeWithSelector(PactZKVerifier.ProofNotFound.selector, 0));
        verifier.getProofByInputs(PactZKVerifier.ProofType.Identity, inputs);
    }

    function test_proverProofCount() public {
        uint256[2][] memory ic = _makeIC(3);
        verifier.registerCircuit(PactZKVerifier.ProofType.Identity, alpha, beta, gamma, delta, ic, "1.0.0");

        assertEq(verifier.getProverProofCount(prover1), 0);

        uint256[] memory inputs1 = new uint256[](2);
        inputs1[0] = 1;
        inputs1[1] = 1;
        vm.prank(prover1);
        verifier.verifyProof(PactZKVerifier.ProofType.Identity, _dummyProof(), inputs1);

        uint256[] memory inputs2 = new uint256[](2);
        inputs2[0] = 2;
        inputs2[1] = 0;
        vm.prank(prover1);
        verifier.verifyProof(PactZKVerifier.ProofType.Identity, _dummyProof(), inputs2);

        assertEq(verifier.getProverProofCount(prover1), 2);
    }

    function test_getProverProofs_pagination() public {
        uint256[2][] memory ic = _makeIC(3);
        verifier.registerCircuit(PactZKVerifier.ProofType.Identity, alpha, beta, gamma, delta, ic, "1.0.0");

        // Submit 3 proofs
        for (uint256 i = 0; i < 3; i++) {
            uint256[] memory inputs = new uint256[](2);
            inputs[0] = i + 10;
            inputs[1] = 1;
            vm.prank(prover1);
            verifier.verifyProof(PactZKVerifier.ProofType.Identity, _dummyProof(), inputs);
        }

        // Get first 2
        PactZKVerifier.ProofRecord[] memory page1 = verifier.getProverProofs(prover1, 0, 2);
        assertEq(page1.length, 2);

        // Get last 1
        PactZKVerifier.ProofRecord[] memory page2 = verifier.getProverProofs(prover1, 2, 5);
        assertEq(page2.length, 1);

        // Offset beyond range
        PactZKVerifier.ProofRecord[] memory page3 = verifier.getProverProofs(prover1, 10, 5);
        assertEq(page3.length, 0);
    }

    function test_proofCount_perType() public {
        uint256[2][] memory ic3 = _makeIC(3);
        uint256[2][] memory ic4 = _makeIC(4);
        uint256[2][] memory ic5 = _makeIC(5);

        verifier.registerCircuit(PactZKVerifier.ProofType.Identity, alpha, beta, gamma, delta, ic3, "1.0.0");
        verifier.registerCircuit(PactZKVerifier.ProofType.Completion, alpha, beta, gamma, delta, ic4, "1.0.0");
        verifier.registerCircuit(PactZKVerifier.ProofType.Location, alpha, beta, gamma, delta, ic5, "1.0.0");

        uint256[] memory idInputs = new uint256[](2);
        idInputs[0] = 1;
        idInputs[1] = 1;
        vm.prank(prover1);
        verifier.verifyProof(PactZKVerifier.ProofType.Identity, _dummyProof(), idInputs);

        uint256[] memory compInputs = new uint256[](3);
        compInputs[0] = 1;
        compInputs[1] = 2;
        compInputs[2] = 3;
        vm.prank(prover1);
        verifier.verifyProof(PactZKVerifier.ProofType.Completion, _dummyProof(), compInputs);

        assertEq(verifier.getProofCount(PactZKVerifier.ProofType.Identity), 1);
        assertEq(verifier.getProofCount(PactZKVerifier.ProofType.Completion), 1);
        assertEq(verifier.getProofCount(PactZKVerifier.ProofType.Location), 0);
        assertEq(verifier.getProofCount(PactZKVerifier.ProofType.Reputation), 0);
    }

    function test_isProofValid_nonexistent() public view {
        assertFalse(verifier.isProofValid(0));
        assertFalse(verifier.isProofValid(999));
    }

    // ── Proof verification with deactivated circuit ─────────────────

    function test_verifyAfterDeactivate_reverts() public {
        uint256[2][] memory ic = _makeIC(3);
        verifier.registerCircuit(PactZKVerifier.ProofType.Identity, alpha, beta, gamma, delta, ic, "1.0.0");
        verifier.deactivateCircuit(PactZKVerifier.ProofType.Identity);

        uint256[] memory inputs = new uint256[](2);
        inputs[0] = 1;
        inputs[1] = 1;
        vm.expectRevert(
            abi.encodeWithSelector(PactZKVerifier.CircuitNotActive.selector, PactZKVerifier.ProofType.Identity)
        );
        verifier.verifyProof(PactZKVerifier.ProofType.Identity, _dummyProof(), inputs);
    }

    // ── Reactivate circuit ──────────────────────────────────────────

    function test_reactivateCircuit() public {
        uint256[2][] memory ic = _makeIC(3);
        verifier.registerCircuit(PactZKVerifier.ProofType.Reputation, alpha, beta, gamma, delta, ic, "1.0.0");
        verifier.deactivateCircuit(PactZKVerifier.ProofType.Reputation);
        assertFalse(verifier.isCircuitActive(PactZKVerifier.ProofType.Reputation));

        // Re-register reactivates
        verifier.registerCircuit(PactZKVerifier.ProofType.Reputation, alpha, beta, gamma, delta, ic, "1.1.0");
        assertTrue(verifier.isCircuitActive(PactZKVerifier.ProofType.Reputation));
        assertEq(verifier.getCircuitVersion(PactZKVerifier.ProofType.Reputation), "1.1.0");
    }

    // ── Multiple provers same type ──────────────────────────────────

    function test_multipleProvers() public {
        uint256[2][] memory ic = _makeIC(3);
        verifier.registerCircuit(PactZKVerifier.ProofType.Identity, alpha, beta, gamma, delta, ic, "1.0.0");

        uint256[] memory inputs1 = new uint256[](2);
        inputs1[0] = 42;
        inputs1[1] = 1;
        vm.prank(prover1);
        uint256 id1 = verifier.verifyProof(PactZKVerifier.ProofType.Identity, _dummyProof(), inputs1);

        uint256[] memory inputs2 = new uint256[](2);
        inputs2[0] = 99;
        inputs2[1] = 0;
        vm.prank(prover2);
        uint256 id2 = verifier.verifyProof(PactZKVerifier.ProofType.Identity, _dummyProof(), inputs2);

        assertEq(id1, 1);
        assertEq(id2, 2);
        assertEq(verifier.getProof(id1).prover, prover1);
        assertEq(verifier.getProof(id2).prover, prover2);
    }

    // ── All four types end-to-end ───────────────────────────────────

    function test_allFourProofTypes() public {
        // Location: 4 inputs (lat, lng, radius, timestamp)
        uint256[2][] memory locIC = _makeIC(5);
        verifier.registerCircuit(PactZKVerifier.ProofType.Location, alpha, beta, gamma, delta, locIC, "1.0.0");

        // Completion: 3 inputs (taskId, evidenceHash, completedAt)
        uint256[2][] memory compIC = _makeIC(4);
        verifier.registerCircuit(PactZKVerifier.ProofType.Completion, alpha, beta, gamma, delta, compIC, "1.0.0");

        // Identity: 2 inputs (participantId, isHuman)
        uint256[2][] memory idIC = _makeIC(3);
        verifier.registerCircuit(PactZKVerifier.ProofType.Identity, alpha, beta, gamma, delta, idIC, "1.0.0");

        // Reputation: 3 inputs (participantId, minScore, actualAbove)
        uint256[2][] memory repIC = _makeIC(4);
        verifier.registerCircuit(PactZKVerifier.ProofType.Reputation, alpha, beta, gamma, delta, repIC, "1.0.0");

        // Submit a proof for each type
        uint256[] memory locInputs = new uint256[](4);
        locInputs[0] = 40;
        locInputs[1] = 74;
        locInputs[2] = 1000;
        locInputs[3] = block.timestamp;
        vm.prank(prover1);
        verifier.verifyProof(PactZKVerifier.ProofType.Location, _dummyProof(), locInputs);

        uint256[] memory compInputs = new uint256[](3);
        compInputs[0] = 1;
        compInputs[1] = 0xdeadbeef;
        compInputs[2] = block.timestamp;
        vm.prank(prover1);
        verifier.verifyProof(PactZKVerifier.ProofType.Completion, _dummyProof(), compInputs);

        uint256[] memory idInputs = new uint256[](2);
        idInputs[0] = 42;
        idInputs[1] = 1;
        vm.prank(prover1);
        verifier.verifyProof(PactZKVerifier.ProofType.Identity, _dummyProof(), idInputs);

        uint256[] memory repInputs = new uint256[](3);
        repInputs[0] = 42;
        repInputs[1] = 75;
        repInputs[2] = 1;
        vm.prank(prover1);
        verifier.verifyProof(PactZKVerifier.ProofType.Reputation, _dummyProof(), repInputs);

        assertEq(verifier.getProofCount(PactZKVerifier.ProofType.Location), 1);
        assertEq(verifier.getProofCount(PactZKVerifier.ProofType.Completion), 1);
        assertEq(verifier.getProofCount(PactZKVerifier.ProofType.Identity), 1);
        assertEq(verifier.getProofCount(PactZKVerifier.ProofType.Reputation), 1);
        assertEq(verifier.getProverProofCount(prover1), 4);
    }
}
