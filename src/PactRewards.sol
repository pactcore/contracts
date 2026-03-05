// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

contract PactRewards is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable rewardToken;

    mapping(address participant => uint256 amount) private rewardBalances;
    mapping(uint256 epochId => bool) public epochDistributed;

    uint256 public totalPendingRewards;

    event RewardAccrued(uint256 indexed epochId, address indexed participant, uint256 amount, bool isValidator);
    event EpochRewardsDistributed(uint256 indexed epochId, uint256 validatorCount, uint256 workerCount, uint256 totalAmount);
    event RewardsClaimed(address indexed participant, uint256 amount);

    error ZeroAddress();
    error InvalidAmount();
    error LengthMismatch();
    error EpochAlreadyDistributed();
    error NothingToClaim();

    constructor(address rewardTokenAddress) Ownable(msg.sender) {
        if (rewardTokenAddress == address(0)) revert ZeroAddress();
        rewardToken = IERC20(rewardTokenAddress);
    }

    function distributeEpochRewards(
        uint256 epochId,
        address[] calldata validators,
        uint256[] calldata validatorRewards,
        address[] calldata workers,
        uint256[] calldata workerRewards
    ) external onlyOwner nonReentrant {
        if (epochDistributed[epochId]) revert EpochAlreadyDistributed();
        if (validators.length != validatorRewards.length || workers.length != workerRewards.length) revert LengthMismatch();

        uint256 validatorsTotal = _accrue(epochId, validators, validatorRewards, true);
        uint256 workersTotal = _accrue(epochId, workers, workerRewards, false);
        uint256 totalAmount = validatorsTotal + workersTotal;
        if (totalAmount == 0) revert InvalidAmount();

        epochDistributed[epochId] = true;
        totalPendingRewards += totalAmount;

        rewardToken.safeTransferFrom(msg.sender, address(this), totalAmount);
        emit EpochRewardsDistributed(epochId, validators.length, workers.length, totalAmount);
    }

    function claimRewards() external nonReentrant {
        uint256 amount = rewardBalances[msg.sender];
        if (amount == 0) revert NothingToClaim();

        rewardBalances[msg.sender] = 0;
        totalPendingRewards -= amount;
        rewardToken.safeTransfer(msg.sender, amount);

        emit RewardsClaimed(msg.sender, amount);
    }

    function getRewardBalance(address participant) external view returns (uint256) {
        return rewardBalances[participant];
    }

    function _accrue(uint256 epochId, address[] calldata participants, uint256[] calldata amounts, bool isValidator)
        internal
        returns (uint256 totalAmount)
    {
        uint256 length = participants.length;
        for (uint256 i = 0; i < length; i++) {
            address participant = participants[i];
            uint256 amount = amounts[i];

            if (participant == address(0)) revert ZeroAddress();
            if (amount == 0) revert InvalidAmount();

            rewardBalances[participant] += amount;
            totalAmount += amount;

            emit RewardAccrued(epochId, participant, amount, isValidator);
        }
    }
}
