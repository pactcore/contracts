// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {PactCommerce} from "../src/PactCommerce.sol";
import {DeterministicReceiptEvaluator} from "../src/evaluators/DeterministicReceiptEvaluator.sol";
import {ReputationGateHook} from "../src/hooks/ReputationGateHook.sol";
import {IPactCommerce} from "../src/interfaces/IPactCommerce.sol";
import {MockFailingCommerceHook} from "./mocks/MockFailingCommerceHook.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

contract PactCommerceTest is Test {
    MockUSDC private usdc;
    PactCommerce private commerce;
    ReputationGateHook private reputationHook;
    DeterministicReceiptEvaluator private deterministicEvaluator;

    address private client = makeAddr("client");
    address private provider = makeAddr("provider");
    address private evaluator = makeAddr("evaluator");
    address private treasury = makeAddr("treasury");
    address private outsider = makeAddr("outsider");

    uint256 private constant INITIAL_BALANCE = 20_000e6;
    uint256 private constant BUDGET = 1_000e6;
    uint16 private constant PLATFORM_FEE_BPS = 500;
    uint256 private constant MINIMUM_PROVIDER_SCORE = 80;

    function setUp() external {
        usdc = new MockUSDC();
        commerce = new PactCommerce(address(usdc), treasury, PLATFORM_FEE_BPS);
        reputationHook = new ReputationGateHook(address(commerce), MINIMUM_PROVIDER_SCORE);
        deterministicEvaluator = new DeterministicReceiptEvaluator(address(commerce));

        usdc.mint(client, INITIAL_BALANCE);
        vm.prank(client);
        usdc.approve(address(commerce), type(uint256).max);
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
}
