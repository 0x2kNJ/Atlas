// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title MockPriceOracle
/// @notice Chainlink-compatible price feed whose answer is settable by the owner.
///
/// Used in the Atlas stop-loss and liquidation demos to simulate:
///   - ETH/USD price drops (triggering stop-loss envelopes)
///   - Health-factor degradation (triggering liquidation envelopes)
///
/// Condition setup (stop-loss example):
///   triggerPrice = 1800e8  (18 USD per ETH scaled to 8 decimals)
///   op           = LESS_THAN
///
/// The envelope fires when ETH/USD < $1,800 — i.e., when the position should be
/// closed to protect against further drawdown.
///
/// updatedAt is always block.timestamp so the EnvelopeRegistry staleness check
/// (MAX_ORACLE_AGE = 3600) is always satisfied.
contract MockPriceOracle {
    uint8 public constant decimals = 8;

    int256  public price;
    address public owner;

    event PriceSet(int256 indexed newPrice);

    constructor() {
        price = 2500e8; // $2,500 initial ETH/USD price
        owner = msg.sender;
    }

    /// @notice Set a new price. Only callable by owner.
    function setPrice(int256 _price) external {
        require(msg.sender == owner, "MockPriceOracle: not owner");
        price = _price;
        emit PriceSet(_price);
    }

    function latestRoundData() external view returns (
        uint80  roundId,
        int256  answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80  answeredInRound
    ) {
        return (1, price, block.timestamp, block.timestamp, 1);
    }
}
