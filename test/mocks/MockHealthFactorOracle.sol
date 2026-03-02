// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title MockHealthFactorOracle
/// @notice Chainlink-compatible feed that returns a configurable health factor.
///
/// Used in the Clawloan compound condition PoC to model early-liquidation protection.
/// The health factor is expressed as a fixed-point integer scaled by 10_000:
///   10_000 = 1.0 (healthy)
///    9_000 = 0.9 (degraded)
///    5_000 = 0.5 (critically undercollateralised)
///
/// Condition setup (early liquidation trigger):
///   priceOracle  = address(healthOracle)
///   triggerPrice = 9_000               (threshold: health factor < 0.9)
///   op           = LESS_THAN
///
/// Combined with a time-based primary condition via OR:
///   Primary:   block.timestamp > loanDeadline   (time oracle)
///   Secondary: healthFactor    < 9_000          (health oracle)
///   logicOp:   OR
///
/// The envelope fires whichever condition is met first — protecting against both
/// missed deadlines AND early collateral degradation.

contract MockHealthFactorOracle {
    uint8 public constant decimals = 0; // health factor is a plain integer (10_000 = 1.0)

    int256 public healthFactor;

    event HealthFactorUpdated(int256 oldValue, int256 newValue);

    constructor(int256 initialHealthFactor) {
        healthFactor = initialHealthFactor;
    }

    /// @notice Set the health factor. Called in tests to simulate collateral degradation.
    function setHealthFactor(int256 newFactor) external {
        emit HealthFactorUpdated(healthFactor, newFactor);
        healthFactor = newFactor;
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
