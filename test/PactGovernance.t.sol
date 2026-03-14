// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {GovernanceReviewEvaluator} from "../src/evaluators/GovernanceReviewEvaluator.sol";
import {PactCommerce} from "../src/PactCommerce.sol";
import {IPactCommerce} from "../src/interfaces/IPactCommerce.sol";
import {PactGovernance} from "../src/PactGovernance.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

contract GovernanceTarget {
    uint256 public value;

    function setValue(uint256 newValue) external {
        value = newValue;
    }
}

contract PactGovernanceTest is Test {
    MockUSDC private governanceToken;
    MockUSDC private paymentToken;
    PactGovernance private governance;
    PactCommerce private commerce;
    GovernanceReviewEvaluator private evaluator;
    GovernanceTarget private target;

    address private alice = makeAddr("alice");
    address private bob = makeAddr("bob");
    address private carol = makeAddr("carol");
    address private treasury = makeAddr("treasury");

    uint64 private constant VOTING_DELAY = 1;
    uint64 private constant VOTING_PERIOD = 3 days;
    uint64 private constant TIMELOCK_DELAY = 1 days;

    uint256 private constant ALICE_VOTES = 2_000e6;
    uint256 private constant BOB_VOTES = 1_000e6;
    uint256 private constant CAROL_VOTES = 50e6;
    uint256 private constant PROPOSAL_THRESHOLD = 100e6;
    uint256 private constant QUORUM = 500e6;

    function setUp() external {
        governanceToken = new MockUSDC();
        governance = new PactGovernance(
            address(governanceToken), VOTING_DELAY, VOTING_PERIOD, TIMELOCK_DELAY, PROPOSAL_THRESHOLD, QUORUM
        );
        paymentToken = new MockUSDC();
        commerce = new PactCommerce(address(paymentToken), treasury, 0);
        evaluator = new GovernanceReviewEvaluator(address(commerce), address(governance));
        target = new GovernanceTarget();

        governanceToken.mint(alice, ALICE_VOTES);
        governanceToken.mint(bob, BOB_VOTES);
        governanceToken.mint(carol, CAROL_VOTES);
    }

    function testCreateProposalStoresConfigAndStartsPending() external {
        bytes memory data = abi.encodeWithSelector(GovernanceTarget.setValue.selector, 11);
        uint256 createdAt = block.timestamp;

        vm.prank(alice);
        uint256 proposalId = governance.createProposal(address(target), 0, data, "set value");

        PactGovernance.Proposal memory proposal = governance.getProposal(proposalId);
        assertEq(proposal.proposer, alice);
        assertEq(proposal.target, address(target));
        assertEq(proposal.value, 0);
        assertEq(keccak256(proposal.data), keccak256(data));
        assertEq(uint256(proposal.startTime), createdAt + VOTING_DELAY);
        assertEq(uint256(proposal.endTime), uint256(proposal.startTime) + VOTING_PERIOD);
        assertEq(uint256(proposal.eta), uint256(proposal.endTime) + TIMELOCK_DELAY);
        assertEq(uint8(governance.state(proposalId)), uint8(PactGovernance.ProposalState.Pending));
    }

    function testVoteTokenWeighted() external {
        uint256 proposalId = _createSetValueProposal(12);
        _moveToActive();

        vm.prank(alice);
        governance.vote(proposalId, true);

        vm.prank(bob);
        governance.vote(proposalId, false);

        PactGovernance.Proposal memory proposal = governance.getProposal(proposalId);
        assertEq(proposal.forVotes, ALICE_VOTES);
        assertEq(proposal.againstVotes, BOB_VOTES);
    }

    function testExecuteAfterTimelock() external {
        uint256 proposalId = _createSetValueProposal(99);
        _moveToActive();

        vm.prank(alice);
        governance.vote(proposalId, true);

        PactGovernance.Proposal memory proposal = governance.getProposal(proposalId);

        vm.warp(uint256(proposal.endTime) + 1);
        assertEq(uint8(governance.state(proposalId)), uint8(PactGovernance.ProposalState.Succeeded));

        vm.warp(uint256(proposal.eta) + 1);
        governance.execute(proposalId);

        assertEq(target.value(), 99);
        assertEq(uint8(governance.state(proposalId)), uint8(PactGovernance.ProposalState.Executed));
    }

    function testExecuteBeforeTimelockReverts() external {
        uint256 proposalId = _createSetValueProposal(77);
        _moveToActive();

        vm.prank(alice);
        governance.vote(proposalId, true);

        PactGovernance.Proposal memory proposal = governance.getProposal(proposalId);
        vm.warp(uint256(proposal.endTime) + 1);

        vm.expectRevert(PactGovernance.InvalidState.selector);
        governance.execute(proposalId);
    }

    function testCancelByOwner() external {
        uint256 proposalId = _createSetValueProposal(25);

        governance.cancel(proposalId);

        assertEq(uint8(governance.state(proposalId)), uint8(PactGovernance.ProposalState.Canceled));
    }

    function testCreateProposalBelowThresholdReverts() external {
        bytes memory data = abi.encodeWithSelector(GovernanceTarget.setValue.selector, 13);

        vm.prank(carol);
        vm.expectRevert(PactGovernance.ThresholdNotMet.selector);
        governance.createProposal(address(target), 0, data, "too little voting power");
    }

    function testCreateCommerceDecisionProposalTargetsGovernanceEvaluator() external {
        bytes32 attestation = keccak256("dao:attestation");
        bytes memory optParams = abi.encode("vote://review", uint256(3));

        vm.prank(alice);
        uint256 proposalId = governance.createCommerceDecisionProposal(
            address(evaluator), 21, true, attestation, optParams, "dao completes job"
        );

        PactGovernance.Proposal memory proposal = governance.getProposal(proposalId);
        bytes memory expectedData = abi.encodeWithSelector(
            GovernanceReviewEvaluator.executeDecision.selector, 21, true, attestation, optParams
        );

        assertEq(proposal.target, address(evaluator));
        assertEq(proposal.value, 0);
        assertEq(keccak256(proposal.data), keccak256(expectedData));
    }

    function testCreateCommerceDisputeProposalTargetsCommerceResolution() external {
        bytes32 resolution = keccak256("dao:dispute-resolution");

        vm.prank(alice);
        uint256 proposalId = governance.createCommerceDisputeProposal(
            address(commerce), 9, true, IPactCommerce.Status.Rejected, resolution, "dao resolves dispute"
        );

        PactGovernance.Proposal memory proposal = governance.getProposal(proposalId);
        bytes memory expectedData = abi.encodeWithSelector(
            PactCommerce.resolveDispute.selector, 9, true, IPactCommerce.Status.Rejected, resolution
        );

        assertEq(proposal.target, address(commerce));
        assertEq(proposal.value, 0);
        assertEq(keccak256(proposal.data), keccak256(expectedData));
    }

    function _createSetValueProposal(uint256 newValue) internal returns (uint256 proposalId) {
        bytes memory data = abi.encodeWithSelector(GovernanceTarget.setValue.selector, newValue);
        vm.prank(alice);
        proposalId = governance.createProposal(address(target), 0, data, "set target value");
    }

    function _moveToActive() internal {
        vm.warp(block.timestamp + VOTING_DELAY + 1);
    }
}
