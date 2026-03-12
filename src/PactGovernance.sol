// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

import {IGovernanceEvaluator} from "./interfaces/IGovernanceEvaluator.sol";

contract PactGovernance is Ownable, ReentrancyGuard {
    enum ProposalState {
        Pending,
        Active,
        Defeated,
        Succeeded,
        Queued,
        Executed,
        Canceled
    }

    struct Proposal {
        address proposer;
        address target;
        uint256 value;
        bytes data;
        bytes32 descriptionHash;
        uint64 startTime;
        uint64 endTime;
        uint64 eta;
        uint256 forVotes;
        uint256 againstVotes;
        bool executed;
        bool canceled;
    }

    IERC20 public immutable governanceToken;
    uint64 public immutable votingDelay;
    uint64 public immutable votingPeriod;
    uint64 public immutable timelockDelay;
    uint256 public immutable proposalThreshold;
    uint256 public immutable quorum;

    uint256 private nextProposalId = 1;

    mapping(uint256 proposalId => Proposal) private proposals;
    mapping(uint256 proposalId => mapping(address voter => bool)) public hasVoted;

    event ProposalCreated(
        uint256 indexed proposalId,
        address indexed proposer,
        address indexed target,
        uint256 value,
        bytes data,
        string description,
        uint64 startTime,
        uint64 endTime,
        uint64 eta
    );
    event VoteCast(uint256 indexed proposalId, address indexed voter, bool support, uint256 weight);
    event ProposalExecuted(uint256 indexed proposalId);
    event ProposalCanceled(uint256 indexed proposalId);

    error ZeroAddress();
    error InvalidConfig();
    error ThresholdNotMet();
    error InvalidProposal();
    error InvalidState();
    error AlreadyVoted();
    error NoVotingPower();
    error UnauthorizedCancel();
    error CallFailed();

    constructor(
        address governanceTokenAddress,
        uint64 votingDelaySeconds,
        uint64 votingPeriodSeconds,
        uint64 timelockDelaySeconds,
        uint256 proposalThresholdAmount,
        uint256 quorumVotes
    ) Ownable(msg.sender) {
        if (governanceTokenAddress == address(0)) revert ZeroAddress();
        if (votingPeriodSeconds == 0 || quorumVotes == 0) revert InvalidConfig();

        governanceToken = IERC20(governanceTokenAddress);
        votingDelay = votingDelaySeconds;
        votingPeriod = votingPeriodSeconds;
        timelockDelay = timelockDelaySeconds;
        proposalThreshold = proposalThresholdAmount;
        quorum = quorumVotes;
    }

    function createProposal(address target, uint256 value, bytes calldata data, string calldata description)
        external
        returns (uint256 proposalId)
    {
        proposalId = _createProposal(target, value, data, description);
    }

    function createCommerceDecisionProposal(
        address evaluator,
        uint256 jobId,
        bool approve,
        bytes32 reason,
        bytes calldata optParams,
        string calldata description
    ) external returns (uint256 proposalId) {
        bytes memory data = abi.encodeCall(IGovernanceEvaluator.executeDecision, (jobId, approve, reason, optParams));
        proposalId = _createProposal(evaluator, 0, data, description);
    }

    function _createProposal(address target, uint256 value, bytes memory data, string calldata description)
        internal
        returns (uint256 proposalId)
    {
        if (target == address(0)) revert ZeroAddress();
        if (governanceToken.balanceOf(msg.sender) < proposalThreshold) revert ThresholdNotMet();

        proposalId = nextProposalId;
        nextProposalId++;

        uint64 startTime = uint64(block.timestamp + votingDelay);
        uint64 endTime = startTime + votingPeriod;

        Proposal storage proposal = proposals[proposalId];
        proposal.proposer = msg.sender;
        proposal.target = target;
        proposal.value = value;
        proposal.data = data;
        proposal.descriptionHash = keccak256(bytes(description));
        proposal.startTime = startTime;
        proposal.endTime = endTime;
        proposal.eta = endTime + timelockDelay;

        emit ProposalCreated(proposalId, msg.sender, target, value, data, description, startTime, endTime, proposal.eta);
    }

    function vote(uint256 proposalId, bool support) external {
        Proposal storage proposal = _getProposalStorage(proposalId);
        if (state(proposalId) != ProposalState.Active) revert InvalidState();
        if (hasVoted[proposalId][msg.sender]) revert AlreadyVoted();

        uint256 weight = governanceToken.balanceOf(msg.sender);
        if (weight == 0) revert NoVotingPower();

        hasVoted[proposalId][msg.sender] = true;

        if (support) {
            proposal.forVotes += weight;
        } else {
            proposal.againstVotes += weight;
        }

        emit VoteCast(proposalId, msg.sender, support, weight);
    }

    function execute(uint256 proposalId) external nonReentrant {
        Proposal storage proposal = _getProposalStorage(proposalId);
        if (state(proposalId) != ProposalState.Queued) revert InvalidState();

        proposal.executed = true;

        (bool success,) = proposal.target.call{value: proposal.value}(proposal.data);
        if (!success) revert CallFailed();

        emit ProposalExecuted(proposalId);
    }

    function cancel(uint256 proposalId) external {
        Proposal storage proposal = _getProposalStorage(proposalId);
        if (proposal.canceled || proposal.executed) revert InvalidState();
        if (msg.sender != owner() && msg.sender != proposal.proposer) revert UnauthorizedCancel();

        proposal.canceled = true;
        emit ProposalCanceled(proposalId);
    }

    function state(uint256 proposalId) public view returns (ProposalState) {
        Proposal storage proposal = _getProposalStorage(proposalId);

        if (proposal.canceled) return ProposalState.Canceled;
        if (proposal.executed) return ProposalState.Executed;
        if (block.timestamp < proposal.startTime) return ProposalState.Pending;
        if (block.timestamp <= proposal.endTime) return ProposalState.Active;
        if (proposal.forVotes <= proposal.againstVotes || proposal.forVotes < quorum) return ProposalState.Defeated;
        if (block.timestamp < proposal.eta) return ProposalState.Succeeded;
        return ProposalState.Queued;
    }

    function getProposal(uint256 proposalId) external view returns (Proposal memory) {
        return _getProposalStorage(proposalId);
    }

    function getNextProposalId() external view returns (uint256) {
        return nextProposalId;
    }

    function _getProposalStorage(uint256 proposalId) internal view returns (Proposal storage proposal) {
        proposal = proposals[proposalId];
        if (proposal.proposer == address(0)) revert InvalidProposal();
    }

    receive() external payable {}
}
