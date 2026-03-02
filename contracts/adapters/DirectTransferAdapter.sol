// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IAdapter} from "../interfaces/IAdapter.sol";

/// @title DirectTransferAdapter
/// @notice Atlas Protocol adapter for Dead Man's Switch scenarios.
///
/// Transfers the agent's vault position directly to a pre-committed beneficiary address
/// when a time-based condition fires. The beneficiary (e.g. a DAO multisig, a backup wallet,
/// or a smart contract) is encoded in the intent's adapterData and EIP-712 signed by the agent
/// at setup time — it cannot be changed without invalidating the agent's signature.
///
/// Flow:
///   1. Agent deposits treasury into vault.
///   2. Agent registers an envelope with this adapter and a time-based condition
///      (e.g. timestamp > lastHeartbeat + 24 hours).
///   3. Agent periodically "checks in" by cancelling the envelope and re-registering with
///      a fresh deadline. No check-in = Dead Man's Switch fires.
///   4. If condition fires, keeper calls registry.trigger() → kernel calls this adapter →
///      (amountIn - 1) USDC is transferred to the beneficiary.
///      1 unit of dust is returned to the kernel to satisfy the vault's non-zero deposit check.
///
/// adapterData encoding:
///   abi.encode(address beneficiary)
///
/// amountOut:
///   Always 1 (one unit of tokenIn returned to kernel as dust).
///   The intent must set minReturn = 1 and the capability must not enforce minReturnBps.
///
/// Security properties:
///   - Beneficiary is signed inside intent hash (EIP-712) — solver cannot redirect output.
///   - Agent cannot drain more than position.amount (capability constraint: maxSpendPerPeriod).
///   - Envelope expiry limits how long the failsafe remains armed.
contract DirectTransferAdapter is IAdapter {
    using SafeERC20 for IERC20;

    function name() external pure override returns (string memory) {
        return "DirectTransferAdapter";
    }

    function target() external pure override returns (address) {
        return address(0);
    }

    /// @notice Quote always returns 1 (dust amount returned to kernel).
    function quote(
        address,
        address,
        uint256,
        bytes calldata
    ) external pure override returns (uint256) {
        return 1;
    }

    /// @notice Validate that the adapter data encodes a non-zero beneficiary.
    function validate(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        bytes calldata data
    ) external pure override returns (bool valid, string memory reason) {
        if (tokenIn == address(0))  return (false, "tokenIn is zero address");
        if (tokenOut != tokenIn)    return (false, "tokenOut must equal tokenIn: same-token transfer");
        if (amountIn < 2)           return (false, "amountIn must be >= 2 to cover dust return");
        if (data.length < 32)       return (false, "adapterData too short: must encode beneficiary address");

        address beneficiary = abi.decode(data, (address));
        if (beneficiary == address(0)) return (false, "beneficiary is zero address");

        return (true, "");
    }

    /// @notice Transfer (amountIn - 1) to the beneficiary. Return 1 dust unit to kernel.
    ///
    /// @dev The kernel holds `amountIn` of `tokenIn` and has approved this adapter for that amount.
    ///      After the transfer, 1 unit is returned so the kernel can create a minimal vault position.
    function execute(
        address tokenIn,
        address,
        uint256 amountIn,
        uint256 minAmountOut,
        bytes calldata data
    ) external override returns (uint256 amountOut) {
        address beneficiary = abi.decode(data, (address));

        // Pull all funds from kernel into this adapter.
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        // Transfer (amountIn - 1) to the committed beneficiary.
        uint256 transferAmt = amountIn - 1;
        IERC20(tokenIn).safeTransfer(beneficiary, transferAmt);

        // Return 1 dust unit to the kernel so vault.depositFor does not revert with ZeroAmount.
        amountOut = 1;
        require(amountOut >= minAmountOut, "DirectTransferAdapter: min return not met");
        IERC20(tokenIn).safeTransfer(msg.sender, 1);
    }
}
