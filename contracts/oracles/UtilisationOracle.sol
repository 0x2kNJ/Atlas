// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ICapitalPool {
    function getUtilizationBps() external view returns (uint256);
}

/// @title UtilisationOracle
/// @notice Chainlink AggregatorV3-compatible oracle that exposes a capital pool's
///         utilisation as a price feed, enabling Atlas Envelope conditions to
///         reference pool risk metrics directly.
///
/// The "answer" is the pool's current utilisation in basis points (0–10,000).
///
/// Example envelope condition (utilisation guard):
///   priceOracle   = address(utilisationOracle)
///   triggerPrice  = 9000   (90% utilisation)
///   op            = GTE    (ComparisonOp.GTE = 4)
///
/// When a keeper calls EnvelopeRegistry.trigger(), the registry reads this oracle
/// on-chain at trigger time. If utilisationBps >= 9000, the condition holds and
/// the PoolPauseAdapter fires — without any trusted party, multisig, or ops team.
///
/// updatedAt is always block.timestamp so the EnvelopeRegistry staleness check
/// (MAX_ORACLE_AGE = 3600) is always satisfied in the demo environment.

contract UtilisationOracle {
    /// @dev Dimensionless — utilisation is already in basis points (integer 0–10000).
    uint8 public constant decimals = 0;

    address public immutable capitalPool;

    constructor(address _capitalPool) {
        require(_capitalPool != address(0), "UtilisationOracle: zero pool");
        capitalPool = _capitalPool;
    }

    /// @notice Reads current pool utilisation and returns it as a Chainlink-style answer.
    /// @return roundId       Always 1 (not relevant for the demo).
    /// @return answer        Current utilisation in basis points (0–10000). Cast to int256.
    /// @return startedAt     block.timestamp
    /// @return updatedAt     block.timestamp (always fresh — no staleness in demo).
    /// @return answeredInRound Always 1.
    function latestRoundData() external view returns (
        uint80  roundId,
        int256  answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80  answeredInRound
    ) {
        uint256 bps = ICapitalPool(capitalPool).getUtilizationBps();
        return (1, int256(bps), block.timestamp, block.timestamp, 1);
    }
}
