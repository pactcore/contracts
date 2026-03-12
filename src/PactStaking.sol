// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

contract PactStaking is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint16 private constant BPS_DENOMINATOR = 10_000;

    IERC20 public immutable usdc;
    address public immutable juryTreasury;
    address public immutable protocolTreasury;
    uint16 public immutable upheldPenaltyBps;

    struct Stake {
        address challenger;
        uint256 amount;
        bool resolved;
        bool upheld;
    }

    mapping(uint256 challengeId => Stake) private stakes;

    event StakePosted(uint256 indexed challengeId, address indexed challenger, uint256 amount);
    event StakeResolved(
        uint256 indexed challengeId, bool upheld, uint256 refundAmount, uint256 juryAmount, uint256 protocolAmount
    );

    error ZeroAddress();
    error InvalidAmount();
    error InvalidPenalty();
    error StakeAlreadyExists();
    error StakeNotFound();
    error StakeAlreadyResolved();

    constructor(address usdcAddress, address juryTreasuryAddress, address protocolTreasuryAddress, uint16 penaltyBps)
        Ownable(msg.sender)
    {
        if (usdcAddress == address(0) || juryTreasuryAddress == address(0) || protocolTreasuryAddress == address(0)) {
            revert ZeroAddress();
        }
        if (penaltyBps > BPS_DENOMINATOR) revert InvalidPenalty();

        usdc = IERC20(usdcAddress);
        juryTreasury = juryTreasuryAddress;
        protocolTreasury = protocolTreasuryAddress;
        upheldPenaltyBps = penaltyBps;
    }

    function postStake(uint256 challengeId, uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidAmount();

        Stake storage stake = stakes[challengeId];
        if (stake.amount != 0) revert StakeAlreadyExists();

        stake.challenger = msg.sender;
        stake.amount = amount;

        usdc.safeTransferFrom(msg.sender, address(this), amount);
        emit StakePosted(challengeId, msg.sender, amount);
    }

    function resolveStake(uint256 challengeId, bool upheld) external onlyOwner nonReentrant {
        Stake storage stake = stakes[challengeId];
        if (stake.amount == 0) revert StakeNotFound();
        if (stake.resolved) revert StakeAlreadyResolved();

        stake.resolved = true;
        stake.upheld = upheld;

        uint256 refundAmount;
        uint256 juryAmount;
        uint256 protocolAmount;

        if (upheld) {
            uint256 penalty = (stake.amount * upheldPenaltyBps) / BPS_DENOMINATOR;
            refundAmount = stake.amount - penalty;
            juryAmount = penalty / 2;
            protocolAmount = penalty - juryAmount;

            if (refundAmount > 0) usdc.safeTransfer(stake.challenger, refundAmount);
            if (juryAmount > 0) usdc.safeTransfer(juryTreasury, juryAmount);
            if (protocolAmount > 0) usdc.safeTransfer(protocolTreasury, protocolAmount);
        } else {
            juryAmount = stake.amount / 2;
            protocolAmount = stake.amount - juryAmount;
            usdc.safeTransfer(juryTreasury, juryAmount);
            usdc.safeTransfer(protocolTreasury, protocolAmount);
        }

        emit StakeResolved(challengeId, upheld, refundAmount, juryAmount, protocolAmount);
    }

    function getStake(uint256 challengeId) external view returns (Stake memory) {
        return stakes[challengeId];
    }
}
