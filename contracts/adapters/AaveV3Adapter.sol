// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IAdapter} from "../interfaces/IAdapter.sol";

/// @dev Aave V3 Pool interface (minimal).
interface IAavePool {
    /// @notice Supply `amount` of `asset` to the protocol on behalf of `onBehalfOf`.
    ///         Caller receives aToken in return, credited to `onBehalfOf`.
    function supply(
        address asset,
        uint256 amount,
        address onBehalfOf,
        uint16 referralCode
    ) external;

    /// @notice Withdraw `amount` of `asset` from the protocol.
    ///         Burns aTokens from `msg.sender`, sends underlying to `to`.
    /// @return The actual withdrawn amount.
    function withdraw(
        address asset,
        uint256 amount,
        address to
    ) external returns (uint256);
}

/// @dev Aave V3 aToken interface.
interface IAToken is IERC20 {
    function UNDERLYING_ASSET_ADDRESS() external view returns (address);
}

/// @dev Aave V3 Pool Addresses Provider.
interface IPoolAddressesProvider {
    function getPool() external view returns (address);
}

/// @title AaveV3Adapter
/// @notice Adapter for supplying and withdrawing from Aave V3 via the protocol's intent system.
///
/// Supported operations (encoded in `data` as `AaveOp`):
///
///   SUPPLY  — deposit underlying tokens into Aave, receive aTokens in output position.
///     tokenIn  = underlying (e.g. USDC)
///     tokenOut = corresponding aToken (e.g. aUSDC)
///     data     = abi.encode(AaveOp.SUPPLY)
///
///   WITHDRAW — redeem aTokens from Aave, receive underlying in output position.
///     tokenIn  = aToken (e.g. aUSDC)
///     tokenOut = corresponding underlying (e.g. USDC)
///     data     = abi.encode(AaveOp.WITHDRAW)
///
/// Execution model (same as UniswapV3Adapter):
///   1. Kernel approves this adapter for tokenIn.
///   2. Adapter pulls tokenIn from kernel via transferFrom.
///   3. Adapter interacts with Aave Pool.
///   4. Adapter sends tokenOut to kernel (msg.sender).
///   5. Returns actual amountOut.
///
/// Why SUPPLY maps cleanly:
///   Aave mints aTokens 1:1 with supplied underlying (initially).
///   supply() mints aUSDC directly to the recipient address we specify.
///   We supply on behalf of address(this), then transfer the received aTokens to kernel.
///
/// Why WITHDRAW maps cleanly:
///   Adapter holds aUSDC, calls withdraw() which burns aUSDC from adapter and sends USDC to kernel.

contract AaveV3Adapter is IAdapter {
    using SafeERC20 for IERC20;

    // ─────────────────────────────────────────────────────────────────────────
    // Types
    // ─────────────────────────────────────────────────────────────────────────

    enum AaveOp { SUPPLY, WITHDRAW }

    // ─────────────────────────────────────────────────────────────────────────
    // Immutables
    // ─────────────────────────────────────────────────────────────────────────

    IPoolAddressesProvider public immutable addressesProvider;

    // ─────────────────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────────────────

    constructor(address _addressesProvider) {
        addressesProvider = IPoolAddressesProvider(_addressesProvider);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // IAdapter: name / target
    // ─────────────────────────────────────────────────────────────────────────

    function name() external pure override returns (string memory) {
        return "AaveV3Adapter";
    }

    function target() external view override returns (address) {
        return addressesProvider.getPool();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // IAdapter: validate
    // ─────────────────────────────────────────────────────────────────────────

    function validate(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        bytes calldata data
    ) external view override returns (bool valid, string memory reason) {
        if (tokenIn == address(0))  return (false, "tokenIn is zero");
        if (tokenOut == address(0)) return (false, "tokenOut is zero");
        if (amountIn == 0)          return (false, "amountIn is zero");
        if (data.length != 32)      return (false, "data must be abi.encode(AaveOp)");

        AaveOp op = abi.decode(data, (AaveOp));

        if (op == AaveOp.SUPPLY) {
            // tokenOut must be the aToken for tokenIn.
            // We verify by checking the aToken's UNDERLYING_ASSET_ADDRESS.
            try IAToken(tokenOut).UNDERLYING_ASSET_ADDRESS() returns (address underlying) {
                if (underlying != tokenIn) {
                    return (false, "tokenOut is not the aToken for tokenIn");
                }
            } catch {
                return (false, "tokenOut does not implement UNDERLYING_ASSET_ADDRESS");
            }
        } else if (op == AaveOp.WITHDRAW) {
            // tokenIn must be the aToken for tokenOut.
            try IAToken(tokenIn).UNDERLYING_ASSET_ADDRESS() returns (address underlying) {
                if (underlying != tokenOut) {
                    return (false, "tokenIn is not the aToken for tokenOut");
                }
            } catch {
                return (false, "tokenIn does not implement UNDERLYING_ASSET_ADDRESS");
            }
        }

        return (true, "");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // IAdapter: quote
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice For Aave supply/withdraw, output is 1:1 with input (at time of call).
    ///         aToken exchange rate may drift slightly from 1:1 as interest accrues,
    ///         but for freshly deposited positions it is effectively 1:1.
    function quote(
        address,        // tokenIn
        address,        // tokenOut
        uint256 amountIn,
        bytes calldata  // data
    ) external pure override returns (uint256) {
        // 1:1 for supply and withdraw at current exchange rate.
        // The actual rate for aTokens is always >= 1:1 (interest bearing).
        return amountIn;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // IAdapter: execute
    // ─────────────────────────────────────────────────────────────────────────

    function execute(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        bytes calldata data
    ) external override returns (uint256 amountOut) {
        AaveOp op = abi.decode(data, (AaveOp));
        IAavePool pool = IAavePool(addressesProvider.getPool());

        // Pull tokenIn from kernel.
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        if (op == AaveOp.SUPPLY) {
            amountOut = _supply(pool, tokenIn, tokenOut, amountIn, msg.sender);
        } else {
            amountOut = _withdraw(pool, tokenIn, tokenOut, amountIn, msg.sender);
        }

        require(amountOut >= minAmountOut, "AaveV3Adapter: insufficient output");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Internal: supply
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Supply underlying to Aave, receive aTokens, send aTokens to kernel.
    /// @param tokenIn   Underlying asset (e.g. USDC).
    /// @param tokenOut  Corresponding aToken (e.g. aUSDC).
    /// @param amountIn  Amount of underlying to supply.
    /// @param kernel    msg.sender — aTokens are sent here.
    /// @return amountOut  aTokens received (measured via balance delta).
    function _supply(
        IAavePool pool,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address kernel
    ) internal returns (uint256 amountOut) {
        // Approve pool to pull underlying from adapter.
        IERC20(tokenIn).forceApprove(address(pool), amountIn);

        uint256 aTokenBefore = IERC20(tokenOut).balanceOf(address(this));

        // Supply on behalf of adapter — adapter receives aTokens.
        pool.supply(tokenIn, amountIn, address(this), 0);

        uint256 aTokenAfter = IERC20(tokenOut).balanceOf(address(this));
        amountOut = aTokenAfter - aTokenBefore;

        // Clear approval.
        IERC20(tokenIn).forceApprove(address(pool), 0);

        // Forward aTokens to kernel.
        IERC20(tokenOut).safeTransfer(kernel, amountOut);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Internal: withdraw
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Redeem aTokens from Aave, receive underlying, send underlying to kernel.
    /// @param tokenIn   aToken (e.g. aUSDC) — adapter now holds these.
    /// @param tokenOut  Underlying (e.g. USDC).
    /// @param amountIn  aToken amount to redeem (use type(uint256).max to redeem all).
    /// @param kernel    msg.sender — underlying is sent here.
    /// @return amountOut  Underlying received.
    function _withdraw(
        IAavePool pool,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address kernel
    ) internal returns (uint256 amountOut) {
        // Approve pool to burn aTokens from adapter.
        IERC20(tokenIn).forceApprove(address(pool), amountIn);

        // Withdraw sends tokenOut directly to `to` (kernel).
        // pool.withdraw returns the actual amount withdrawn.
        amountOut = pool.withdraw(tokenOut, amountIn, kernel);

        // Clear any residual approval.
        IERC20(tokenIn).forceApprove(address(pool), 0);
    }
}
