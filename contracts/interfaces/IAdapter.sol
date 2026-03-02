// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IAdapter
/// @notice Interface all protocol adapters must implement.
///
/// Execution model:
///   - The CapabilityKernel holds tokenIn after releasing from the vault.
///   - The kernel approves the adapter for amountIn.
///   - The kernel calls adapter.execute(...).
///   - The adapter pulls tokenIn from the kernel via transferFrom.
///   - The adapter interacts with the target protocol (Uniswap, Aave, etc.).
///   - The adapter sends tokenOut back to the kernel (msg.sender).
///   - The kernel deposits tokenOut into the vault as a new position commitment.
///
/// Safety requirements for adapter implementors:
///   - Must enforce minAmountOut — revert if output is below this floor.
///   - Must return amountOut equal to the actual amount sent to msg.sender.
///   - Must not retain any tokens — all input consumed, all output forwarded.
///   - Must be stateless — no persistent storage between calls.
///   - Must validate parameters in validate() to match what execute() will enforce.

interface IAdapter {

    /// @notice Returns a human-readable name for this adapter.
    function name() external view returns (string memory);

    /// @notice Returns the address of the target protocol (e.g. Uniswap V3 Router).
    function target() external view returns (address);

    /// @notice Get the expected output amount for a given input.
    ///
    /// @dev Not marked as view — some adapters (e.g. UniswapV3 QuoterV2) simulate the swap
    ///      via an internal try/catch that technically modifies transient state.
    ///      Callers should use staticcall or off-chain simulation where possible.
    ///
    /// @param tokenIn   Input token address.
    /// @param tokenOut  Output token address.
    /// @param amountIn  Input amount.
    /// @param data      Adapter-specific encoded parameters (e.g. pool fee, path).
    /// @return amountOut  Expected output amount. May differ from actual due to price movement.
    function quote(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        bytes calldata data
    ) external returns (uint256 amountOut);

    /// @notice Validate parameters before execution — called by CapabilityKernel before executing.
    /// @dev Should check: supported token pairs, data encoding, parameter bounds.
    ///      Does not check live price — that is the role of intent.minReturn.
    /// @return valid   True if parameters are acceptable for execution.
    /// @return reason  Human-readable reason if invalid (empty string if valid).
    function validate(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        bytes calldata data
    ) external view returns (bool valid, string memory reason);

    /// @notice Execute the protocol interaction.
    ///
    /// Preconditions (enforced by CapabilityKernel before this call):
    ///   - msg.sender (kernel) holds `amountIn` of `tokenIn`.
    ///   - msg.sender has approved this adapter for `amountIn` of `tokenIn`.
    ///
    /// Postconditions (must be enforced by the adapter):
    ///   - All `amountIn` of `tokenIn` has been consumed.
    ///   - `amountOut >= minAmountOut` of `tokenOut` has been transferred to msg.sender.
    ///   - Returns the exact `amountOut` transferred to msg.sender.
    ///
    /// @param tokenIn       Input token.
    /// @param tokenOut      Output token.
    /// @param amountIn      Exact input amount to consume.
    /// @param minAmountOut  Minimum acceptable output — revert if not met.
    /// @param data          Adapter-specific encoded parameters.
    /// @return amountOut    Actual output amount transferred to msg.sender.
    function execute(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        bytes calldata data
    ) external returns (uint256 amountOut);
}
