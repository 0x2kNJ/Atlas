// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IAdapter} from "../interfaces/IAdapter.sol";

interface ICapitalPool {
    function pauseBorrowing() external;
}

/// @title PoolPauseAdapter
/// @notice Atlas Protocol adapter that pauses a capital pool when an envelope fires.
///
/// Integration pattern — Lender Utilisation Guard:
///   A lender registers an Atlas Envelope at capital deployment time:
///     Condition: utilisationOracle.answer >= triggerPrice  (e.g. 9000 = 90%)
///     Action:    execute this adapter → pool.pauseBorrowing()
///
///   When a keeper calls EnvelopeRegistry.trigger() and the utilisation condition
///   holds on-chain, the CapabilityKernel calls this adapter. The adapter:
///     1. Pulls the sentinel USDC from the kernel (lender's guard deposit).
///     2. Calls pool.pauseBorrowing() — the sole side effect.
///     3. Returns the sentinel USDC in full to the kernel (pass-through).
///
///   The lender's guard deposit (sentinel position) is returned intact as a new
///   vault position. No value is consumed — the adapter is "zero-cost" beyond gas.
///
/// Adapter data encoding:
///   abi.encode(address capitalPool)
///
/// Token model:
///   tokenIn == tokenOut (USDC sentinel, same-token pass-through).
///   minReturnBps should be 10000 (100%) — all value is returned.

contract PoolPauseAdapter is IAdapter {
    using SafeERC20 for IERC20;

    // ─────────────────────────────────────────────────────────────────────────
    // IAdapter: metadata
    // ─────────────────────────────────────────────────────────────────────────

    function name() external pure override returns (string memory) {
        return "PoolPauseAdapter";
    }

    /// @notice No fixed target — pool address is passed per-intent in adapterData.
    function target() external pure override returns (address) {
        return address(0);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // IAdapter: quote
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Full pass-through: amountOut == amountIn. No value consumed.
    function quote(
        address,
        address,
        uint256 amountIn,
        bytes calldata
    ) external pure override returns (uint256) {
        return amountIn;
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
        if (tokenIn  == address(0)) return (false, "tokenIn is zero address");
        if (tokenOut == address(0)) return (false, "tokenOut is zero address");
        if (tokenOut != tokenIn)    return (false, "tokenOut must equal tokenIn: sentinel pass-through");
        if (amountIn == 0)          return (false, "amountIn is zero");
        if (data.length < 32)       return (false, "adapterData too short: expected abi.encode(address)");
        address pool = abi.decode(data, (address));
        if (pool == address(0))     return (false, "capitalPool is zero address");
        return (true, "");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // IAdapter: execute
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Pause the pool and return the sentinel USDC to the kernel.
    ///
    /// Preconditions (enforced by CapabilityKernel before this call):
    ///   - msg.sender (kernel) holds `amountIn` of `tokenIn`.
    ///   - msg.sender has approved this adapter for `amountIn` of `tokenIn`.
    ///
    /// Postconditions:
    ///   - capitalPool.borrowingPaused == true.
    ///   - `amountIn` of USDC returned to kernel (sentinel position preserved).
    function execute(
        address tokenIn,
        address,
        uint256 amountIn,
        uint256 minAmountOut,
        bytes calldata data
    ) external override returns (uint256 amountOut) {
        address pool = abi.decode(data, (address));

        // Pull sentinel USDC from kernel.
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        // THE SIDE EFFECT: pause new borrows — this is what the envelope was for.
        ICapitalPool(pool).pauseBorrowing();

        // Return sentinel in full — no value consumed.
        amountOut = amountIn;
        require(amountOut >= minAmountOut, "PoolPauseAdapter: insufficient return");
        IERC20(tokenIn).safeTransfer(msg.sender, amountOut);
    }
}
