// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title MockClawloanPool
/// @notice Minimal Clawloan LendingPoolV2 mock for integration testing.
///
/// Models the key invariant of Clawloan's liquidation risk:
///   - borrow() issues USDC to the caller and records a debt.
///   - repay()  accepts USDC from the caller and reduces the debt.
///   - If repay() is never called, getDebt() remains > 0 — the loan is outstanding.
///
/// In the real LendingPoolV2, overdue loans are resolved by calling liquidate() which
/// drains the operator's wallet. The PoC demonstrates that Atlas Envelopes replace this
/// fragile operator-liveness dependency: the repayment fires permissionlessly via a keeper
/// when the time condition is met, regardless of whether the agent or operator is alive.

contract MockClawloanPool {
    using SafeERC20 for IERC20;

    IERC20 public immutable usdc;

    /// @notice Outstanding debt per bot ID. 0 = no active loan.
    mapping(uint256 botId => uint256 debt) public debt;

    event Borrowed(uint256 indexed botId, address indexed borrower, uint256 amount);
    event Repaid(uint256 indexed botId, address indexed repayer, uint256 amount);

    error InsufficientPoolBalance();
    error NoActiveLoan();
    error Overpayment(uint256 debt, uint256 repayAmount);
    error NoActiveLoanForAccrual();

    constructor(address _usdc) {
        usdc = IERC20(_usdc);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Core
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Borrow USDC against a registered bot identity.
    /// @dev In the real protocol this checks credit tier, permission limits, and rate limits.
    ///      Here we just record the debt and transfer USDC.
    function borrow(uint256 botId, uint256 amount) external {
        if (usdc.balanceOf(address(this)) < amount) revert InsufficientPoolBalance();
        debt[botId] += amount;
        usdc.safeTransfer(msg.sender, amount);
        emit Borrowed(botId, msg.sender, amount);
    }

    /// @notice Repay an outstanding loan.
    /// @dev Pulls USDC from msg.sender. In the real protocol this also:
    ///      - accrues interest before accepting repayment
    ///      - updates credit score on successful repayment
    ///      - releases permission capacity
    function repay(uint256 botId, uint256 amount) external {
        uint256 outstanding = debt[botId];
        if (outstanding == 0)      revert NoActiveLoan();
        if (amount > outstanding)  revert Overpayment(outstanding, amount);

        debt[botId] = outstanding - amount;
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        emit Repaid(botId, msg.sender, amount);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // View
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Simulate interest accrual. Adds `interestAmount` to the outstanding debt.
    ///         In the real protocol this happens automatically via a block-based rate model.
    ///         Here it is driven explicitly in tests.
    function accrueInterest(uint256 botId, uint256 interestAmount) external {
        if (debt[botId] == 0) revert NoActiveLoanForAccrual();
        debt[botId] += interestAmount;
    }

    function getDebt(uint256 botId) external view returns (uint256) {
        return debt[botId];
    }

    function isLoanOutstanding(uint256 botId) external view returns (bool) {
        return debt[botId] > 0;
    }
}
