// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IAdapter} from "../interfaces/IAdapter.sol";

/// @dev Minimal Clawloan LendingPool interface — only what the adapter needs.
interface IClawloanPool {
    /// @notice Repay an outstanding loan on behalf of a registered bot.
    /// @param botId   ERC-721 token ID of the registered agent (from BotRegistry).
    /// @param amount  USDC amount to repay (principal + interest, 6 decimals).
    function repay(uint256 botId, uint256 amount) external;

    /// @notice Returns the current outstanding debt for a bot (principal + accrued interest).
    function getDebt(uint256 botId) external view returns (uint256);
}

/// @title ClawloanRepayAdapter
/// @notice Atlas Protocol adapter that repays a Clawloan loan from an agent's task earnings.
///
/// Integration pattern:
///   An agent borrows USDC from Clawloan, completes a task, and deposits its earnings
///   into the Atlas SingletonVault as a position. It then registers an Atlas Envelope:
///     - Position:  the task earnings commitment (>= loan debt)
///     - Condition: time-based deadline (loan must be repaid before Clawloan's 7-day limit)
///     - Intent:    execute this adapter, repaying the debt and keeping the surplus as profit
///
///   When the keeper triggers the envelope (on or before the loan deadline), this adapter:
///     1. Pulls the full earnings USDC from the CapabilityKernel.
///     2. Repays the loan debt to the Clawloan pool.
///     3. Returns the surplus (task profit) to the kernel — which commits it as a new
///        vault position owned by the agent.
///
///   The agent need not be alive at repayment time. The loan is always repaid as long as
///   the task earnings are in the vault and the envelope has not expired.
///
/// Adapter data encoding — two supported formats:
///
///   Static (legacy):  abi.encode(address clawloanPool, uint256 botId, uint256 debtAmount)
///   Live-debt:        abi.encode(address clawloanPool, uint256 botId, uint256 debtCap, bool useLiveDebt)
///
///   - clawloanPool:  LendingPoolV2 contract address on the target chain.
///   - botId:         Agent's BotRegistry ERC-721 token ID.
///   - debtAmount /   Static mode (useLiveDebt=false): exact amount to repay, baked in at
///     debtCap:         envelope creation time.  Safe only when the loan carries no interest.
///                    Live-debt mode (useLiveDebt=true): maximum debt the operator is willing
///                      to repay.  At trigger time, the adapter queries pool.getDebt(botId)
///                      and uses the live value.  Handles interest accrual correctly.
///                      Reverts if liveDebt > debtCap (protects operator from unexpected debt).
///   - useLiveDebt:   Optional bool (present only in the 128-byte encoding).  Absent = false.
///
/// tokenIn == tokenOut:
///   Both are USDC. The adapter performs a same-token split: actualDebt → pool, surplus → vault.
///
/// Surplus requirement:
///   The position amount MUST exceed the debt repaid (validate() enforces this at worst-case).
///   The surplus represents the agent's task profit.

contract ClawloanRepayAdapter is IAdapter {
    using SafeERC20 for IERC20;

    // ─────────────────────────────────────────────────────────────────────────
    // IAdapter: metadata
    // ─────────────────────────────────────────────────────────────────────────

    function name() external pure override returns (string memory) {
        return "ClawloanRepayAdapter";
    }

    /// @notice No fixed target — pool address is passed per-intent in adapterData.
    function target() external pure override returns (address) {
        return address(0);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Internal: decode adapter data (backward-compatible)
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Decodes both the legacy 96-byte encoding (3 fields) and the new 128-byte
    ///      encoding (4 fields with useLiveDebt bool).  Static dispatch on data.length.
    function _decodeData(bytes calldata data)
        internal pure
        returns (address pool, uint256 botId, uint256 debtParam, bool useLiveDebt)
    {
        if (data.length == 128) {
            (pool, botId, debtParam, useLiveDebt) =
                abi.decode(data, (address, uint256, uint256, bool));
        } else {
            (pool, botId, debtParam) = abi.decode(data, (address, uint256, uint256));
            useLiveDebt = false;
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // IAdapter: quote
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Returns the expected surplus.
    ///   Static mode:    surplus = amountIn - debtAmount  (exact, known at quote time).
    ///   Live-debt mode: surplus = amountIn - debtCap     (minimum; actual surplus ≥ this
    ///                     because liveDebt ≤ debtCap).
    function quote(
        address,
        address,
        uint256 amountIn,
        bytes calldata data
    ) external pure override returns (uint256 amountOut) {
        if (data.length == 0) return 0;
        (, , uint256 debtParam, ) = _decodeData(data);
        if (debtParam >= amountIn) return 0;
        return amountIn - debtParam;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // IAdapter: validate
    // ─────────────────────────────────────────────────────────────────────────

    function validate(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        bytes calldata data
    ) external pure override returns (bool valid, string memory reason) {
        if (tokenIn == address(0))  return (false, "tokenIn is zero address");
        if (tokenOut == address(0)) return (false, "tokenOut is zero address");
        if (tokenOut != tokenIn)    return (false, "tokenOut must equal tokenIn: same-token repayment");
        if (amountIn == 0)          return (false, "amountIn is zero");
        if (data.length == 0)       return (false, "adapterData is empty");

        (address pool, uint256 botId, uint256 debtParam, ) = _decodeData(data);

        if (pool == address(0)) return (false, "clawloanPool is zero address");
        if (botId == 0)         return (false, "botId is zero");
        if (debtParam == 0)     return (false, "debtAmount/debtCap is zero");

        // Worst-case surplus must be positive: amountIn must exceed debtParam.
        // In live-debt mode debtParam is the cap, so actual debt ≤ debtParam.
        if (debtParam >= amountIn)
            return (false, "debtAmount/debtCap must be less than position amount: no surplus");

        return (true, "");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // IAdapter: execute
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Repay a Clawloan loan and return the surplus to the kernel.
    ///
    /// Static mode (useLiveDebt=false):
    ///   Uses the pre-encoded debtAmount as the exact repayment. Suitable when the loan
    ///   carries no variable interest between envelope creation and trigger.
    ///
    /// Live-debt mode (useLiveDebt=true):
    ///   Queries pool.getDebt(botId) at execution time.  Handles interest accrual correctly.
    ///   Reverts if liveDebt > debtCap (operator protection against unexpected debt growth).
    ///
    /// Preconditions (enforced by CapabilityKernel before this call):
    ///   - msg.sender (kernel) holds `amountIn` of `tokenIn` (USDC).
    ///   - msg.sender has approved this adapter for `amountIn` of `tokenIn`.
    ///
    /// Postconditions:
    ///   - `actualDebt` of USDC has been transferred to the Clawloan pool via repay().
    ///   - `amountIn - actualDebt` (surplus) of USDC has been transferred to msg.sender.
    function execute(
        address tokenIn,
        address,            // tokenOut — same as tokenIn, unused
        uint256 amountIn,
        uint256 minAmountOut,
        bytes calldata data
    ) external override returns (uint256 amountOut) {
        (address pool, uint256 botId, uint256 debtParam, bool useLiveDebt) = _decodeData(data);

        // Determine the actual debt to repay.
        uint256 actualDebt;
        if (useLiveDebt) {
            actualDebt = IClawloanPool(pool).getDebt(botId);
            require(
                actualDebt <= debtParam,
                "ClawloanRepayAdapter: live debt exceeds cap"
            );
        } else {
            actualDebt = debtParam;
        }

        // Pull full earnings USDC from kernel.
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        // Approve Clawloan pool for the actual debt and repay.
        IERC20(tokenIn).forceApprove(pool, actualDebt);
        IClawloanPool(pool).repay(botId, actualDebt);
        IERC20(tokenIn).forceApprove(pool, 0);

        // Surplus = task profit — returned to kernel, becomes a new vault position.
        amountOut = amountIn - actualDebt;
        require(amountOut >= minAmountOut, "ClawloanRepayAdapter: insufficient surplus");

        IERC20(tokenIn).safeTransfer(msg.sender, amountOut);
    }
}
