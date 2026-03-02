// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Chainlink-compatible price feed mock.
contract MockOracle {
    int256  public answer;
    uint256 public updatedAt;
    uint8   public decimals;

    constructor(int256 _answer, uint8 _decimals) {
        answer    = _answer;
        updatedAt = block.timestamp;
        decimals  = _decimals;
    }

    function setAnswer(int256 _answer) external { answer = _answer; }
    function setUpdatedAt(uint256 _ts) external  { updatedAt = _ts; }

    function latestRoundData() external view returns (
        uint80 roundId,
        int256 answer_,
        uint256 startedAt,
        uint256 updatedAt_,
        uint80 answeredInRound
    ) {
        return (1, answer, block.timestamp, updatedAt, 1);
    }
}
