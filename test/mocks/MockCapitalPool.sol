// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title MockCapitalPool
/// @notice Simulates the lender-side of Clawloan's LendingPoolV2.
///
/// Demonstrates the Atlas Capital Provider use case:
///   - Institutional lender deposits USDC into the pool and earns yield.
///   - Borrowers draw against credit-gated limits.
///   - An Atlas keeper can pause new borrows when utilization breaches the guard threshold.
///   - Repayments include an interest component that accrues as lender yield.
///
/// Yield model (simplified):
///   - Each repayment can include an interest amount (separate from principal).
///   - Interest is split: YIELD_TO_LENDER_BPS goes to lenders, remainder stays in pool.
///   - Lender yield is tracked proportionally to their share of total capital.

contract MockCapitalPool {
    using SafeERC20 for IERC20;

    IERC20 public immutable usdc;

    // ─── Lender state ──────────────────────────────────────────────────────────
    uint256 public totalCapital;          // total USDC deposited by all lenders
    uint256 public totalBorrowed;         // currently outstanding principal
    uint256 public totalYieldEarned;      // cumulative interest collected from repayments
    uint256 public yieldPerShareScaled;   // running yield-per-share (scaled by 1e18)
    bool    public borrowingPaused;       // set by keeper when utilization guard fires

    mapping(address => uint256) public lenderCapital;      // principal deposited
    mapping(address => uint256) public lenderYieldDebt;    // snapshot at deposit time
    mapping(address => uint256) public lenderYieldClaimed; // cumulative claimed

    // ─── Borrower state ────────────────────────────────────────────────────────
    mapping(uint256 => uint256) public botDebt;   // outstanding principal per bot ID
    mapping(uint256 => uint16)  public botTier;   // credit tier (1 or 2) per bot ID

    // ─── Tier credit limits ────────────────────────────────────────────────────
    mapping(uint16 => uint256) public tierLimit;  // max borrow per tier in USDC

    // ─── Utilization guard ─────────────────────────────────────────────────────
    uint256 public utilizationGuardBps = 9000;    // 90% — pause threshold
    address public keeper;                         // Atlas keeper address

    // ─── Constants ─────────────────────────────────────────────────────────────
    uint256 public constant YIELD_TO_LENDER_BPS = 8000; // 80% of interest to lenders
    uint256 public constant BPS_DENOM           = 10000;
    uint256 public constant SCALE               = 1e18;

    // ─── Events ────────────────────────────────────────────────────────────────
    event CapitalProvided(address indexed lender, uint256 amount, uint256 newTotal);
    event CapitalWithdrawn(address indexed lender, uint256 amount);
    event TierSet(uint256 indexed botId, uint16 tier);
    event Borrowed(uint256 indexed botId, address indexed borrower, uint256 amount);
    event Repaid(uint256 indexed botId, address indexed repayer, uint256 principal, uint256 interest);
    event YieldClaimed(address indexed lender, uint256 amount);
    event BorrowingPaused(address indexed by, uint256 utilization);
    event BorrowingResumed(address indexed by);
    event KeeperSet(address indexed newKeeper);
    event TierLimitSet(uint16 indexed tier, uint256 limit);
    event UtilizationGuardUpdated(uint256 newBps);

    // ─── Errors ────────────────────────────────────────────────────────────────
    error ZeroAmount();
    error InsufficientPoolLiquidity();
    error NoActiveLoan();
    error Overpayment(uint256 debt, uint256 amount);
    error BorrowingIsPaused();
    error UnauthorizedKeeper();
    error ExceedsCreditLimit(uint256 requested, uint256 limit);
    error NoCreditTier();
    error InsufficientLenderCapital();

    constructor(address _usdc) {
        usdc = IERC20(_usdc);
        // Default tier limits
        tierLimit[1] = 10_000e6;  // Tier 1: 10,000 USDC
        tierLimit[2] = 50_000e6;  // Tier 2: 50,000 USDC
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Admin / Setup
    // ─────────────────────────────────────────────────────────────────────────

    function setKeeper(address _keeper) external {
        keeper = _keeper;
        emit KeeperSet(_keeper);
    }

    function setTierLimit(uint16 tier, uint256 limit) external {
        tierLimit[tier] = limit;
        emit TierLimitSet(tier, limit);
    }

    function setUtilizationGuard(uint256 bps) external {
        utilizationGuardBps = bps;
        emit UtilizationGuardUpdated(bps);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Lender: provide capital
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Institutional lender deposits USDC into the pool and earns pro-rata yield.
    function provideCapital(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();

        // Settle any pending yield before updating share
        lenderYieldDebt[msg.sender] = yieldPerShareScaled;

        usdc.safeTransferFrom(msg.sender, address(this), amount);
        lenderCapital[msg.sender] += amount;
        totalCapital += amount;

        emit CapitalProvided(msg.sender, amount, totalCapital);
    }

    /// @notice Lender withdraws idle capital (only up to un-borrowed amount).
    function withdrawCapital(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        if (lenderCapital[msg.sender] < amount) revert InsufficientLenderCapital();

        uint256 idle = totalCapital - totalBorrowed;
        if (amount > idle) revert InsufficientPoolLiquidity();

        lenderCapital[msg.sender] -= amount;
        totalCapital -= amount;
        usdc.safeTransfer(msg.sender, amount);

        emit CapitalWithdrawn(msg.sender, amount);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Credit tier assignment (in production: driven by ZK proof verifier)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Assign a credit tier to a bot (in production, verified by CreditVerifier).
    function assignTier(uint256 botId, uint16 tier) external {
        botTier[botId] = tier;
        emit TierSet(botId, tier);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Borrower: draw and repay
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Borrow USDC against a credit-tier verified bot identity.
    function borrow(uint256 botId, uint256 amount) external {
        if (borrowingPaused) revert BorrowingIsPaused();
        if (amount == 0) revert ZeroAmount();

        uint16 tier = botTier[botId];
        if (tier == 0) revert NoCreditTier();

        uint256 limit = tierLimit[tier];
        uint256 newDebt = botDebt[botId] + amount;
        if (newDebt > limit) revert ExceedsCreditLimit(newDebt, limit);

        uint256 available = totalCapital - totalBorrowed;
        if (available < amount) revert InsufficientPoolLiquidity();

        botDebt[botId]  = newDebt;
        totalBorrowed   += amount;

        usdc.safeTransfer(msg.sender, amount);
        emit Borrowed(botId, msg.sender, amount);

        // Auto-check utilization guard after borrow
        if (_utilizationBps() >= utilizationGuardBps) {
            borrowingPaused = true;
            emit BorrowingPaused(msg.sender, _utilizationBps());
        }
    }

    /// @notice Repay principal + optional interest. Interest accrues as lender yield.
    /// @param principal  Original loan amount to repay.
    /// @param interest   Additional interest payment (yield for lenders).
    function repay(uint256 botId, uint256 principal, uint256 interest) external {
        uint256 outstanding = botDebt[botId];
        if (outstanding == 0) revert NoActiveLoan();
        if (principal > outstanding) revert Overpayment(outstanding, principal);

        uint256 total = principal + interest;
        usdc.safeTransferFrom(msg.sender, address(this), total);

        botDebt[botId]  = outstanding - principal;
        totalBorrowed   -= principal;

        // Distribute interest as yield to lenders (pro-rata by capital share)
        if (interest > 0 && totalCapital > 0) {
            uint256 lenderPortion = (interest * YIELD_TO_LENDER_BPS) / BPS_DENOM;
            totalYieldEarned += lenderPortion;
            yieldPerShareScaled += (lenderPortion * SCALE) / totalCapital;
        }

        emit Repaid(botId, msg.sender, principal, interest);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Lender: claim earned yield
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Claim accumulated yield proportional to lender's capital share.
    function claimYield() external {
        uint256 pending = pendingYield(msg.sender);
        if (pending == 0) return;

        lenderYieldDebt[msg.sender] = yieldPerShareScaled;
        lenderYieldClaimed[msg.sender] += pending;

        usdc.safeTransfer(msg.sender, pending);
        emit YieldClaimed(msg.sender, pending);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Atlas keeper: utilization guard
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Called by Atlas keeper when utilization guard envelope fires.
    ///         In production, this is triggered by a registered Atlas Envelope with
    ///         a utilization oracle condition, not by a trusted address.
    function pauseBorrowing() external {
        borrowingPaused = true;
        emit BorrowingPaused(msg.sender, _utilizationBps());
    }

    /// @notice Resume borrowing (governance / lender action).
    function resumeBorrowing() external {
        borrowingPaused = false;
        emit BorrowingResumed(msg.sender);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // View helpers
    // ─────────────────────────────────────────────────────────────────────────

    function getDebt(uint256 botId) external view returns (uint256) {
        return botDebt[botId];
    }

    function getUtilizationBps() external view returns (uint256) {
        return _utilizationBps();
    }

    function pendingYield(address lender) public view returns (uint256) {
        if (lenderCapital[lender] == 0) return 0;
        uint256 gain = yieldPerShareScaled - lenderYieldDebt[lender];
        return (lenderCapital[lender] * gain) / SCALE;
    }

    function getLenderStats(address lender) external view returns (
        uint256 capital,
        uint256 yieldPending,
        uint256 yieldClaimed,
        uint256 utilizationBps
    ) {
        return (
            lenderCapital[lender],
            pendingYield(lender),
            lenderYieldClaimed[lender],
            _utilizationBps()
        );
    }

    function getPoolStats() external view returns (
        uint256 poolTotalCapital,
        uint256 poolTotalBorrowed,
        uint256 poolAvailable,
        uint256 poolUtilizationBps,
        uint256 poolTotalYieldEarned,
        bool    poolBorrowingPaused
    ) {
        return (
            totalCapital,
            totalBorrowed,
            totalCapital - totalBorrowed,
            _utilizationBps(),
            totalYieldEarned,
            borrowingPaused
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Internal
    // ─────────────────────────────────────────────────────────────────────────

    function _utilizationBps() internal view returns (uint256) {
        if (totalCapital == 0) return 0;
        return (totalBorrowed * BPS_DENOM) / totalCapital;
    }
}
