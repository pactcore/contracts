// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {PactCommerce} from "../src/PactCommerce.sol";
import {DeterministicReceiptEvaluator} from "../src/evaluators/DeterministicReceiptEvaluator.sol";
import {GovernanceReviewEvaluator} from "../src/evaluators/GovernanceReviewEvaluator.sol";
import {PactGovernance} from "../src/PactGovernance.sol";
import {ApprovedEvaluatorHook} from "../src/hooks/ApprovedEvaluatorHook.sol";
import {CounterpartyPolicyHook} from "../src/hooks/CounterpartyPolicyHook.sol";
import {ReputationGateHook} from "../src/hooks/ReputationGateHook.sol";
import {IPactCommerce} from "../src/interfaces/IPactCommerce.sol";
import {MockFailingCommerceHook} from "./mocks/MockFailingCommerceHook.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

contract PactCommerceTest is Test {
    MockUSDC private usdc;
    PactCommerce private commerce;
    ApprovedEvaluatorHook private approvedEvaluatorHook;
    CounterpartyPolicyHook private counterpartyPolicyHook;
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
    uint256 private constant DISPUTE_BOND = 100e6;
    uint16 private constant PLATFORM_FEE_BPS = 500;
    uint16 private constant DISPUTE_UPHELD_PENALTY_BPS = 1_000;
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
        approvedEvaluatorHook = new ApprovedEvaluatorHook(address(commerce));
        counterpartyPolicyHook = new CounterpartyPolicyHook(address(commerce), MINIMUM_PROVIDER_SCORE);
        reputationHook = new ReputationGateHook(address(commerce), MINIMUM_PROVIDER_SCORE);
        deterministicEvaluator = new DeterministicReceiptEvaluator(address(commerce));
        governanceToken = new MockUSDC();
        governance = new PactGovernance(
            address(governanceToken), VOTING_DELAY, VOTING_PERIOD, TIMELOCK_DELAY, PROPOSAL_THRESHOLD, QUORUM
        );
        governanceEvaluator = new GovernanceReviewEvaluator(address(commerce), address(governance));

        usdc.mint(client, INITIAL_BALANCE);
        usdc.mint(outsider, INITIAL_BALANCE);
        vm.prank(client);
        usdc.approve(address(commerce), type(uint256).max);
        vm.prank(outsider);
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

    function testClientCanAssignEvaluatorLaterAndHooksReceiveOptParams() external {
        reputationHook.setProviderScore(provider, 100);

        uint256 jobId = _createJob(provider, address(0), address(reputationHook), 7 days);
        bytes memory evaluatorOptParams = abi.encode("review://shortlist", uint256(2));

        vm.prank(client);
        commerce.setEvaluator(jobId, evaluator, evaluatorOptParams);

        IPactCommerce.Job memory job = commerce.getJob(jobId);
        assertEq(job.evaluator, evaluator);
        assertEq(reputationHook.lastBeforeSelector(), commerce.SET_EVALUATOR_SELECTOR());
        assertEq(reputationHook.lastAfterSelector(), commerce.SET_EVALUATOR_SELECTOR());
        assertEq(reputationHook.lastBeforeDataHash(), keccak256(abi.encode(evaluator, evaluatorOptParams)));
        assertEq(reputationHook.lastAfterDataHash(), keccak256(abi.encode(evaluator, evaluatorOptParams)));

        vm.prank(client);
        commerce.setBudget(jobId, BUDGET);
        vm.prank(client);
        commerce.fund(jobId, BUDGET);

        bytes32 deliverable = keccak256("deliverable:late-evaluator");
        bytes32 attestation = keccak256("attestation:late-evaluator-approved");

        vm.prank(provider);
        commerce.submit(jobId, deliverable);

        vm.prank(evaluator);
        commerce.complete(jobId, attestation);

        job = commerce.getJob(jobId);
        assertEq(uint8(job.status), uint8(IPactCommerce.Status.Completed));
        assertEq(job.attestation, attestation);
    }

    function testClientCanSwapEvaluatorWhileOpen() external {
        address replacementEvaluator = makeAddr("replacementEvaluator");
        uint256 jobId = _createJob(provider, evaluator, address(0), 7 days);

        vm.prank(client);
        commerce.setEvaluator(jobId, replacementEvaluator);

        IPactCommerce.Job memory job = commerce.getJob(jobId);
        assertEq(job.evaluator, replacementEvaluator);

        vm.prank(client);
        commerce.setBudget(jobId, BUDGET);
        vm.prank(client);
        commerce.fund(jobId, BUDGET);

        vm.prank(provider);
        commerce.submit(jobId, keccak256("deliverable:replacement-evaluator"));

        vm.expectRevert(PactCommerce.UnauthorizedCaller.selector);
        vm.prank(evaluator);
        commerce.complete(jobId, keccak256("attestation:stale-evaluator"));

        vm.prank(replacementEvaluator);
        commerce.complete(jobId, keccak256("attestation:new-evaluator"));

        job = commerce.getJob(jobId);
        assertEq(uint8(job.status), uint8(IPactCommerce.Status.Completed));
    }

    function testFundingRevertsUntilEvaluatorIsAssigned() external {
        uint256 jobId = _createJob(provider, address(0), address(0), 7 days);

        vm.prank(client);
        commerce.setBudget(jobId, BUDGET);

        vm.expectRevert(PactCommerce.EvaluatorRequired.selector);
        vm.prank(client);
        commerce.fund(jobId, BUDGET);
    }

    function testCounterpartyPolicyHookEnforcesProviderAndEvaluatorAssignment() external {
        uint256 jobId = _createJob(address(0), address(0), address(counterpartyPolicyHook), 7 days);
        bytes memory providerOptParams = abi.encode("assignment://provider", uint256(1));
        bytes memory evaluatorOptParams = abi.encode("assignment://evaluator", uint256(2));

        vm.expectRevert(
            abi.encodeWithSelector(
                CounterpartyPolicyHook.ProviderScoreTooLow.selector, provider, uint256(0), MINIMUM_PROVIDER_SCORE
            )
        );
        vm.prank(client);
        commerce.setProvider(jobId, provider, providerOptParams);

        counterpartyPolicyHook.setProviderScore(provider, 100);

        vm.prank(client);
        commerce.setProvider(jobId, provider, providerOptParams);

        vm.expectRevert(abi.encodeWithSelector(CounterpartyPolicyHook.EvaluatorNotApproved.selector, evaluator));
        vm.prank(client);
        commerce.setEvaluator(jobId, evaluator, evaluatorOptParams);

        counterpartyPolicyHook.setEvaluatorApproval(evaluator, true);

        vm.prank(client);
        commerce.setEvaluator(jobId, evaluator, evaluatorOptParams);

        IPactCommerce.Job memory job = commerce.getJob(jobId);
        assertEq(job.provider, provider);
        assertEq(job.evaluator, evaluator);
        assertEq(counterpartyPolicyHook.lastBeforeSelector(), commerce.SET_EVALUATOR_SELECTOR());
        assertEq(counterpartyPolicyHook.lastAfterSelector(), commerce.SET_EVALUATOR_SELECTOR());
        assertEq(counterpartyPolicyHook.lastBeforeDataHash(), keccak256(abi.encode(evaluator, evaluatorOptParams)));
        assertEq(counterpartyPolicyHook.lastAfterDataHash(), keccak256(abi.encode(evaluator, evaluatorOptParams)));
        assertEq(counterpartyPolicyHook.lastCheckedProvider(), provider);
        assertEq(counterpartyPolicyHook.lastCheckedScore(), 100);
        assertEq(counterpartyPolicyHook.lastCheckedEvaluator(), evaluator);
        assertTrue(counterpartyPolicyHook.lastCheckedApproval());
    }

    function testCounterpartyPolicyHookRechecksBothPartiesAtFunding() external {
        uint256 jobId = _createJob(provider, address(governanceEvaluator), address(counterpartyPolicyHook), 7 days);

        counterpartyPolicyHook.setProviderScore(provider, 100);
        counterpartyPolicyHook.setEvaluatorApproval(address(governanceEvaluator), true);

        vm.prank(client);
        commerce.setBudget(jobId, BUDGET, abi.encode("quoted-budget"));

        counterpartyPolicyHook.setProviderScore(provider, 40);

        vm.expectRevert(
            abi.encodeWithSelector(
                CounterpartyPolicyHook.ProviderScoreTooLow.selector, provider, uint256(40), MINIMUM_PROVIDER_SCORE
            )
        );
        vm.prank(client);
        commerce.fund(jobId, BUDGET, abi.encode("funding-pass"));

        counterpartyPolicyHook.setProviderScore(provider, 100);
        counterpartyPolicyHook.setEvaluatorApproval(address(governanceEvaluator), false);

        vm.expectRevert(
            abi.encodeWithSelector(CounterpartyPolicyHook.EvaluatorNotApproved.selector, address(governanceEvaluator))
        );
        vm.prank(client);
        commerce.fund(jobId, BUDGET, abi.encode("funding-pass"));

        counterpartyPolicyHook.setEvaluatorApproval(address(governanceEvaluator), true);

        vm.prank(client);
        commerce.fund(jobId, BUDGET, abi.encode("funding-pass"));

        IPactCommerce.Job memory job = commerce.getJob(jobId);
        assertEq(uint8(job.status), uint8(IPactCommerce.Status.Funded));
        assertEq(counterpartyPolicyHook.lastBeforeSelector(), commerce.FUND_SELECTOR());
        assertEq(counterpartyPolicyHook.lastAfterSelector(), commerce.FUND_SELECTOR());
        assertEq(counterpartyPolicyHook.lastBeforeDataHash(), keccak256(abi.encode("funding-pass")));
        assertEq(counterpartyPolicyHook.lastAfterDataHash(), keccak256(abi.encode("funding-pass")));
        assertEq(counterpartyPolicyHook.lastCheckedProvider(), provider);
        assertEq(counterpartyPolicyHook.lastCheckedScore(), 100);
        assertEq(counterpartyPolicyHook.lastCheckedEvaluator(), address(governanceEvaluator));
        assertTrue(counterpartyPolicyHook.lastCheckedApproval());
    }

    function testCounterpartyPolicyHookSupportsGovernanceEvaluatorCompletion() external {
        uint256 jobId = _createJob(address(0), address(0), address(counterpartyPolicyHook), 7 days);
        bytes32 deliverable = keccak256("deliverable:counterparty-policy");
        bytes32 attestation = keccak256("dao:counterparty-approved");
        bytes memory providerOptParams = abi.encode("assignment://provider", uint256(3));
        bytes memory evaluatorOptParams = abi.encode("assignment://governance", uint256(4));
        bytes memory governanceOptParams = abi.encode("vote://proposal-approval", uint256(123));

        counterpartyPolicyHook.setProviderScore(provider, 100);
        counterpartyPolicyHook.setEvaluatorApproval(address(governanceEvaluator), true);

        vm.prank(client);
        commerce.setProvider(jobId, provider, providerOptParams);
        vm.prank(client);
        commerce.setEvaluator(jobId, address(governanceEvaluator), evaluatorOptParams);
        vm.prank(client);
        commerce.setBudget(jobId, BUDGET);
        vm.prank(client);
        commerce.fund(jobId, BUDGET);

        vm.prank(provider);
        commerce.submit(jobId, deliverable, abi.encode("artifact://submission"));

        uint256 proposalId = _createGovernanceDecisionProposal(jobId, true, attestation, governanceOptParams);
        _voteForAndExecuteProposal(proposalId);

        IPactCommerce.Job memory job = commerce.getJob(jobId);
        uint256 feeAmount = (BUDGET * PLATFORM_FEE_BPS) / 10_000;

        assertEq(uint8(job.status), uint8(IPactCommerce.Status.Completed));
        assertEq(job.provider, provider);
        assertEq(job.evaluator, address(governanceEvaluator));
        assertEq(job.attestation, attestation);
        assertEq(usdc.balanceOf(provider), BUDGET - feeAmount);
        assertEq(usdc.balanceOf(treasury), feeAmount);
    }

    function testApprovedEvaluatorHookBlocksUnapprovedAssignment() external {
        uint256 jobId = _createJob(provider, address(0), address(approvedEvaluatorHook), 7 days);
        bytes memory evaluatorOptParams = abi.encode("policy://candidate", uint256(1));

        vm.expectRevert(abi.encodeWithSelector(ApprovedEvaluatorHook.EvaluatorNotApproved.selector, evaluator));
        vm.prank(client);
        commerce.setEvaluator(jobId, evaluator, evaluatorOptParams);

        approvedEvaluatorHook.setEvaluatorApproval(evaluator, true);

        vm.prank(client);
        commerce.setEvaluator(jobId, evaluator, evaluatorOptParams);

        IPactCommerce.Job memory job = commerce.getJob(jobId);
        assertEq(job.evaluator, evaluator);
        assertEq(approvedEvaluatorHook.lastBeforeSelector(), commerce.SET_EVALUATOR_SELECTOR());
        assertEq(approvedEvaluatorHook.lastAfterSelector(), commerce.SET_EVALUATOR_SELECTOR());
        assertEq(approvedEvaluatorHook.lastBeforeDataHash(), keccak256(abi.encode(evaluator, evaluatorOptParams)));
        assertEq(approvedEvaluatorHook.lastAfterDataHash(), keccak256(abi.encode(evaluator, evaluatorOptParams)));
        assertEq(approvedEvaluatorHook.lastCheckedEvaluator(), evaluator);
        assertTrue(approvedEvaluatorHook.lastCheckedApproval());
    }

    function testApprovedEvaluatorHookRechecksApprovalAtFunding() external {
        approvedEvaluatorHook.setEvaluatorApproval(address(governanceEvaluator), true);

        uint256 jobId = _createJob(provider, address(governanceEvaluator), address(approvedEvaluatorHook), 7 days);

        vm.prank(client);
        commerce.setBudget(jobId, BUDGET, abi.encode("quoted-budget"));

        approvedEvaluatorHook.setEvaluatorApproval(address(governanceEvaluator), false);

        vm.expectRevert(
            abi.encodeWithSelector(ApprovedEvaluatorHook.EvaluatorNotApproved.selector, address(governanceEvaluator))
        );
        vm.prank(client);
        commerce.fund(jobId, BUDGET, abi.encode("funding-check"));

        approvedEvaluatorHook.setEvaluatorApproval(address(governanceEvaluator), true);

        vm.prank(client);
        commerce.fund(jobId, BUDGET, abi.encode("funding-check"));

        assertEq(approvedEvaluatorHook.lastBeforeSelector(), commerce.FUND_SELECTOR());
        assertEq(approvedEvaluatorHook.lastAfterSelector(), commerce.FUND_SELECTOR());
        assertEq(approvedEvaluatorHook.lastBeforeDataHash(), keccak256(abi.encode("funding-check")));
        assertEq(approvedEvaluatorHook.lastAfterDataHash(), keccak256(abi.encode("funding-check")));
        assertEq(approvedEvaluatorHook.lastCheckedEvaluator(), address(governanceEvaluator));
        assertTrue(approvedEvaluatorHook.lastCheckedApproval());
    }

    function testApprovedEvaluatorHookSupportsGovernanceEvaluatorSettlement() external {
        approvedEvaluatorHook.setEvaluatorApproval(address(governanceEvaluator), true);

        uint256 jobId = _createJob(provider, address(0), address(approvedEvaluatorHook), 7 days);
        bytes memory evaluatorOptParams = abi.encode("vote://assignment", uint256(9));
        bytes32 deliverable = keccak256("deliverable:governance-policy");
        bytes32 attestation = keccak256("dao:policy-approved");
        bytes memory governanceOptParams = abi.encode("vote://proposal-approval", uint256(99));

        vm.prank(client);
        commerce.setEvaluator(jobId, address(governanceEvaluator), evaluatorOptParams);
        vm.prank(client);
        commerce.setBudget(jobId, BUDGET);
        vm.prank(client);
        commerce.fund(jobId, BUDGET);

        vm.prank(provider);
        commerce.submit(jobId, deliverable);

        uint256 proposalId = _createGovernanceDecisionProposal(jobId, true, attestation, governanceOptParams);
        _voteForAndExecuteProposal(proposalId);

        IPactCommerce.Job memory job = commerce.getJob(jobId);
        uint256 feeAmount = (BUDGET * PLATFORM_FEE_BPS) / 10_000;

        assertEq(uint8(job.status), uint8(IPactCommerce.Status.Completed));
        assertEq(job.evaluator, address(governanceEvaluator));
        assertEq(job.attestation, attestation);
        assertEq(usdc.balanceOf(provider), BUDGET - feeAmount);
        assertEq(usdc.balanceOf(treasury), feeAmount);
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

    function testDeterministicEvaluatorCompletesWhenOptParamsHashMatches() external {
        uint256 jobId = _createAndFundJob(provider, address(deterministicEvaluator), address(0), BUDGET, 7 days);
        bytes32 deliverable = keccak256("proof-commitment");
        bytes32 successAttestation = keccak256("zk-receipt");
        bytes32 failureAttestation = keccak256("invalid-proof");
        bytes memory evaluatorOptParams = abi.encode("receipt://bundle", uint256(88));

        deterministicEvaluator.setExpectationWithOptParamsHash(
            jobId, deliverable, successAttestation, failureAttestation, keccak256(evaluatorOptParams)
        );

        vm.prank(provider);
        commerce.submit(jobId, deliverable);

        deterministicEvaluator.evaluate(jobId, evaluatorOptParams);

        IPactCommerce.Job memory job = commerce.getJob(jobId);
        assertEq(uint8(job.status), uint8(IPactCommerce.Status.Completed));
        assertEq(job.attestation, successAttestation);
        (,,,,, bool configured) = deterministicEvaluator.expectations(jobId);
        assertFalse(configured);
    }

    function testDeterministicEvaluatorRejectsWhenOptParamsHashMismatches() external {
        uint256 jobId = _createAndFundJob(provider, address(deterministicEvaluator), address(0), BUDGET, 7 days);
        bytes32 deliverable = keccak256("proof-commitment");
        bytes32 successAttestation = keccak256("zk-receipt");
        bytes32 failureAttestation = keccak256("invalid-proof");
        bytes memory expectedOptParams = abi.encode("receipt://bundle", uint256(88));
        bytes memory wrongOptParams = abi.encode("receipt://bundle", uint256(99));

        deterministicEvaluator.setExpectationWithOptParamsHash(
            jobId, deliverable, successAttestation, failureAttestation, keccak256(expectedOptParams)
        );

        vm.prank(provider);
        commerce.submit(jobId, deliverable);

        deterministicEvaluator.evaluate(jobId, wrongOptParams);

        IPactCommerce.Job memory job = commerce.getJob(jobId);
        assertEq(uint8(job.status), uint8(IPactCommerce.Status.Rejected));
        assertEq(job.attestation, failureAttestation);
        assertEq(usdc.balanceOf(client), INITIAL_BALANCE);
        (,,,,, bool configured) = deterministicEvaluator.expectations(jobId);
        assertFalse(configured);
    }

    function testDeterministicEvaluatorClearsExpectationAfterEvaluation() external {
        uint256 jobId = _createAndFundJob(provider, address(deterministicEvaluator), address(0), BUDGET, 7 days);
        bytes32 deliverable = keccak256("proof-commitment");
        bytes32 successAttestation = keccak256("zk-receipt");
        bytes32 failureAttestation = keccak256("invalid-proof");

        deterministicEvaluator.setExpectation(jobId, deliverable, successAttestation, failureAttestation);

        vm.prank(provider);
        commerce.submit(jobId, deliverable);

        deterministicEvaluator.evaluate(jobId);

        vm.expectRevert(DeterministicReceiptEvaluator.ExpectationNotConfigured.selector);
        deterministicEvaluator.evaluate(jobId);
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

        deterministicEvaluator.setExpectationWithOptParamsHash(
            jobId, deliverable, successAttestation, failureAttestation, keccak256(evaluatorOptParams)
        );

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

        deterministicEvaluator.setExpectationWithOptParamsHash(
            jobId, expectedDeliverable, successAttestation, failureAttestation, keccak256(evaluatorOptParams)
        );

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

    function testRaiseDisputeEscrowsBondForCompletedJob() external {
        uint256 jobId = _createAndFundJob(provider, evaluator, address(0), BUDGET, 7 days);
        bytes32 deliverable = keccak256("deliverable:dispute-complete");
        bytes32 attestation = keccak256("attestation:approved");
        bytes32 subjectType = keccak256("settlement");
        bytes32 subjectRef = keccak256("receipt://1");
        bytes32 evidenceHash = keccak256("evidence://bundle");

        vm.prank(provider);
        commerce.submit(jobId, deliverable);
        vm.prank(evaluator);
        commerce.complete(jobId, attestation);

        vm.prank(outsider);
        uint256 disputeId = commerce.raiseDispute(jobId, subjectType, subjectRef, evidenceHash, DISPUTE_BOND);

        IPactCommerce.Dispute memory dispute = commerce.getDispute(disputeId);
        assertEq(dispute.jobId, jobId);
        assertEq(dispute.challenger, outsider);
        assertEq(dispute.subjectType, subjectType);
        assertEq(dispute.subjectRef, subjectRef);
        assertEq(dispute.evidenceHash, evidenceHash);
        assertEq(dispute.bondAmount, DISPUTE_BOND);
        assertEq(uint8(dispute.status), uint8(IPactCommerce.DisputeStatus.Open));
        assertEq(commerce.getDisputeForJob(jobId), disputeId);
        assertEq(usdc.balanceOf(address(commerce)), DISPUTE_BOND);
        assertEq(usdc.balanceOf(outsider), INITIAL_BALANCE - DISPUTE_BOND);
    }

    function testResolveDisputeUpheldReturnsBondToChallengerAndUpdatesResolution() external {
        uint256 jobId = _createAndFundJob(provider, evaluator, address(0), BUDGET, 7 days);
        bytes32 deliverable = keccak256("deliverable:upheld");
        bytes32 attestation = keccak256("attestation:approved");
        bytes32 resolution = keccak256("jury:override");

        vm.prank(provider);
        commerce.submit(jobId, deliverable);
        vm.prank(evaluator);
        commerce.complete(jobId, attestation);

        vm.prank(outsider);
        uint256 disputeId = commerce.raiseDispute(
            jobId, keccak256("settlement"), keccak256("receipt://2"), keccak256("evidence://jury"), DISPUTE_BOND
        );

        commerce.resolveDispute(disputeId, true, resolution);

        uint256 penaltyAmount = (DISPUTE_BOND * DISPUTE_UPHELD_PENALTY_BPS) / 10_000;
        uint256 expectedRefund = DISPUTE_BOND - penaltyAmount;
        uint256 expectedJury = penaltyAmount / 2;
        uint256 expectedProtocol = penaltyAmount - expectedJury;

        IPactCommerce.Dispute memory dispute = commerce.getDispute(disputeId);
        IPactCommerce.Job memory job = commerce.getJob(jobId);
        assertEq(uint8(dispute.status), uint8(IPactCommerce.DisputeStatus.Upheld));
        assertEq(dispute.resolution, resolution);
        assertEq(job.attestation, resolution);
        assertEq(usdc.balanceOf(outsider), INITIAL_BALANCE - DISPUTE_BOND + expectedRefund);
        assertEq(usdc.balanceOf(address(this)), expectedJury);
        assertEq(usdc.balanceOf(treasury), ((BUDGET * PLATFORM_FEE_BPS) / 10_000) + expectedProtocol);
        assertEq(usdc.balanceOf(address(commerce)), 0);
    }

    function testResolveDisputeRejectedPaysBondToOwner() external {
        uint256 jobId = _createAndFundJob(provider, evaluator, address(0), BUDGET, 7 days);
        bytes32 reason = keccak256("attestation:rejected");
        bytes32 resolution = keccak256("jury:bond-forfeited");

        vm.prank(evaluator);
        commerce.reject(jobId, reason);

        vm.prank(outsider);
        uint256 disputeId = commerce.raiseDispute(
            jobId, keccak256("rejection"), keccak256("decision://1"), keccak256("evidence://appeal"), DISPUTE_BOND
        );

        commerce.resolveDispute(disputeId, false, resolution);

        uint256 expectedJury = DISPUTE_BOND / 2;
        uint256 expectedProtocol = DISPUTE_BOND - expectedJury;

        IPactCommerce.Dispute memory dispute = commerce.getDispute(disputeId);
        assertEq(uint8(dispute.status), uint8(IPactCommerce.DisputeStatus.Rejected));
        assertEq(dispute.resolution, resolution);
        assertEq(usdc.balanceOf(address(this)), expectedJury);
        assertEq(usdc.balanceOf(treasury), expectedProtocol);
        assertEq(usdc.balanceOf(address(commerce)), 0);
    }

    function testRaiseDisputeRequiresTerminalJobAndExactBond() external {
        uint256 openJobId = _createJob(provider, evaluator, address(0), 7 days);

        vm.expectRevert(PactCommerce.InvalidStatus.selector);
        vm.prank(outsider);
        commerce.raiseDispute(
            openJobId, keccak256("premature"), keccak256("job://open"), keccak256("evidence://none"), DISPUTE_BOND
        );

        uint256 completedJobId = _createAndFundJob(provider, evaluator, address(0), BUDGET, 7 days);
        vm.prank(provider);
        commerce.submit(completedJobId, keccak256("deliverable:bond-check"));
        vm.prank(evaluator);
        commerce.complete(completedJobId, keccak256("attestation:bond-check"));

        vm.expectRevert(PactCommerce.InvalidDisputeBond.selector);
        vm.prank(outsider);
        commerce.raiseDispute(
            completedJobId,
            keccak256("settlement"),
            keccak256("receipt://3"),
            keccak256("evidence://wrong-bond"),
            DISPUTE_BOND - 1
        );
    }

    function testRaiseDisputeAllowsExpiredJobsButOnlyOnePerJob() external {
        uint256 jobId = _createAndFundJob(provider, evaluator, address(0), BUDGET, 1 days);

        vm.warp(block.timestamp + 1 days);
        vm.prank(outsider);
        commerce.claimRefund(jobId);

        vm.prank(client);
        uint256 disputeId = commerce.raiseDispute(
            jobId, keccak256("expiry"), keccak256("refund://1"), keccak256("evidence://expired"), DISPUTE_BOND
        );

        assertEq(commerce.getDisputeForJob(jobId), disputeId);

        vm.expectRevert(PactCommerce.DisputeAlreadyExists.selector);
        vm.prank(outsider);
        commerce.raiseDispute(
            jobId, keccak256("expiry"), keccak256("refund://2"), keccak256("evidence://duplicate"), DISPUTE_BOND
        );
    }

    function testGovernanceCanResolveDisputeAfterOwnershipTransfer() external {
        uint256 jobId = _createAndFundJob(provider, evaluator, address(0), BUDGET, 7 days);
        bytes32 deliverable = keccak256("deliverable:governance-dispute");
        bytes32 attestation = keccak256("attestation:approved");
        bytes32 resolution = keccak256("jury:governance-upheld");

        vm.prank(provider);
        commerce.submit(jobId, deliverable);
        vm.prank(evaluator);
        commerce.complete(jobId, attestation);

        vm.prank(outsider);
        uint256 disputeId = commerce.raiseDispute(
            jobId, keccak256("settlement"), keccak256("receipt://governance"), keccak256("evidence://dao"), DISPUTE_BOND
        );

        commerce.transferOwnership(address(governance));

        uint256 proposalId = _createGovernanceDisputeProposal(disputeId, true, resolution);
        _voteForAndExecuteProposal(proposalId);

        uint256 penaltyAmount = (DISPUTE_BOND * DISPUTE_UPHELD_PENALTY_BPS) / 10_000;
        uint256 expectedRefund = DISPUTE_BOND - penaltyAmount;
        uint256 expectedJury = penaltyAmount / 2;
        uint256 expectedProtocol = penaltyAmount - expectedJury;

        IPactCommerce.Dispute memory dispute = commerce.getDispute(disputeId);
        IPactCommerce.Job memory job = commerce.getJob(jobId);
        assertEq(uint8(dispute.status), uint8(IPactCommerce.DisputeStatus.Upheld));
        assertEq(dispute.resolution, resolution);
        assertEq(job.attestation, resolution);
        assertEq(usdc.balanceOf(outsider), INITIAL_BALANCE - DISPUTE_BOND + expectedRefund);
        assertEq(usdc.balanceOf(address(governance)), expectedJury);
        assertEq(usdc.balanceOf(treasury), ((BUDGET * PLATFORM_FEE_BPS) / 10_000) + expectedProtocol);
        assertEq(usdc.balanceOf(address(commerce)), 0);
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

    function _createGovernanceDisputeProposal(uint256 disputeId, bool upheld, bytes32 resolution)
        internal
        returns (uint256 proposalId)
    {
        vm.prank(voterA);
        proposalId = governance.createCommerceDisputeProposal(
            address(commerce), disputeId, upheld, resolution, "governance dispute resolution"
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
