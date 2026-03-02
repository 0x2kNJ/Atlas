// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title MockTimestampOracle
/// @notice Chainlink-compatible feed that returns block.timestamp as its answer.
///
/// Used in the Clawloan PoC to model time-based envelope conditions without requiring
/// a real time oracle. The price returned is block.timestamp (as an int256 with 0 decimals).
///
/// Condition setup:
///   triggerPrice = loanDeadline (as a uint256 timestamp)
///   op           = GREATER_THAN
///
/// The envelope fires when block.timestamp > loanDeadline — i.e., when the loan has
/// passed its repayment window and must be settled before Clawloan can liquidate the operator.
///
/// updatedAt is always block.timestamp, so the EnvelopeRegistry staleness check
/// (MAX_ORACLE_AGE = 3600) is always satisfied.

contract MockTimestampOracle {
    uint8 public constant decimals = 0;

    function latestRoundData() external view returns (
        uint80  roundId,
        int256  answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80  answeredInRound
    ) {
        return (
            1,
            int256(block.timestamp),
            block.timestamp,
            block.timestamp,
            1
        );
    }
}
