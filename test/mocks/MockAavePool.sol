// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title MockAavePool
/// @notice Minimal Aave-like lending pool that tracks per-user debt for the
///         Atlas protocol liquidation engine demo.
///
/// Context:
///   In the demo, a user opens an "Aave position" by recording collateral and debt
///   in this contract. When the health factor (from MockHealthOracle) drops below
///   the liquidation threshold, an Atlas envelope fires the LiquidationAdapter,
///   which calls repayNoTransfer() here to clear the debt record.
///
///   This contract does NOT hold any tokens — all assets live in the Atlas vault.
///   It exists purely as a debt ledger that the adapter updates after settling.
///
/// Usage in the demo:
///   1. UI calls openPosition(user, debtAmount) to record a loan.
///   2. MockHealthOracle is pushed below 1.05e8.
///   3. Atlas LiquidationAdapter is triggered.
///   4. Adapter calls repayNoTransfer(user, amount) to mark debt as settled.
contract MockAavePool {

    struct Position {
        uint256 collateralUsdc;  // USDC collateral value (6 dec)
        uint256 debtUsdc;        // outstanding USDC debt (6 dec)
        bool    active;
    }

    mapping(address => Position) public positions;

    event PositionOpened(address indexed user, uint256 collateral, uint256 debt);
    event DebtRepaid(address indexed user, uint256 amount, uint256 remaining);

    /// @notice Record a new position for a user. Overwrites any existing record.
    function openPosition(address user, uint256 collateralUsdc, uint256 debtUsdc) external {
        positions[user] = Position({
            collateralUsdc: collateralUsdc,
            debtUsdc:       debtUsdc,
            active:         true
        });
        emit PositionOpened(user, collateralUsdc, debtUsdc);
    }

    /// @notice Returns the outstanding debt for a user (6-decimal USDC).
    function getDebt(address user) external view returns (uint256) {
        return positions[user].debtUsdc;
    }

    /// @notice Returns the full position for a user.
    function getPosition(address user) external view returns (Position memory) {
        return positions[user];
    }

    /// @notice Mark debt as repaid without a token transfer (tokens go directly to adapter).
    ///         Called by LiquidationAdapter after liquidation to update the debt ledger.
    function repayNoTransfer(address user, uint256 amount) external {
        Position storage pos = positions[user];
        require(pos.active, "MockAavePool: no active position");
        uint256 remaining = pos.debtUsdc >= amount ? pos.debtUsdc - amount : 0;
        pos.debtUsdc = remaining;
        if (remaining == 0) pos.active = false;
        emit DebtRepaid(user, amount, remaining);
    }
}
