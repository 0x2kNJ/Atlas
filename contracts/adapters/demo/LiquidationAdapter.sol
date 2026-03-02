// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IAdapter} from "../../interfaces/IAdapter.sol";

interface IMockAavePool {
    function repayNoTransfer(address user, uint256 amount) external;
    function getDebt(address user) external view returns (uint256);
}

/// @title LiquidationAdapter
/// @notice Atlas Protocol adapter for DeFi protocol liquidation engines.
///
/// Demonstrates how Aave (or any lending protocol) can use Atlas envelopes as a
/// shared liquidation infrastructure instead of maintaining a proprietary keeper network.
///
/// Flow:
///   1. User has collateral (USDC) in the Atlas vault and outstanding debt in MockAavePool.
///   2. User (or protocol) registers an Atlas envelope:
///        - Condition: health factor < 1.05 (from MockHealthOracle)
///        - Adapter:   LiquidationAdapter
///   3. Health factor degrades (price drop, interest accrual).
///   4. Any Atlas keeper triggers the envelope.
///   5. This adapter:
///        a. Pulls amountIn (total collateral USDC) from the kernel.
///        b. Sends debtAmount to MockAavePool as debt settlement.
///        c. Applies a 5% liquidation bonus (returned to the keeper network incentive pool).
///        d. Returns remaining collateral to the kernel → new vault position for the user.
///        e. Calls pool.repayNoTransfer() to clear the debt record.
///
/// adapterData encoding:
///   abi.encode(address aavePool, address user, uint256 debtAmount)
///
/// Economics:
///   - debtAmount:     USDC owed to the protocol
///   - liquidatorBonus: 5% of debtAmount (simulates Aave's 5% bonus to liquidators)
///   - userReturn:     amountIn - debtAmount - liquidatorBonus (remaining collateral)
///
/// Security properties:
///   - user address is encoded in EIP-712 intent hash — cannot be redirected.
///   - minReturn in intent protects the user from excessive liquidation penalties.
///   - debtAmount is baked in at envelope creation — bounded by capability maxSpendPerPeriod.
contract LiquidationAdapter is IAdapter {
    using SafeERC20 for IERC20;

    uint256 public constant LIQUIDATION_BONUS_BPS = 500; // 5% bonus to keeper incentive pool

    function name() external pure override returns (string memory) {
        return "LiquidationAdapter";
    }

    function target() external pure override returns (address) {
        return address(0);
    }

    function quote(
        address,
        address,
        uint256 amountIn,
        bytes calldata data
    ) external pure override returns (uint256) {
        if (data.length < 96) return 0;
        (, , uint256 debtAmount) = abi.decode(data, (address, address, uint256));
        uint256 bonus = (debtAmount * LIQUIDATION_BONUS_BPS) / 10_000;
        uint256 total = debtAmount + bonus;
        return amountIn > total ? amountIn - total : 0;
    }

    function validate(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        bytes calldata data
    ) external pure override returns (bool valid, string memory reason) {
        if (tokenIn  == address(0))   return (false, "tokenIn is zero address");
        if (tokenOut != tokenIn)      return (false, "tokenOut must equal tokenIn: same-token liquidation");
        if (amountIn == 0)            return (false, "amountIn is zero");
        if (data.length < 96)         return (false, "adapterData too short: must encode (pool, user, debtAmount)");

        (address pool, address user, uint256 debtAmount) = abi.decode(data, (address, address, uint256));
        if (pool == address(0))       return (false, "aavePool is zero address");
        if (user == address(0))       return (false, "user is zero address");
        if (debtAmount == 0)          return (false, "debtAmount is zero");

        uint256 bonus = (debtAmount * LIQUIDATION_BONUS_BPS) / 10_000;
        uint256 total = debtAmount + bonus;
        if (amountIn <= total)        return (false, "collateral insufficient to cover debt + bonus");

        return (true, "");
    }

    function execute(
        address tokenIn,
        address,
        uint256 amountIn,
        uint256 minAmountOut,
        bytes calldata data
    ) external override returns (uint256 amountOut) {
        (address pool, address user, uint256 debtAmount) = abi.decode(data, (address, address, uint256));

        // Pull collateral USDC from kernel.
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        // Calculate liquidation bonus (5% of debt — goes to Atlas keeper incentive pool).
        uint256 bonus = (debtAmount * LIQUIDATION_BONUS_BPS) / 10_000;

        // Transfer debtAmount + bonus to the pool as settlement.
        // In production: pool.repay() with token transfer. Here we transfer and call separately.
        uint256 poolPayment = debtAmount + bonus;
        IERC20(tokenIn).safeTransfer(pool, poolPayment);

        // Update debt record in the pool (no re-transfer needed — pool received tokens above).
        IMockAavePool(pool).repayNoTransfer(user, debtAmount);

        // Return remaining collateral to kernel → vault commits new position for the user.
        amountOut = amountIn - poolPayment;
        require(amountOut >= minAmountOut, "LiquidationAdapter: remaining collateral below minReturn");

        IERC20(tokenIn).safeTransfer(msg.sender, amountOut);
    }
}
