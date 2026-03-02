// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title MockHealthOracle
/// @notice Chainlink-compatible feed that returns a settable health factor.
///
/// Used in the Atlas protocol liquidation demo to simulate position health degradation.
///
/// Health factor encoding (8 decimals):
///   2.0e8  = 200000000  → Healthy (2.0x collateralisation)
///   1.1e8  = 110000000  → Warning zone
///   1.05e8 = 105000000  → Liquidation threshold
///   0.99e8 =  99000000  → Underwater — envelope triggers
///
/// Condition setup for a liquidation envelope:
///   triggerPrice = 1_05e6  (1.05 in 8-decimal format = 105000000)
///   op           = LESS_THAN
///
/// The envelope fires when healthFactor < 1.05 — i.e., when the position should
/// be liquidated before it becomes undercollateralised.
contract MockHealthOracle {
    uint8 public constant decimals = 8;

    int256  public healthFactor;
    address public owner;

    event HealthFactorSet(int256 indexed newHealthFactor);

    constructor() {
        healthFactor = 2_00e6; // 2.0 initial health factor (200000000)
        owner = msg.sender;
    }

    /// @notice Set the current health factor. Only callable by owner.
    function setHealthFactor(int256 _hf) external {
        require(msg.sender == owner, "MockHealthOracle: not owner");
        healthFactor = _hf;
        emit HealthFactorSet(_hf);
    }

    function latestRoundData() external view returns (
        uint80  roundId,
        int256  answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80  answeredInRound
    ) {
        return (1, healthFactor, block.timestamp, block.timestamp, 1);
    }
}
