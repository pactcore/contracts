// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "openzeppelin-contracts/contracts/access/AccessControl.sol";
import {PactZKVerifier} from "./PactZKVerifier.sol";

/// @title PactZKProverRegistry — Production ZK prover management for PACT protocol (§7)
/// @notice Manages registered ZK prover nodes (remote proving services) that can generate
///         Groth16 proofs on behalf of users. This bridges the gap between the on-chain
///         PactZKVerifier (which verifies proofs) and the core's ProductionZKProverBridge
///         (which orchestrates proving). Key features:
///         - Prover registration with stake requirements
///         - SLA tracking (latency, uptime, success rate)
///         - Circuit capability declarations per prover
///         - Proof delegation: users request proofs, provers submit them
///         - Slashing for failed/malicious proofs
///         - Reward distribution for honest proving
/// @dev Integrates with PactZKVerifier for on-chain proof verification.
contract PactZKProverRegistry is AccessControl {
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant SLASHER_ROLE = keccak256("SLASHER_ROLE");

    // ── Prover status ───────────────────────────────────────────────
    enum ProverStatus {
        Inactive, // Registered but not staked/active
        Active, // Accepting proof requests
        Suspended, // Temporarily suspended (SLA violation)
        Slashed, // Slashed for malicious behavior
        Exiting // Withdrawal pending (cooldown)
    }

    // ── Proof request status ────────────────────────────────────────
    enum ProofRequestStatus {
        Pending, // Awaiting prover assignment
        Assigned, // Prover accepted
        Fulfilled, // Proof submitted and verified
        Failed, // Prover failed to deliver
        Expired, // Request timed out
        Cancelled // Requester cancelled
    }

    // ── Prover node record ──────────────────────────────────────────
    struct ProverNode {
        address owner;
        string endpoint; // Remote prover endpoint URL
        string providerId; // Unique provider identifier
        uint256 stake; // Staked ETH
        ProverStatus status;
        uint64 registeredAt;
        uint64 lastActiveAt;
        uint256 totalProofsGenerated;
        uint256 totalProofsFailed;
        uint256 totalSlashed;
        uint256 totalRewards;
    }

    // ── Circuit capability ──────────────────────────────────────────
    struct CircuitCapability {
        PactZKVerifier.ProofType proofType;
        string circuitVersion;
        uint256 maxLatencyMs; // SLA: max proof generation time
        uint256 pricePerProof; // Price in wei per proof
        bool active;
    }

    // ── Proof request ───────────────────────────────────────────────
    struct ProofRequest {
        uint256 requestId;
        address requester;
        PactZKVerifier.ProofType proofType;
        bytes32 publicInputsHash;
        uint256 reward; // ETH offered for the proof
        uint256 assignedProver; // Prover node ID (0 = unassigned)
        ProofRequestStatus status;
        uint64 createdAt;
        uint64 deadline;
        uint64 fulfilledAt;
        uint256 verifierProofId; // PactZKVerifier proof ID once verified
    }

    // ── SLA metrics (rolling window) ────────────────────────────────
    struct SLAMetrics {
        uint256 windowProofs; // Proofs in current window
        uint256 windowFailures; // Failures in current window
        uint256 totalLatencyMs; // Sum of latency for avg calculation
        uint64 windowStart; // Current window start timestamp
    }

    // ── Configuration ───────────────────────────────────────────────
    uint256 public minimumStake = 0.1 ether;
    uint256 public exitCooldownPeriod = 7 days;
    uint256 public requestTimeout = 1 hours;
    uint256 public slashPercentage = 10; // 10% of stake
    uint256 public maxFailureRate = 20; // 20% failure → suspension
    uint64 public slaWindowDuration = 24 hours;

    // ── Storage ─────────────────────────────────────────────────────
    uint256 private nextProverId = 1;
    uint256 private nextRequestId = 1;

    mapping(uint256 proverId => ProverNode) private provers;
    mapping(address owner => uint256 proverId) private proverByOwner;
    mapping(uint256 proverId => CircuitCapability[]) private proverCapabilities;
    mapping(uint256 proverId => SLAMetrics) private proverSLA;
    mapping(uint256 proverId => uint64) private exitTimestamp;
    mapping(uint256 requestId => ProofRequest) private requests;

    // Circuit → active provers for that circuit type
    mapping(PactZKVerifier.ProofType => uint256[]) private circuitProvers;

    PactZKVerifier public immutable zkVerifier;

    // ── Events ──────────────────────────────────────────────────────
    event ProverRegistered(uint256 indexed proverId, address indexed owner, string endpoint, uint256 stake);
    event ProverStakeAdded(uint256 indexed proverId, uint256 amount, uint256 totalStake);
    event ProverActivated(uint256 indexed proverId);
    event ProverSuspended(uint256 indexed proverId, string reason);
    event ProverSlashed(uint256 indexed proverId, uint256 amount, string reason);
    event ProverExitInitiated(uint256 indexed proverId, uint64 exitAfter);
    event ProverExited(uint256 indexed proverId, uint256 stakeReturned);
    event CapabilityDeclared(uint256 indexed proverId, PactZKVerifier.ProofType indexed proofType, string version);
    event CapabilityRevoked(uint256 indexed proverId, PactZKVerifier.ProofType indexed proofType);
    event ProofRequested(uint256 indexed requestId, address indexed requester, PactZKVerifier.ProofType proofType);
    event ProofAssigned(uint256 indexed requestId, uint256 indexed proverId);
    event ProofFulfilled(uint256 indexed requestId, uint256 indexed proverId, uint256 verifierProofId);
    event ProofRequestFailed(uint256 indexed requestId, uint256 indexed proverId);
    event ProofRequestExpired(uint256 indexed requestId);
    event ProofRequestCancelled(uint256 indexed requestId);
    event RewardDistributed(uint256 indexed proverId, uint256 amount);
    event ConfigUpdated(string param, uint256 value);

    // ── Errors ──────────────────────────────────────────────────────
    error InsufficientStake(uint256 required, uint256 provided);
    error ProverNotFound(uint256 proverId);
    error ProverNotActive(uint256 proverId);
    error ProverAlreadyRegistered(address owner);
    error NotProverOwner(uint256 proverId, address caller);
    error RequestNotFound(uint256 requestId);
    error RequestNotPending(uint256 requestId);
    error RequestNotAssigned(uint256 requestId);
    error RequestExpired(uint256 requestId);
    error InvalidProverStatus(uint256 proverId, ProverStatus current, ProverStatus expected);
    error CooldownNotElapsed(uint256 proverId, uint64 exitAfter);
    error NoCapableProver(PactZKVerifier.ProofType proofType);
    error EmptyEndpoint();
    error EmptyProviderId();
    error InvalidPercentage(uint256 value);
    error ProverNotAssigned(uint256 requestId, uint256 proverId);

    constructor(address _zkVerifier) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);
        _grantRole(SLASHER_ROLE, msg.sender);
        zkVerifier = PactZKVerifier(_zkVerifier);
    }

    // ── Prover registration ─────────────────────────────────────────

    /// @notice Register as a ZK prover node with initial stake
    /// @param endpoint Remote prover service endpoint
    /// @param providerId Unique provider identifier
    /// @return proverId The assigned prover node ID
    function registerProver(string calldata endpoint, string calldata providerId)
        external
        payable
        returns (uint256 proverId)
    {
        if (bytes(endpoint).length == 0) revert EmptyEndpoint();
        if (bytes(providerId).length == 0) revert EmptyProviderId();
        if (proverByOwner[msg.sender] != 0) revert ProverAlreadyRegistered(msg.sender);
        if (msg.value < minimumStake) revert InsufficientStake(minimumStake, msg.value);

        proverId = nextProverId++;
        provers[proverId] = ProverNode({
            owner: msg.sender,
            endpoint: endpoint,
            providerId: providerId,
            stake: msg.value,
            status: ProverStatus.Active,
            registeredAt: uint64(block.timestamp),
            lastActiveAt: uint64(block.timestamp),
            totalProofsGenerated: 0,
            totalProofsFailed: 0,
            totalSlashed: 0,
            totalRewards: 0
        });
        proverByOwner[msg.sender] = proverId;
        proverSLA[proverId].windowStart = uint64(block.timestamp);

        emit ProverRegistered(proverId, msg.sender, endpoint, msg.value);
        emit ProverActivated(proverId);
    }

    /// @notice Add more stake to a prover node
    function addStake(uint256 proverId) external payable {
        ProverNode storage node = _requireProver(proverId);
        if (node.owner != msg.sender) revert NotProverOwner(proverId, msg.sender);

        node.stake += msg.value;
        emit ProverStakeAdded(proverId, msg.value, node.stake);

        // Re-activate if suspended and now meets minimum stake
        if (node.status == ProverStatus.Suspended && node.stake >= minimumStake) {
            node.status = ProverStatus.Active;
            emit ProverActivated(proverId);
        }
    }

    /// @notice Initiate exit (begins cooldown period)
    function initiateExit(uint256 proverId) external {
        ProverNode storage node = _requireProver(proverId);
        if (node.owner != msg.sender) revert NotProverOwner(proverId, msg.sender);
        if (node.status == ProverStatus.Exiting) {
            revert InvalidProverStatus(proverId, node.status, ProverStatus.Active);
        }

        node.status = ProverStatus.Exiting;
        uint64 exitAfter = uint64(block.timestamp + exitCooldownPeriod);
        exitTimestamp[proverId] = exitAfter;

        emit ProverExitInitiated(proverId, exitAfter);
    }

    /// @notice Complete exit after cooldown and withdraw stake
    function completeExit(uint256 proverId) external {
        ProverNode storage node = _requireProver(proverId);
        if (node.owner != msg.sender) revert NotProverOwner(proverId, msg.sender);
        if (node.status != ProverStatus.Exiting) {
            revert InvalidProverStatus(proverId, node.status, ProverStatus.Exiting);
        }

        uint64 exitAfter = exitTimestamp[proverId];
        if (block.timestamp < exitAfter) revert CooldownNotElapsed(proverId, exitAfter);

        uint256 stakeToReturn = node.stake;
        node.stake = 0;
        node.status = ProverStatus.Inactive;
        proverByOwner[node.owner] = 0;

        // Remove from all circuit prover lists
        _removeFromAllCircuitLists(proverId);

        (bool ok,) = payable(node.owner).call{value: stakeToReturn}("");
        require(ok, "Transfer failed");

        emit ProverExited(proverId, stakeToReturn);
    }

    // ── Circuit capabilities ────────────────────────────────────────

    /// @notice Declare capability to prove a specific circuit type
    function declareCapability(
        uint256 proverId,
        PactZKVerifier.ProofType proofType,
        string calldata circuitVersion,
        uint256 maxLatencyMs,
        uint256 pricePerProof
    ) external {
        ProverNode storage node = _requireProver(proverId);
        if (node.owner != msg.sender) revert NotProverOwner(proverId, msg.sender);

        CircuitCapability[] storage caps = proverCapabilities[proverId];

        // Update existing or push new
        bool found = false;
        for (uint256 i = 0; i < caps.length; i++) {
            if (caps[i].proofType == proofType) {
                caps[i].circuitVersion = circuitVersion;
                caps[i].maxLatencyMs = maxLatencyMs;
                caps[i].pricePerProof = pricePerProof;
                caps[i].active = true;
                found = true;
                break;
            }
        }

        if (!found) {
            caps.push(
                CircuitCapability({
                    proofType: proofType,
                    circuitVersion: circuitVersion,
                    maxLatencyMs: maxLatencyMs,
                    pricePerProof: pricePerProof,
                    active: true
                })
            );
            circuitProvers[proofType].push(proverId);
        }

        emit CapabilityDeclared(proverId, proofType, circuitVersion);
    }

    /// @notice Revoke capability for a circuit type
    function revokeCapability(uint256 proverId, PactZKVerifier.ProofType proofType) external {
        ProverNode storage node = _requireProver(proverId);
        if (node.owner != msg.sender) revert NotProverOwner(proverId, msg.sender);

        CircuitCapability[] storage caps = proverCapabilities[proverId];
        for (uint256 i = 0; i < caps.length; i++) {
            if (caps[i].proofType == proofType) {
                caps[i].active = false;
                break;
            }
        }

        _removeFromCircuitList(proofType, proverId);
        emit CapabilityRevoked(proverId, proofType);
    }

    // ── Proof request lifecycle ─────────────────────────────────────

    /// @notice Request a ZK proof generation from the prover network
    /// @param proofType Which circuit to prove
    /// @param publicInputsHash Hash of the public inputs for tracking
    /// @return requestId The proof request identifier
    function requestProof(PactZKVerifier.ProofType proofType, bytes32 publicInputsHash)
        external
        payable
        returns (uint256 requestId)
    {
        requestId = nextRequestId++;
        requests[requestId] = ProofRequest({
            requestId: requestId,
            requester: msg.sender,
            proofType: proofType,
            publicInputsHash: publicInputsHash,
            reward: msg.value,
            assignedProver: 0,
            status: ProofRequestStatus.Pending,
            createdAt: uint64(block.timestamp),
            deadline: uint64(block.timestamp + requestTimeout),
            fulfilledAt: 0,
            verifierProofId: 0
        });

        emit ProofRequested(requestId, msg.sender, proofType);
    }

    /// @notice Prover accepts a proof request
    function acceptRequest(uint256 requestId, uint256 proverId) external {
        ProofRequest storage req = _requireRequest(requestId);
        ProverNode storage node = _requireProver(proverId);

        if (req.status != ProofRequestStatus.Pending) revert RequestNotPending(requestId);
        if (node.owner != msg.sender) revert NotProverOwner(proverId, msg.sender);
        if (node.status != ProverStatus.Active) revert ProverNotActive(proverId);
        if (block.timestamp > req.deadline) revert RequestExpired(requestId);

        req.assignedProver = proverId;
        req.status = ProofRequestStatus.Assigned;
        node.lastActiveAt = uint64(block.timestamp);

        emit ProofAssigned(requestId, proverId);
    }

    /// @notice Prover submits the generated proof, which is verified via PactZKVerifier
    /// @param requestId The request being fulfilled
    /// @param proof The Groth16 proof data
    /// @param publicInputs The public inputs for verification
    /// @return verifierProofId The proof ID from PactZKVerifier
    function fulfillRequest(
        uint256 requestId,
        PactZKVerifier.Groth16Proof calldata proof,
        uint256[] calldata publicInputs
    ) external returns (uint256 verifierProofId) {
        ProofRequest storage req = _requireRequest(requestId);
        if (req.status != ProofRequestStatus.Assigned) revert RequestNotAssigned(requestId);

        uint256 proverId = req.assignedProver;
        ProverNode storage node = provers[proverId];
        if (node.owner != msg.sender) revert ProverNotAssigned(requestId, proverId);

        // Submit proof to PactZKVerifier for on-chain verification
        verifierProofId = zkVerifier.verifyProof(req.proofType, proof, publicInputs);

        req.status = ProofRequestStatus.Fulfilled;
        req.fulfilledAt = uint64(block.timestamp);
        req.verifierProofId = verifierProofId;

        // Update prover stats
        node.totalProofsGenerated++;
        node.lastActiveAt = uint64(block.timestamp);

        // Update SLA metrics
        _updateSLAWindow(proverId);
        SLAMetrics storage sla = proverSLA[proverId];
        sla.windowProofs++;
        uint256 latencyMs = (block.timestamp - req.createdAt) * 1000;
        sla.totalLatencyMs += latencyMs;

        // Distribute reward
        if (req.reward > 0) {
            node.totalRewards += req.reward;
            (bool ok,) = payable(node.owner).call{value: req.reward}("");
            require(ok, "Reward transfer failed");
            emit RewardDistributed(proverId, req.reward);
        }

        emit ProofFulfilled(requestId, proverId, verifierProofId);
    }

    /// @notice Mark a request as failed (prover couldn't deliver)
    function failRequest(uint256 requestId) external {
        ProofRequest storage req = _requireRequest(requestId);
        if (req.status != ProofRequestStatus.Assigned) revert RequestNotAssigned(requestId);

        uint256 proverId = req.assignedProver;
        ProverNode storage node = provers[proverId];
        if (node.owner != msg.sender) revert ProverNotAssigned(requestId, proverId);

        req.status = ProofRequestStatus.Failed;
        node.totalProofsFailed++;

        // Update SLA
        _updateSLAWindow(proverId);
        proverSLA[proverId].windowFailures++;

        // Check SLA threshold — suspend if failure rate too high
        _checkSLACompliance(proverId);

        // Return reward to requester
        if (req.reward > 0) {
            (bool ok,) = payable(req.requester).call{value: req.reward}("");
            require(ok, "Refund transfer failed");
        }

        emit ProofRequestFailed(requestId, proverId);
    }

    /// @notice Expire a timed-out request (anyone can call)
    function expireRequest(uint256 requestId) external {
        ProofRequest storage req = _requireRequest(requestId);
        if (req.status != ProofRequestStatus.Pending && req.status != ProofRequestStatus.Assigned) {
            revert RequestNotPending(requestId);
        }
        if (block.timestamp <= req.deadline) revert RequestNotPending(requestId);

        // If assigned, count as failure for the prover
        if (req.status == ProofRequestStatus.Assigned) {
            uint256 proverId = req.assignedProver;
            provers[proverId].totalProofsFailed++;
            _updateSLAWindow(proverId);
            proverSLA[proverId].windowFailures++;
            _checkSLACompliance(proverId);
        }

        req.status = ProofRequestStatus.Expired;

        // Return reward to requester
        if (req.reward > 0) {
            (bool ok,) = payable(req.requester).call{value: req.reward}("");
            require(ok, "Refund transfer failed");
        }

        emit ProofRequestExpired(requestId);
    }

    /// @notice Requester cancels a pending (unassigned) request
    function cancelRequest(uint256 requestId) external {
        ProofRequest storage req = _requireRequest(requestId);
        if (req.requester != msg.sender) revert RequestNotFound(requestId);
        if (req.status != ProofRequestStatus.Pending) revert RequestNotPending(requestId);

        req.status = ProofRequestStatus.Cancelled;

        if (req.reward > 0) {
            (bool ok,) = payable(req.requester).call{value: req.reward}("");
            require(ok, "Refund transfer failed");
        }

        emit ProofRequestCancelled(requestId);
    }

    // ── Slashing ────────────────────────────────────────────────────

    /// @notice Slash a prover for malicious behavior
    /// @param proverId The prover to slash
    /// @param reason Description of the violation
    function slashProver(uint256 proverId, string calldata reason) external onlyRole(SLASHER_ROLE) {
        ProverNode storage node = _requireProver(proverId);
        uint256 slashAmount = (node.stake * slashPercentage) / 100;
        if (slashAmount > node.stake) slashAmount = node.stake;

        node.stake -= slashAmount;
        node.totalSlashed += slashAmount;
        node.status = ProverStatus.Slashed;

        // Slashed amount goes to treasury (stays in contract)
        emit ProverSlashed(proverId, slashAmount, reason);
    }

    /// @notice Reactivate a suspended prover (operator only)
    function reactivateProver(uint256 proverId) external onlyRole(OPERATOR_ROLE) {
        ProverNode storage node = _requireProver(proverId);
        if (node.status != ProverStatus.Suspended && node.status != ProverStatus.Slashed) {
            revert InvalidProverStatus(proverId, node.status, ProverStatus.Suspended);
        }
        if (node.stake < minimumStake) revert InsufficientStake(minimumStake, node.stake);

        node.status = ProverStatus.Active;
        // Reset SLA window
        proverSLA[proverId] =
            SLAMetrics({windowProofs: 0, windowFailures: 0, totalLatencyMs: 0, windowStart: uint64(block.timestamp)});

        emit ProverActivated(proverId);
    }

    // ── Configuration ───────────────────────────────────────────────

    function setMinimumStake(uint256 _minimumStake) external onlyRole(DEFAULT_ADMIN_ROLE) {
        minimumStake = _minimumStake;
        emit ConfigUpdated("minimumStake", _minimumStake);
    }

    function setExitCooldownPeriod(uint256 _period) external onlyRole(DEFAULT_ADMIN_ROLE) {
        exitCooldownPeriod = _period;
        emit ConfigUpdated("exitCooldownPeriod", _period);
    }

    function setRequestTimeout(uint256 _timeout) external onlyRole(DEFAULT_ADMIN_ROLE) {
        requestTimeout = _timeout;
        emit ConfigUpdated("requestTimeout", _timeout);
    }

    function setSlashPercentage(uint256 _percentage) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_percentage > 100) revert InvalidPercentage(_percentage);
        slashPercentage = _percentage;
        emit ConfigUpdated("slashPercentage", _percentage);
    }

    function setMaxFailureRate(uint256 _rate) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_rate > 100) revert InvalidPercentage(_rate);
        maxFailureRate = _rate;
        emit ConfigUpdated("maxFailureRate", _rate);
    }

    function setSLAWindowDuration(uint64 _duration) external onlyRole(DEFAULT_ADMIN_ROLE) {
        slaWindowDuration = _duration;
        emit ConfigUpdated("slaWindowDuration", _duration);
    }

    // ── Queries ─────────────────────────────────────────────────────

    function getProver(uint256 proverId) external view returns (ProverNode memory) {
        if (provers[proverId].registeredAt == 0) revert ProverNotFound(proverId);
        return provers[proverId];
    }

    function getProverByOwner(address owner) external view returns (uint256) {
        return proverByOwner[owner];
    }

    function getProverCapabilities(uint256 proverId) external view returns (CircuitCapability[] memory) {
        return proverCapabilities[proverId];
    }

    function getProverSLA(uint256 proverId) external view returns (SLAMetrics memory) {
        return proverSLA[proverId];
    }

    function getRequest(uint256 requestId) external view returns (ProofRequest memory) {
        if (requests[requestId].createdAt == 0) revert RequestNotFound(requestId);
        return requests[requestId];
    }

    function getCircuitProverCount(PactZKVerifier.ProofType proofType) external view returns (uint256) {
        return circuitProvers[proofType].length;
    }

    function getCircuitProverIds(PactZKVerifier.ProofType proofType, uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory)
    {
        uint256[] storage ids = circuitProvers[proofType];
        uint256 total = ids.length;
        if (offset >= total) return new uint256[](0);
        uint256 end = offset + limit;
        if (end > total) end = total;
        uint256[] memory result = new uint256[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            result[i - offset] = ids[i];
        }
        return result;
    }

    function getTotalProvers() external view returns (uint256) {
        return nextProverId - 1;
    }

    function getTotalRequests() external view returns (uint256) {
        return nextRequestId - 1;
    }

    function getProverFailureRate(uint256 proverId) external view returns (uint256 ratePercent) {
        SLAMetrics storage sla = proverSLA[proverId];
        uint256 total = sla.windowProofs + sla.windowFailures;
        if (total == 0) return 0;
        return (sla.windowFailures * 100) / total;
    }

    function getProverAvgLatencyMs(uint256 proverId) external view returns (uint256) {
        SLAMetrics storage sla = proverSLA[proverId];
        if (sla.windowProofs == 0) return 0;
        return sla.totalLatencyMs / sla.windowProofs;
    }

    /// @notice Withdraw accumulated slashed funds (treasury)
    function withdrawTreasury(address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        (bool ok,) = payable(to).call{value: amount}("");
        require(ok, "Treasury withdrawal failed");
    }

    // ── Internal helpers ────────────────────────────────────────────

    function _requireProver(uint256 proverId) internal view returns (ProverNode storage) {
        ProverNode storage node = provers[proverId];
        if (node.registeredAt == 0) revert ProverNotFound(proverId);
        return node;
    }

    function _requireRequest(uint256 requestId) internal view returns (ProofRequest storage) {
        ProofRequest storage req = requests[requestId];
        if (req.createdAt == 0) revert RequestNotFound(requestId);
        return req;
    }

    function _updateSLAWindow(uint256 proverId) internal {
        SLAMetrics storage sla = proverSLA[proverId];
        if (block.timestamp >= sla.windowStart + slaWindowDuration) {
            sla.windowProofs = 0;
            sla.windowFailures = 0;
            sla.totalLatencyMs = 0;
            sla.windowStart = uint64(block.timestamp);
        }
    }

    function _checkSLACompliance(uint256 proverId) internal {
        SLAMetrics storage sla = proverSLA[proverId];
        uint256 total = sla.windowProofs + sla.windowFailures;
        if (total < 5) return; // Need minimum sample size

        uint256 failureRate = (sla.windowFailures * 100) / total;
        if (failureRate > maxFailureRate) {
            provers[proverId].status = ProverStatus.Suspended;
            emit ProverSuspended(proverId, "SLA failure rate exceeded");
        }
    }

    function _removeFromCircuitList(PactZKVerifier.ProofType proofType, uint256 proverId) internal {
        uint256[] storage ids = circuitProvers[proofType];
        for (uint256 i = 0; i < ids.length; i++) {
            if (ids[i] == proverId) {
                ids[i] = ids[ids.length - 1];
                ids.pop();
                break;
            }
        }
    }

    function _removeFromAllCircuitLists(uint256 proverId) internal {
        // Remove from all 4 proof type lists
        _removeFromCircuitList(PactZKVerifier.ProofType.Location, proverId);
        _removeFromCircuitList(PactZKVerifier.ProofType.Completion, proverId);
        _removeFromCircuitList(PactZKVerifier.ProofType.Identity, proverId);
        _removeFromCircuitList(PactZKVerifier.ProofType.Reputation, proverId);
    }
}
