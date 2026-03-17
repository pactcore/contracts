// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PactDifferentialPrivacy} from "../src/PactDifferentialPrivacy.sol";
import {IPactDifferentialPrivacy} from "../src/interfaces/IPactDifferentialPrivacy.sol";

contract PactDifferentialPrivacyTest is Test {
    PactDifferentialPrivacy public dp;

    address owner = address(this);
    address datasetOwner = address(0xA1);
    address querier1 = address(0xB1);
    address querier2 = address(0xB2);

    uint256 constant SCALE = 1e18;

    function setUp() public {
        dp = new PactDifferentialPrivacy();
    }

    // ─── Dataset Registration ──────────────────────────────

    function test_registerDataset() public {
        vm.prank(datasetOwner);
        uint256 id = dp.registerDataset(10 * SCALE);
        assertEq(id, 1);

        IPactDifferentialPrivacy.DatasetConfig memory ds = dp.getDataset(id);
        assertEq(ds.maxBudget, 10 * SCALE);
        assertEq(ds.usedBudget, 0);
        assertEq(ds.queryCount, 0);
        assertEq(ds.owner, datasetOwner);
        assertTrue(ds.active);
    }

    function test_registerMultipleDatasets() public {
        vm.startPrank(datasetOwner);
        uint256 id1 = dp.registerDataset(5 * SCALE);
        uint256 id2 = dp.registerDataset(10 * SCALE);
        vm.stopPrank();

        assertEq(id1, 1);
        assertEq(id2, 2);
        assertEq(dp.getNextDatasetId(), 3);
    }

    function test_registerDataset_zeroBudget_reverts() public {
        vm.prank(datasetOwner);
        vm.expectRevert(IPactDifferentialPrivacy.InvalidBudget.selector);
        dp.registerDataset(0);
    }

    // ─── Dataset Deactivation ──────────────────────────────

    function test_deactivateDataset_byOwner() public {
        vm.prank(datasetOwner);
        uint256 id = dp.registerDataset(10 * SCALE);

        vm.prank(datasetOwner);
        dp.deactivateDataset(id);

        assertFalse(dp.getDataset(id).active);
    }

    function test_deactivateDataset_byContractOwner() public {
        vm.prank(datasetOwner);
        uint256 id = dp.registerDataset(10 * SCALE);

        dp.deactivateDataset(id); // called by test contract (owner)
        assertFalse(dp.getDataset(id).active);
    }

    function test_deactivateDataset_unauthorized_reverts() public {
        vm.prank(datasetOwner);
        uint256 id = dp.registerDataset(10 * SCALE);

        vm.prank(querier1);
        vm.expectRevert(IPactDifferentialPrivacy.Unauthorized.selector);
        dp.deactivateDataset(id);
    }

    function test_deactivateDataset_notFound_reverts() public {
        vm.expectRevert(IPactDifferentialPrivacy.DatasetNotFound.selector);
        dp.deactivateDataset(999);
    }

    // ─── Budget Update ─────────────────────────────────────

    function test_updateBudget() public {
        vm.startPrank(datasetOwner);
        uint256 id = dp.registerDataset(10 * SCALE);
        dp.updateBudget(id, 20 * SCALE);
        vm.stopPrank();

        assertEq(dp.getDataset(id).maxBudget, 20 * SCALE);
    }

    function test_updateBudget_belowUsed_reverts() public {
        vm.startPrank(datasetOwner);
        uint256 id = dp.registerDataset(10 * SCALE);

        // Record a query consuming 5 epsilon
        dp.recordQuery(id, querier1, 5 * SCALE, IPactDifferentialPrivacy.Mechanism.Laplace);

        // Try to set budget below used
        vm.expectRevert(IPactDifferentialPrivacy.InvalidBudget.selector);
        dp.updateBudget(id, 4 * SCALE);
        vm.stopPrank();
    }

    function test_updateBudget_unauthorized_reverts() public {
        vm.prank(datasetOwner);
        uint256 id = dp.registerDataset(10 * SCALE);

        vm.prank(querier1);
        vm.expectRevert(IPactDifferentialPrivacy.Unauthorized.selector);
        dp.updateBudget(id, 20 * SCALE);
    }

    // ─── Query Recording ───────────────────────────────────

    function test_recordQuery_laplace() public {
        vm.startPrank(datasetOwner);
        uint256 id = dp.registerDataset(10 * SCALE);
        dp.recordQuery(id, querier1, 1 * SCALE, IPactDifferentialPrivacy.Mechanism.Laplace);
        vm.stopPrank();

        IPactDifferentialPrivacy.DatasetConfig memory ds = dp.getDataset(id);
        assertEq(ds.usedBudget, 1 * SCALE);
        assertEq(ds.queryCount, 1);
        assertEq(dp.remainingBudget(id), 9 * SCALE);
    }

    function test_recordQuery_gaussian() public {
        vm.startPrank(datasetOwner);
        uint256 id = dp.registerDataset(10 * SCALE);
        dp.recordQuery(id, querier1, 2 * SCALE, IPactDifferentialPrivacy.Mechanism.Gaussian);
        vm.stopPrank();

        assertEq(dp.getDataset(id).usedBudget, 2 * SCALE);
    }

    function test_recordQuery_exponential() public {
        vm.startPrank(datasetOwner);
        uint256 id = dp.registerDataset(10 * SCALE);
        dp.recordQuery(id, querier1, 3 * SCALE, IPactDifferentialPrivacy.Mechanism.Exponential);
        vm.stopPrank();

        assertEq(dp.getDataset(id).usedBudget, 3 * SCALE);
    }

    function test_recordQuery_multipleQueries_composition() public {
        vm.startPrank(datasetOwner);
        uint256 id = dp.registerDataset(10 * SCALE);

        dp.recordQuery(id, querier1, 2 * SCALE, IPactDifferentialPrivacy.Mechanism.Laplace);
        dp.recordQuery(id, querier2, 3 * SCALE, IPactDifferentialPrivacy.Mechanism.Gaussian);
        dp.recordQuery(id, querier1, 1 * SCALE, IPactDifferentialPrivacy.Mechanism.Exponential);
        vm.stopPrank();

        IPactDifferentialPrivacy.DatasetConfig memory ds = dp.getDataset(id);
        assertEq(ds.usedBudget, 6 * SCALE);
        assertEq(ds.queryCount, 3);
        assertEq(dp.remainingBudget(id), 4 * SCALE);

        // Verify composition theorem
        assertEq(dp.computeComposition(id), 6 * SCALE);
    }

    function test_recordQuery_budgetExceeded_reverts() public {
        vm.startPrank(datasetOwner);
        uint256 id = dp.registerDataset(5 * SCALE);

        dp.recordQuery(id, querier1, 3 * SCALE, IPactDifferentialPrivacy.Mechanism.Laplace);

        vm.expectRevert(abi.encodeWithSelector(IPactDifferentialPrivacy.BudgetExceeded.selector, 3 * SCALE, 2 * SCALE));
        dp.recordQuery(id, querier1, 3 * SCALE, IPactDifferentialPrivacy.Mechanism.Laplace);
        vm.stopPrank();
    }

    function test_recordQuery_exactBudget_emitsBudgetExhausted() public {
        vm.startPrank(datasetOwner);
        uint256 id = dp.registerDataset(5 * SCALE);

        dp.recordQuery(id, querier1, 5 * SCALE, IPactDifferentialPrivacy.Mechanism.Laplace);
        vm.stopPrank();

        assertEq(dp.remainingBudget(id), 0);
    }

    function test_recordQuery_zeroEpsilon_reverts() public {
        vm.startPrank(datasetOwner);
        uint256 id = dp.registerDataset(10 * SCALE);

        vm.expectRevert(IPactDifferentialPrivacy.InvalidEpsilon.selector);
        dp.recordQuery(id, querier1, 0, IPactDifferentialPrivacy.Mechanism.Laplace);
        vm.stopPrank();
    }

    function test_recordQuery_zeroQuerier_reverts() public {
        vm.startPrank(datasetOwner);
        uint256 id = dp.registerDataset(10 * SCALE);

        vm.expectRevert(IPactDifferentialPrivacy.ZeroAddress.selector);
        dp.recordQuery(id, address(0), 1 * SCALE, IPactDifferentialPrivacy.Mechanism.Laplace);
        vm.stopPrank();
    }

    function test_recordQuery_inactiveDataset_reverts() public {
        vm.startPrank(datasetOwner);
        uint256 id = dp.registerDataset(10 * SCALE);
        dp.deactivateDataset(id);

        vm.expectRevert(IPactDifferentialPrivacy.DatasetInactive.selector);
        dp.recordQuery(id, querier1, 1 * SCALE, IPactDifferentialPrivacy.Mechanism.Laplace);
        vm.stopPrank();
    }

    function test_recordQuery_unauthorized_reverts() public {
        vm.prank(datasetOwner);
        uint256 id = dp.registerDataset(10 * SCALE);

        vm.prank(querier1);
        vm.expectRevert(IPactDifferentialPrivacy.Unauthorized.selector);
        dp.recordQuery(id, querier1, 1 * SCALE, IPactDifferentialPrivacy.Mechanism.Laplace);
    }

    function test_recordQuery_contractOwnerCanRecord() public {
        vm.prank(datasetOwner);
        uint256 id = dp.registerDataset(10 * SCALE);

        // Contract owner (this) should be able to record
        dp.recordQuery(id, querier1, 1 * SCALE, IPactDifferentialPrivacy.Mechanism.Laplace);
        assertEq(dp.getDataset(id).usedBudget, 1 * SCALE);
    }

    // ─── Query History ─────────────────────────────────────

    function test_queryHistory() public {
        vm.startPrank(datasetOwner);
        uint256 id = dp.registerDataset(10 * SCALE);

        dp.recordQuery(id, querier1, 1 * SCALE, IPactDifferentialPrivacy.Mechanism.Laplace);
        dp.recordQuery(id, querier2, 2 * SCALE, IPactDifferentialPrivacy.Mechanism.Gaussian);
        vm.stopPrank();

        IPactDifferentialPrivacy.QueryRecord[] memory history = dp.getQueryHistory(id);
        assertEq(history.length, 2);

        assertEq(history[0].querier, querier1);
        assertEq(history[0].epsilon, 1 * SCALE);
        assertTrue(history[0].mechanism == IPactDifferentialPrivacy.Mechanism.Laplace);

        assertEq(history[1].querier, querier2);
        assertEq(history[1].epsilon, 2 * SCALE);
        assertTrue(history[1].mechanism == IPactDifferentialPrivacy.Mechanism.Gaussian);
    }

    // ─── Per-Querier Budget ────────────────────────────────

    function test_querierUsedBudget() public {
        vm.startPrank(datasetOwner);
        uint256 id = dp.registerDataset(10 * SCALE);

        dp.recordQuery(id, querier1, 2 * SCALE, IPactDifferentialPrivacy.Mechanism.Laplace);
        dp.recordQuery(id, querier1, 3 * SCALE, IPactDifferentialPrivacy.Mechanism.Gaussian);
        dp.recordQuery(id, querier2, 1 * SCALE, IPactDifferentialPrivacy.Mechanism.Exponential);
        vm.stopPrank();

        assertEq(dp.querierUsedBudget(id, querier1), 5 * SCALE);
        assertEq(dp.querierUsedBudget(id, querier2), 1 * SCALE);
    }

    // ─── View Edge Cases ───────────────────────────────────

    function test_remainingBudget_notFound_reverts() public {
        vm.expectRevert(IPactDifferentialPrivacy.DatasetNotFound.selector);
        dp.remainingBudget(999);
    }

    function test_getQueryCount() public {
        vm.startPrank(datasetOwner);
        uint256 id = dp.registerDataset(10 * SCALE);
        assertEq(dp.getQueryCount(id), 0);

        dp.recordQuery(id, querier1, 1 * SCALE, IPactDifferentialPrivacy.Mechanism.Laplace);
        assertEq(dp.getQueryCount(id), 1);
        vm.stopPrank();
    }

    function test_getQueryCount_notFound_reverts() public {
        vm.expectRevert(IPactDifferentialPrivacy.DatasetNotFound.selector);
        dp.getQueryCount(999);
    }

    // ─── Composition Theorem Integrity ─────────────────────

    function test_compositionMatchesUsedBudget() public {
        vm.startPrank(datasetOwner);
        uint256 id = dp.registerDataset(100 * SCALE);

        uint256[5] memory epsilons = [uint256(1), 3, 2, 5, 4];
        uint256 expectedTotal = 0;

        for (uint256 i = 0; i < 5; i++) {
            dp.recordQuery(id, querier1, epsilons[i] * SCALE, IPactDifferentialPrivacy.Mechanism.Laplace);
            expectedTotal += epsilons[i] * SCALE;
        }
        vm.stopPrank();

        assertEq(dp.computeComposition(id), expectedTotal);
        assertEq(dp.getDataset(id).usedBudget, expectedTotal);
        assertEq(dp.computeComposition(id), dp.getDataset(id).usedBudget);
    }

    // ─── Fuzz Tests ────────────────────────────────────────

    function testFuzz_recordQuery_budgetEnforcement(uint256 budget, uint256 epsilon) public {
        budget = bound(budget, 1, 1000 * SCALE);
        epsilon = bound(epsilon, 1, budget); // ensure epsilon fits

        vm.startPrank(datasetOwner);
        uint256 id = dp.registerDataset(budget);
        dp.recordQuery(id, querier1, epsilon, IPactDifferentialPrivacy.Mechanism.Laplace);
        vm.stopPrank();

        assertEq(dp.getDataset(id).usedBudget, epsilon);
        assertEq(dp.remainingBudget(id), budget - epsilon);
    }

    function testFuzz_registerDataset(uint256 budget) public {
        budget = bound(budget, 1, type(uint128).max);

        vm.prank(datasetOwner);
        uint256 id = dp.registerDataset(budget);

        assertEq(dp.getDataset(id).maxBudget, budget);
        assertTrue(dp.getDataset(id).active);
    }
}
