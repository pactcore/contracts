// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {PactCommerce} from "../src/PactCommerce.sol";
import {DeterministicReceiptEvaluator} from "../src/evaluators/DeterministicReceiptEvaluator.sol";
import {GovernanceReviewEvaluator} from "../src/evaluators/GovernanceReviewEvaluator.sol";
import {PactGovernance} from "../src/PactGovernance.sol";
import {ReputationGateHook} from "../src/hooks/ReputationGateHook.sol";
import {IPactCommerce} from "../src/interfaces/IPactCommerce.sol";
import {MockFailingCommerceHook} from "./mocks/MockFailingCommerceHook.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

contract PactCommerceTest is Test {
    MockUSDC private usdc;
    PactCommerce private commerce;
    ReputationGateHook private reputationHook;
    DeterministicReceiptEvaluator private deterministicEvaluator;
    MockUSDC private governanceToken;
    PactGovernance private governance;
    GovernanceReviewEvaluator private governanceEvaluator;

    address private client = makeAddr("client");
    address private provider = makeAddr("provider");
    address private evaluator = makeAddr("evaluator");
    address private treasury = makeAddr("treasury");
    address private outsider = makeAddr("outsider");
    address private voterA = makeAddr("voterA");
    address private voterB = makeAddr("voterB");

    uint256 private constant INITIAL_BALANCE = 20_000e6;
    uint256 private constant BUDGET = 1_000e6;
    uint16 private constant PLATFORM_FEE_BPS = 500;
    uint256 private constant MINIMUM_PROVIDER_SCORE = 80;
    uint64 private constant VOTING_DELAY = 1;
    uint64 private constant VOTING_PERIOD = 3 days;
    uint64 private constant TIMELOCK_DELAY = 1 days;
    uint256 private constant PROPOSAL_THRESHOLD = 100e6;
    uint256 private constant QUORUM = 500e6;
    uint256 private constant VOTER_A_POWER = 2_000e6;
    uint256 private constant VOTER_B_POWER = 1_000e6;

    function setUp() external {
        usdc = new MockUSDC();
        commerce = new PactCommerce(address(usdc), treasury, PLATFORM_FEE_BPS);
        reputationHook = new ReputationGateHook(address(commerce), MINIMUM_PROVIDER_SCORE);
        deterministicEvaluator = new DeterministicReceiptEvaluator(address(commerce));
        governanceToken = new MockUSDC();
        governance = new PactGovernance(
            address(governanceToken), VOTING_DELAY, VOTING_PERIOD, TIMELOCK_DELAY, PROPOSAL_THRESHOLD, QUORUM
        );
        governanceEvaluator = new GovernanceReviewEvaluator(address(commerce), address(governance));

        usdc.mint(client, INITIAL_BALANCE);
        vm.prank(client);
        usdc.approve(address(commerce), type(uint256).max);

        governanceToken.mint(voterA, VOTER_A_POWER);
        governanceToken.mint(voterB, VOTER_B_POWER);
    }

    function testLifecycleCompletesAndReleasesEscrow() external {
        uint256 jobId = _createAndFundJob(provider, evaluator, address(0), BUDGET, 7 days);
        bytes32 deliverable = keccak256("deliverable:v1");
        bytes32 attestation = keccak256("attestation:approved");

        vm.prank(provider);
        commerce.submit(jobId, deliverable);

        vm.prank(evaluator);
        commerce.complete(jobId, attestation);

        IPactCommerce.Job memory job = commerce.getJob(jobId);
        assertEq(uint8(job.status), uint8(IPactCommerce.Status.Completed));
        assertEq(job.deliverable, deliverable);
        assertEq(job.attestation, attestation);

        uint256 feeAmount = (BUDGET * PLATFORM_FEE_BPS) / 10_000;
        assertEq(usdc.balanceOf(provider), BUDGET - feeAmount);
        assertEq(usdc.balanceOf(treasury), feeAmount);
        assertEq(usdc.balanceOf(address(commerce)), 0);
    }

    function testEvaluatorRejectsSubmittedJobAndRefundsClient() external {
        uint256 jobId = _createAndFundJob(provider, evaluator, address(0), BUDGET, 7 days);
        bytes32 deliverable = keccak256("deliverable:rejected");
        bytes32 reason = keccak256("attestation:rejected");

        vm.prank(provider);
        commerce.submit(jobId, deliverable);

        vm.prank(evaluator);
        commerce.reject(jobId, reason);

        IPactCommerce.Job memory job = commerce.getJob(jobId);
        assertEq(uint8(job.status), uint8(IPactCommerce.Status.Rejected));
        assertEq(job.attestation, reason);
        assertEq(usdc.balanceOf(client), INITIAL_BALANCE);
        assertEq(usdc.balanceOf(address(commerce)), 0);
    }

    function testClientRejectsOpenJobBeforeFunding() external {
        uint256 jobId = _createJob(provider, evaluator, address(0), 3 days);
        bytes32 reason = keccak256("client-cancelled");

        vm.prank(client);
        commerce.reject(jobId, reason);

        IPactCommerce.Job memory job = commerce.getJob(jobId);
        assertEq(uint8(job.status), uint8(IPactCommerce.Status.Rejected));
        assertEq(job.attestation, reason);
        assertEq(usdc.balanceOf(client), INITIAL_BALANCE);
    }

    function testEvaluatorRejectsFundedJobBeforeSubmission() external {
        uint256 jobId = _createAndFundJob(provider, evaluator, address(0), BUDGET, 2 days);
        bytes32 reason = keccak256("failed-precheck");

        vm.prank(evaluator);
        commerce.reject(jobId, reason);

        IPactCommerce.Job memory job = commerce.getJob(jobId);
        assertEq(uint8(job.status), uint8(IPactCommerce.Status.Rejected));
        assertEq(job.attestation, reason);
        assertEq(usdc.balanceOf(client), INITIAL_BALANCE);
        assertEq(usdc.balanceOf(address(commerce)), 0);
    }

    function testClaimRefundAfterExpiryIsPermissionlessAndNotHooked() external {
        reputationHook.setProviderScore(provider, 100);
        uint256 jobId = _createAndFundJob(provider, evaluator, address(reputationHook), BUDGET, 1 days);

        vm.warp(block.timestamp + 1 days);
        vm.prank(outsider);
        commerce.claimRefund(jobId);

        IPactCommerce.Job memory job = commerce.getJob(jobId);
        assertEq(uint8(job.status), uint8(IPactCommerce.Status.Expired));
        assertEq(usdc.balanceOf(client), INITIAL_BALANCE);
        assertEq(usdc.balanceOf(address(commerce)), 0);
        assertEq(reputationHook.lastAfterSelector(), commerce.FUND_SELECTOR());
    }

    function testPreviewPayoutReturnsProviderAndFeeSplit() external {
        uint256 jobId = _createJob(provider, evaluator, address(0), 7 days);
        vm.prank(client);
        commerce.setBudget(jobId, BUDGET);

        (uint256 providerAmount, uint256 feeAmount) = commerce.previewPayout(jobId);

        assertEq(feeAmount, (BUDGET * PLATFORM_FEE_BPS) / 10_000);
        assertEq(providerAmount, BUDGET - feeAmount);
    }

    function testHookBlocksFundingUntilProviderMeetsReputationThreshold() external {
        uint256 jobId = _createJob(address(0), evaluator, address(reputationHook), 5 days);

        vm.expectRevert(
            abi.encodeWithSelector(
                ReputationGateHook.ProviderScoreTooLow.selector, provider, uint256(0), MINIMUM_PROVIDER_SCORE
            )
        );
        vm.prank(client);
        commerce.setProvider(jobId, provider, abi.encode("manual-assignment"));

        reputationHook.setProviderScore(provider, 100);

        vm.prank(client);
        commerce.setProvider(jobId, provider, abi.encode("manual-assignment"));
        vm.prank(client);
        commerce.setBudget(jobId, BUDGET, abi.encode("quoted-budget"));
        vm.prank(client);
        commerce.fund(jobId, BUDGET, abi.encode("funding-pass"));

        assertEq(reputationHook.lastBeforeJobId(), jobId);
        assertEq(reputationHook.lastAfterJobId(), jobId);
        assertEq(reputationHook.lastBeforeSelector(), commerce.FUND_SELECTOR());
        assertEq(reputationHook.lastAfterSelector(), commerce.FUND_SELECTOR());
        assertEq(reputationHook.lastCheckedProvider(), provider);
        assertEq(reputationHook.lastCheckedScore(), 100);
        assertEq(reputationHook.lastRequiredScore(), MINIMUM_PROVIDER_SCORE);
    }

    function testDeterministicEvaluatorCompletesWhenSubmissionMatchesExpectation() external {
        uint256 jobId = _createAndFundJob(provider, address(deterministicEvaluator), address(0), BUDGET, 7 days);
        bytes32 deliverable = keccak256("proof-commitment");
        bytes32 successAttestation = keccak256("zk-receipt");
        bytes32 failureAttestation = keccak256("invalid-proof");

        deterministicEvaluator.setExpectation(jobId, deliverable, successAttestation, failureAttestation);

        vm.prank(provider);
        commerce.submit(jobId, deliverable, abi.encode("proof://receipt"));

        deterministicEvaluator.evaluate(jobId);

        IPactCommerce.Job memory job = commerce.getJob(jobId);
        assertEq(uint8(job.status), uint8(IPactCommerce.Status.Completed));
        assertEq(job.attestation, successAttestation);
        assertEq(usdc.balanceOf(provider), BUDGET - ((BUDGET * PLATFORM_FEE_BPS) / 10_000));
    }

    function testDeterministicEvaluatorForwardsCompletionOptParamsIntoHooks() external {
        reputationHook.setProviderScore(provider, 100);

        uint256 jobId =
            _createAndFundJob(provider, address(deterministicEvaluator), address(reputationHook), BUDGET, 7 days);
        bytes32 deliverable = keccak256("proof-commitment");
        bytes32 successAttestation = keccak256("zk-receipt");
        bytes32 failureAttestation = keccak256("invalid-proof");
        bytes memory evaluatorOptParams = abi.encode("receipt://bundle", uint256(7));

        deterministicEvaluator.setExpectation(jobId, deliverable, successAttestation, failureAttestation);

        vm.prank(provider);
        commerce.submit(jobId, deliverable);

        deterministicEvaluator.evaluate(jobId, evaluatorOptParams);

        assertEq(reputationHook.lastBeforeSelector(), commerce.COMPLETE_SELECTOR());
        assertEq(reputationHook.lastAfterSelector(), commerce.COMPLETE_SELECTOR());
        assertEq(reputationHook.lastBeforeDataHash(), keccak256(abi.encode(successAttestation, evaluatorOptParams)));
        assertEq(reputationHook.lastAfterDataHash(), keccak256(abi.encode(successAttestation, evaluatorOptParams)));
    }

    function testDeterministicEvaluatorRejectsMismatchedSubmission() external {
        uint256 jobId = _createAndFundJob(provider, address(deterministicEvaluator), address(0), BUDGET, 7 days);
        bytes32 expectedDeliverable = keccak256("expected-proof");
        bytes32 wrongDeliverable = keccak256("wrong-proof");
        bytes32 successAttestation = keccak256("zk-receipt");
        bytes32 failureAttestation = keccak256("invalid-proof");

        deterministicEvaluator.setExpectation(jobId, expectedDeliverable, successAttestation, failureAttestation);

        vm.prank(provider);
        commerce.submit(jobId, wrongDeliverable);

        deterministicEvaluator.evaluate(jobId);

        IPactCommerce.Job memory job = commerce.getJob(jobId);
        assertEq(uint8(job.status), uint8(IPactCommerce.Status.Rejected));
        assertEq(job.attestation, failureAttestation);
        assertEq(usdc.balanceOf(client), INITIAL_BALANCE);
        assertEq(usdc.balanceOf(address(commerce)), 0);
    }

    function testDeterministicEvaluatorForwardsRejectOptParamsIntoHooks() external {
        reputationHook.setProviderScore(provider, 100);

        uint256 jobId =
            _createAndFundJob(provider, address(deterministicEvaluator), address(reputationHook), BUDGET, 7 days);
        bytes32 expectedDeliverable = keccak256("expected-proof");
        bytes32 wrongDeliverable = keccak256("wrong-proof");
        bytes32 successAttestation = keccak256("zk-receipt");
        bytes32 failureAttestation = keccak256("invalid-proof");
        bytes memory evaluatorOptParams = abi.encode("proof://mismatch", uint256(11));

        deterministicEvaluator.setExpectation(jobId, expectedDeliverable, successAttestation, failureAttestation);

        vm.prank(provider);
        commerce.submit(jobId, wrongDeliverable);

        deterministicEvaluator.evaluate(jobId, evaluatorOptParams);

        assertEq(reputationHook.lastBeforeSelector(), commerce.REJECT_SELECTOR());
        assertEq(reputationHook.lastAfterSelector(), commerce.REJECT_SELECTOR());
        assertEq(reputationHook.lastBeforeDataHash(), keccak256(abi.encode(failureAttestation, evaluatorOptParams)));
        assertEq(reputationHook.lastAfterDataHash(), keccak256(abi.encode(failureAttestation, evaluatorOptParams)));
    }

    function testClientAsHumanJudgeCanCompleteSubmittedJob() external {
        uint256 jobId = _createAndFundJob(provider, client, address(0), BUDGET, 7 days);
        bytes32 deliverable = keccak256("deliverable:human-review");
        bytes32 attestation = keccak256("judge:approved");

        vm.prank(provider);
        commerce.submit(jobId, deliverable, abi.encode("evidence://artifact"));

        vm.prank(client);
        commerce.complete(jobId, attestation, abi.encode("judge://decision"));

        IPactCommerce.Job memory job = commerce.getJob(jobId);
        uint256 feeAmount = (BUDGET * PLATFORM_FEE_BPS) / 10_000;

        assertEq(uint8(job.status), uint8(IPactCommerce.Status.Completed));
        assertEq(job.attestation, attestation);
        assertEq(usdc.balanceOf(provider), BUDGET - feeAmount);
        assertEq(usdc.balanceOf(treasury), feeAmount);
    }

    function testGovernanceEvaluatorCompletesSubmittedJobAfterProposalExecution() external {
        reputationHook.setProviderScore(provider, 100);

        uint256 jobId =
            _createAndFundJob(provider, address(governanceEvaluator), address(reputationHook), BUDGET, 7 days);
        bytes32 deliverable = keccak256("deliverable:dao-review");
        bytes32 attestation = keccak256("dao:approved");
        bytes memory evaluatorOptParams = abi.encode("vote://proposal-approval", uint256(42));

        vm.prank(provider);
        commerce.submit(jobId, deliverable, abi.encode("artifact://submission"));

        uint256 proposalId = _createGovernanceDecisionProposal(jobId, true, attestation, evaluatorOptParams);

        _voteForAndExecuteProposal(proposalId);

        IPactCommerce.Job memory job = commerce.getJob(jobId);
        uint256 feeAmount = (BUDGET * PLATFORM_FEE_BPS) / 10_000;

        assertEq(uint8(job.status), uint8(IPactCommerce.Status.Completed));
        assertEq(job.attestation, attestation);
        assertEq(usdc.balanceOf(provider), BUDGET - feeAmount);
        assertEq(usdc.balanceOf(treasury), feeAmount);
        assertEq(reputationHook.lastBeforeSelector(), commerce.COMPLETE_SELECTOR());
        assertEq(reputationHook.lastAfterSelector(), commerce.COMPLETE_SELECTOR());
        assertEq(reputationHook.lastBeforeDataHash(), keccak256(abi.encode(attestation, evaluatorOptParams)));
        assertEq(reputationHook.lastAfterDataHash(), keccak256(abi.encode(attestation, evaluatorOptParams)));
    }

    function testGovernanceEvaluatorRejectsSubmittedJobAfterProposalExecution() external {
        reputationHook.setProviderScore(provider, 100);

        uint256 jobId =
            _createAndFundJob(provider, address(governanceEvaluator), address(reputationHook), BUDGET, 7 days);
        bytes32 deliverable = keccak256("deliverable:dao-reject");
        bytes32 attestation = keccak256("dao:rejected");
        bytes memory evaluatorOptParams = abi.encode("vote://proposal-rejection", uint256(7));

        vm.prank(provider);
        commerce.submit(jobId, deliverable);

        uint256 proposalId = _createGovernanceDecisionProposal(jobId, false, attestation, evaluatorOptParams);

        _voteForAndExecuteProposal(proposalId);

        IPactCommerce.Job memory job = commerce.getJob(jobId);

        assertEq(uint8(job.status), uint8(IPactCommerce.Status.Rejected));
        assertEq(job.attestation, attestation);
        assertEq(usdc.balanceOf(client), INITIAL_BALANCE);
        assertEq(usdc.balanceOf(address(commerce)), 0);
        assertEq(reputationHook.lastBeforeSelector(), commerce.REJECT_SELECTOR());
        assertEq(reputationHook.lastAfterSelector(), commerce.REJECT_SELECTOR());
        assertEq(reputationHook.lastBeforeDataHash(), keccak256(abi.encode(attestation, evaluatorOptParams)));
        assertEq(reputationHook.lastAfterDataHash(), keccak256(abi.encode(attestation, evaluatorOptParams)));
    }

    function testAfterActionFailureRollsBackCompletionAndEscrowRelease() external {
        MockFailingCommerceHook failingHook = new MockFailingCommerceHook(address(commerce));
        failingHook.setFailure(commerce.COMPLETE_SELECTOR(), false, true);

        uint256 jobId = _createAndFundJob(provider, evaluator, address(failingHook), BUDGET, 7 days);
        bytes32 deliverable = keccak256("deliverable:policy-check");
        bytes32 attestation = keccak256("attestation:policy-approved");

        vm.prank(provider);
        commerce.submit(jobId, deliverable);

        vm.expectRevert(
            abi.encodeWithSelector(MockFailingCommerceHook.HookFailure.selector, commerce.COMPLETE_SELECTOR(), false)
        );
        vm.prank(evaluator);
        commerce.complete(jobId, attestation, abi.encode("policy://post-settlement"));

        IPactCommerce.Job memory job = commerce.getJob(jobId);
        assertEq(uint8(job.status), uint8(IPactCommerce.Status.Submitted));
        assertEq(job.attestation, bytes32(0));
        assertEq(usdc.balanceOf(provider), 0);
        assertEq(usdc.balanceOf(treasury), 0);
        assertEq(usdc.balanceOf(address(commerce)), BUDGET);
    }

    function _createAndFundJob(
        address jobProvider,
        address jobEvaluator,
        address hook,
        uint256 budget,
        uint256 expiryOffset
    ) internal returns (uint256 jobId) {
        jobId = _createJob(jobProvider, jobEvaluator, hook, expiryOffset);

        vm.prank(client);
        commerce.setBudget(jobId, budget);
        vm.prank(client);
        commerce.fund(jobId, budget);
    }

    function _createJob(address jobProvider, address jobEvaluator, address hook, uint256 expiryOffset)
        internal
        returns (uint256 jobId)
    {
        vm.prank(client);
        jobId = commerce.createJob(
            jobProvider, jobEvaluator, block.timestamp + expiryOffset, "ERC-8183 aligned commerce job", hook
        );
    }

    function _createGovernanceDecisionProposal(uint256 jobId, bool approve, bytes32 attestation, bytes memory optParams)
        internal
        returns (uint256 proposalId)
    {
        vm.prank(voterA);
        proposalId = governance.createCommerceDecisionProposal(
            address(governanceEvaluator), jobId, approve, attestation, optParams, "governance evaluator decision"
        );
    }

    function _voteForAndExecuteProposal(uint256 proposalId) internal {
        vm.warp(block.timestamp + VOTING_DELAY + 1);

        vm.prank(voterA);
        governance.vote(proposalId, true);

        vm.prank(voterB);
        governance.vote(proposalId, true);

        PactGovernance.Proposal memory proposal = governance.getProposal(proposalId);

        vm.warp(uint256(proposal.endTime) + 1);
        vm.warp(uint256(proposal.eta) + 1);
        governance.execute(proposalId);
    }
}
