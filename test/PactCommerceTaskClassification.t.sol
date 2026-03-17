// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {PactCommerce} from "../src/PactCommerce.sol";
import {IPactCommerce} from "../src/interfaces/IPactCommerce.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

contract PactCommerceTaskClassificationTest is Test {
    MockUSDC private usdc;
    PactCommerce private commerce;

    address private client = makeAddr("client");
    address private provider = makeAddr("provider");
    address private evaluator = makeAddr("evaluator");
    address private treasury = makeAddr("treasury");

    uint16 private constant PLATFORM_FEE_BPS = 500;
    uint256 private expiry;

    function setUp() public {
        usdc = new MockUSDC();
        commerce = new PactCommerce(address(usdc), treasury, PLATFORM_FEE_BPS);
        expiry = block.timestamp + 7 days;
    }

    function test_createJobWithTaskType_Physical() public {
        vm.prank(client);
        uint256 jobId = commerce.createJob(
            provider, evaluator, expiry, "physical task", address(0), IPactCommerce.TaskType.Physical
        );

        IPactCommerce.TaskType taskType = commerce.getJobTaskType(jobId);
        assertEq(uint8(taskType), uint8(IPactCommerce.TaskType.Physical));
    }

    function test_createJobWithTaskType_Digital() public {
        vm.prank(client);
        uint256 jobId =
            commerce.createJob(provider, evaluator, expiry, "digital task", address(0), IPactCommerce.TaskType.Digital);

        IPactCommerce.TaskType taskType = commerce.getJobTaskType(jobId);
        assertEq(uint8(taskType), uint8(IPactCommerce.TaskType.Digital));
    }

    function test_createJobWithTaskType_Verification() public {
        vm.prank(client);
        uint256 jobId = commerce.createJob(
            provider, evaluator, expiry, "verification task", address(0), IPactCommerce.TaskType.Verification
        );

        IPactCommerce.TaskType taskType = commerce.getJobTaskType(jobId);
        assertEq(uint8(taskType), uint8(IPactCommerce.TaskType.Verification));
    }

    function test_createJobWithTaskType_Micro() public {
        vm.prank(client);
        uint256 jobId =
            commerce.createJob(provider, evaluator, expiry, "micro task", address(0), IPactCommerce.TaskType.Micro);

        IPactCommerce.TaskType taskType = commerce.getJobTaskType(jobId);
        assertEq(uint8(taskType), uint8(IPactCommerce.TaskType.Micro));
    }

    function test_defaultOverloads_defaultToDigital() public {
        // 4-arg overload
        vm.prank(client);
        uint256 jobId1 = commerce.createJob(provider, evaluator, expiry, "legacy 4-arg");
        assertEq(uint8(commerce.getJobTaskType(jobId1)), uint8(IPactCommerce.TaskType.Digital));

        // 5-arg overload
        vm.prank(client);
        uint256 jobId2 = commerce.createJob(provider, evaluator, expiry, "legacy 5-arg", address(0));
        assertEq(uint8(commerce.getJobTaskType(jobId2)), uint8(IPactCommerce.TaskType.Digital));
    }

    function test_getJob_returnsTaskType() public {
        vm.prank(client);
        uint256 jobId =
            commerce.createJob(provider, evaluator, expiry, "typed job", address(0), IPactCommerce.TaskType.Micro);

        IPactCommerce.Job memory job = commerce.getJob(jobId);
        assertEq(uint8(job.taskType), uint8(IPactCommerce.TaskType.Micro));
    }

    function test_JobCreatedEvent_includesTaskType() public {
        vm.prank(client);
        vm.expectEmit(true, true, true, true);
        emit PactCommerce.JobCreated(
            1, client, provider, evaluator, expiry, address(0), "with type", IPactCommerce.TaskType.Physical
        );
        commerce.createJob(provider, evaluator, expiry, "with type", address(0), IPactCommerce.TaskType.Physical);
    }

    function test_JobCreatedEvent_defaultOverload_emitsDigital() public {
        vm.prank(client);
        vm.expectEmit(true, true, true, true);
        emit PactCommerce.JobCreated(
            1, client, provider, evaluator, expiry, address(0), "default type", IPactCommerce.TaskType.Digital
        );
        commerce.createJob(provider, evaluator, expiry, "default type");
    }
}
