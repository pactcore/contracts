// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IEvaluatorSettlementRecipient {
    function settlementRecipient() external view returns (address);
}
