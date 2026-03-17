// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "openzeppelin-contracts/contracts/access/AccessControl.sol";

/// @title PactZKVerifier — On-chain ZK proof verification for PACT protocol (§7)
/// @notice Supports 4 proof types: location, completion, identity, reputation
/// @dev Uses Groth16 BN254 verification with configurable verification keys per circuit.
///      Proof hashes are stored on-chain; full Groth16 pairing checks are delegated to
///      a registered verifier contract (or can be overridden for testing).
contract PactZKVerifier is AccessControl {
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant CIRCUIT_ADMIN_ROLE = keccak256("CIRCUIT_ADMIN_ROLE");

    // ── Proof types matching whitepaper §7 ──────────────────────────
    enum ProofType {
        Location, // §7 — ZK location proof
        Completion, // §7 — ZK task completion proof
        Identity, // §7 — ZK proof of humanity
        Reputation // §7 — ZK reputation threshold proof
    }

    // ── Verification key (simplified Groth16 VK) ────────────────────
    struct VerificationKey {
        uint256[2] alpha;
        uint256[2][2] beta;
        uint256[2][2] gamma;
        uint256[2][2] delta;
        uint256[2][] ic; // input commitment points
        bool active;
        string version;
    }

    // ── Groth16 proof representation ────────────────────────────────
    struct Groth16Proof {
        uint256[2] a;
        uint256[2][2] b;
        uint256[2] c;
    }

    // ── Verified proof record ───────────────────────────────────────
    struct ProofRecord {
        ProofType proofType;
        address prover;
        bytes32 publicInputsHash;
        uint64 verifiedAt;
        bool valid;
        string circuitVersion;
    }

    // ── Storage ─────────────────────────────────────────────────────
    uint256 private nextProofId = 1;
    mapping(ProofType => VerificationKey) private vkeys;
    mapping(uint256 proofId => ProofRecord) private proofs;
    mapping(bytes32 inputsHash => uint256 proofId) private proofByInputs;
    mapping(address prover => uint256[]) private proverProofs;
    mapping(ProofType => uint256) private proofCounts;

    // ── Events ──────────────────────────────────────────────────────
    event CircuitRegistered(ProofType indexed proofType, string version, uint256 icLength);
    event CircuitDeactivated(ProofType indexed proofType, string version);
    event ProofVerified(
        uint256 indexed proofId,
        ProofType indexed proofType,
        address indexed prover,
        bytes32 publicInputsHash,
        bool valid
    );

    // ── Errors ──────────────────────────────────────────────────────
    error CircuitNotRegistered(ProofType proofType);
    error CircuitNotActive(ProofType proofType);
    error ProofAlreadyVerified(bytes32 publicInputsHash);
    error InvalidPublicInputsLength(uint256 expected, uint256 actual);
    error ProofNotFound(uint256 proofId);
    error InvalidProof();
    error EmptyIC();

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);
        _grantRole(CIRCUIT_ADMIN_ROLE, msg.sender);
    }

    // ── Circuit management ──────────────────────────────────────────

    /// @notice Register or update a Groth16 verification key for a proof type
    function registerCircuit(
        ProofType proofType,
        uint256[2] calldata alpha,
        uint256[2][2] calldata beta,
        uint256[2][2] calldata gamma,
        uint256[2][2] calldata delta,
        uint256[2][] calldata ic,
        string calldata version
    ) external onlyRole(CIRCUIT_ADMIN_ROLE) {
        if (ic.length == 0) revert EmptyIC();

        VerificationKey storage vk = vkeys[proofType];
        vk.alpha = alpha;
        vk.beta = beta;
        vk.gamma = gamma;
        vk.delta = delta;
        delete vk.ic;
        for (uint256 i = 0; i < ic.length; i++) {
            vk.ic.push(ic[i]);
        }
        vk.active = true;
        vk.version = version;

        emit CircuitRegistered(proofType, version, ic.length);
    }

    /// @notice Deactivate a circuit (prevents new proofs of that type)
    function deactivateCircuit(ProofType proofType) external onlyRole(CIRCUIT_ADMIN_ROLE) {
        VerificationKey storage vk = vkeys[proofType];
        if (!vk.active) revert CircuitNotActive(proofType);
        vk.active = false;
        emit CircuitDeactivated(proofType, vk.version);
    }

    // ── Proof verification ──────────────────────────────────────────

    /// @notice Submit and verify a ZK proof on-chain
    /// @param proofType The proof type (Location, Completion, Identity, Reputation)
    /// @param proof The Groth16 proof (a, b, c points)
    /// @param publicInputs The public signals for the circuit
    /// @return proofId The unique proof record identifier
    function verifyProof(ProofType proofType, Groth16Proof calldata proof, uint256[] calldata publicInputs)
        external
        returns (uint256 proofId)
    {
        VerificationKey storage vk = vkeys[proofType];
        if (!vk.active) revert CircuitNotActive(proofType);

        // IC length = public inputs + 1
        uint256 expectedInputs = vk.ic.length - 1;
        if (publicInputs.length != expectedInputs) {
            revert InvalidPublicInputsLength(expectedInputs, publicInputs.length);
        }

        bytes32 inputsHash = keccak256(abi.encodePacked(proofType, publicInputs));
        if (proofByInputs[inputsHash] != 0) {
            revert ProofAlreadyVerified(inputsHash);
        }

        // Verify the Groth16 proof using on-chain pairing check
        bool valid = _verifyGroth16(vk, proof, publicInputs);

        proofId = nextProofId++;
        proofs[proofId] = ProofRecord({
            proofType: proofType,
            prover: msg.sender,
            publicInputsHash: inputsHash,
            verifiedAt: uint64(block.timestamp),
            valid: valid,
            circuitVersion: vk.version
        });
        proofByInputs[inputsHash] = proofId;
        proverProofs[msg.sender].push(proofId);
        proofCounts[proofType]++;

        emit ProofVerified(proofId, proofType, msg.sender, inputsHash, valid);
    }

    // ── Queries ─────────────────────────────────────────────────────

    function getProof(uint256 proofId) external view returns (ProofRecord memory) {
        if (proofId == 0 || proofId >= nextProofId) revert ProofNotFound(proofId);
        return proofs[proofId];
    }

    function getProofByInputs(ProofType proofType, uint256[] calldata publicInputs)
        external
        view
        returns (ProofRecord memory)
    {
        bytes32 inputsHash = keccak256(abi.encodePacked(proofType, publicInputs));
        uint256 proofId = proofByInputs[inputsHash];
        if (proofId == 0) revert ProofNotFound(0);
        return proofs[proofId];
    }

    function getProverProofCount(address prover) external view returns (uint256) {
        return proverProofs[prover].length;
    }

    function getProverProofs(address prover, uint256 offset, uint256 limit)
        external
        view
        returns (ProofRecord[] memory)
    {
        uint256[] storage ids = proverProofs[prover];
        uint256 total = ids.length;
        if (offset >= total) return new ProofRecord[](0);
        uint256 end = offset + limit;
        if (end > total) end = total;
        ProofRecord[] memory result = new ProofRecord[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            result[i - offset] = proofs[ids[i]];
        }
        return result;
    }

    function getProofCount(ProofType proofType) external view returns (uint256) {
        return proofCounts[proofType];
    }

    function isCircuitActive(ProofType proofType) external view returns (bool) {
        return vkeys[proofType].active;
    }

    function getCircuitVersion(ProofType proofType) external view returns (string memory) {
        return vkeys[proofType].version;
    }

    function getCircuitICLength(ProofType proofType) external view returns (uint256) {
        return vkeys[proofType].ic.length;
    }

    function isProofValid(uint256 proofId) external view returns (bool) {
        if (proofId == 0 || proofId >= nextProofId) return false;
        return proofs[proofId].valid;
    }

    // ── Internal Groth16 verification ───────────────────────────────

    /// @dev Groth16 BN254 verification via ecPairing precompile (0x08)
    ///      Checks: e(A, B) == e(alpha, beta) * e(vk_x, gamma) * e(C, delta)
    ///      where vk_x = ic[0] + sum(publicInputs[i] * ic[i+1])
    function _verifyGroth16(VerificationKey storage vk, Groth16Proof calldata proof, uint256[] calldata publicInputs)
        internal
        view
        returns (bool)
    {
        // Compute vk_x = ic[0] + sum(input[i] * ic[i+1])
        uint256[2] memory vkX = [vk.ic[0][0], vk.ic[0][1]];

        for (uint256 i = 0; i < publicInputs.length; i++) {
            uint256[2] memory scalar = _ecMul(vk.ic[i + 1], publicInputs[i]);
            vkX = _ecAdd(vkX, scalar);
        }

        // Prepare pairing input: 4 pairs of (G1, G2) points
        // Check: e(-A, B) * e(alpha, beta) * e(vk_x, gamma) * e(C, delta) == 1
        uint256[24] memory input;

        // Pair 1: e(negA, B) — negate proof.a
        input[0] = proof.a[0];
        // Negate y coordinate for BN254: y' = P - y where P is the field modulus
        input[1] = (proof.a[1] == 0)
            ? 0
            : 21888242871839275222246405745257275088696311157297823662689037894645226208583 - proof.a[1];
        input[2] = proof.b[0][1]; // Note: Solidity stores [2][2] as [row][col], but BN254 G2 is (x_im, x_re, y_im, y_re)
        input[3] = proof.b[0][0];
        input[4] = proof.b[1][1];
        input[5] = proof.b[1][0];

        // Pair 2: e(alpha, beta)
        input[6] = vk.alpha[0];
        input[7] = vk.alpha[1];
        input[8] = vk.beta[0][1];
        input[9] = vk.beta[0][0];
        input[10] = vk.beta[1][1];
        input[11] = vk.beta[1][0];

        // Pair 3: e(vk_x, gamma)
        input[12] = vkX[0];
        input[13] = vkX[1];
        input[14] = vk.gamma[0][1];
        input[15] = vk.gamma[0][0];
        input[16] = vk.gamma[1][1];
        input[17] = vk.gamma[1][0];

        // Pair 4: e(C, delta)
        input[18] = proof.c[0];
        input[19] = proof.c[1];
        input[20] = vk.delta[0][1];
        input[21] = vk.delta[0][0];
        input[22] = vk.delta[1][1];
        input[23] = vk.delta[1][0];

        uint256[1] memory result;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            // ecPairing precompile at 0x08
            // Cap gas at 300K to avoid burning all remaining gas on invalid inputs
            let pairingGas := 300000
            if gt(pairingGas, gas()) { pairingGas := gas() }
            let success := staticcall(pairingGas, 0x08, input, 768, result, 32)
            if iszero(success) {
                // Pairing check failed — return false (not revert, to record the attempt)
                mstore(result, 0)
            }
        }

        return result[0] == 1;
    }

    /// @dev Elliptic curve point addition on BN254 (precompile 0x06)
    ///      Returns (0, 0) on failure instead of reverting, so invalid VK
    ///      gracefully yields `valid = false` from the pairing check.
    function _ecAdd(uint256[2] memory p1, uint256[2] memory p2) internal view returns (uint256[2] memory r) {
        uint256[4] memory input;
        input[0] = p1[0];
        input[1] = p1[1];
        input[2] = p2[0];
        input[3] = p2[1];
        // solhint-disable-next-line no-inline-assembly
        assembly {
            if iszero(staticcall(gas(), 0x06, input, 128, r, 64)) {
                mstore(r, 0)
                mstore(add(r, 0x20), 0)
            }
        }
    }

    /// @dev Elliptic curve scalar multiplication on BN254 (precompile 0x07)
    ///      Returns (0, 0) on failure instead of reverting.
    function _ecMul(uint256[2] memory p, uint256 s) internal view returns (uint256[2] memory r) {
        uint256[3] memory input;
        input[0] = p[0];
        input[1] = p[1];
        input[2] = s;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            if iszero(staticcall(gas(), 0x07, input, 96, r, 64)) {
                mstore(r, 0)
                mstore(add(r, 0x20), 0)
            }
        }
    }
}
