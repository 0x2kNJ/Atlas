// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IAdapter} from "../interfaces/IAdapter.sol";

/// @dev Minimal Uniswap V3 SwapRouter interface.
interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24  fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    struct ExactInputParams {
        bytes   path;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    function exactInputSingle(ExactInputSingleParams calldata params)
        external returns (uint256 amountOut);

    function exactInput(ExactInputParams calldata params)
        external returns (uint256 amountOut);
}

/// @dev Minimal Uniswap V3 Quoter interface for off-chain quoting.
interface IQuoterV2 {
    function quoteExactInputSingle(
        address tokenIn,
        address tokenOut,
        uint24  fee,
        uint256 amountIn,
        uint160 sqrtPriceLimitX96
    ) external returns (
        uint256 amountOut,
        uint160 sqrtPriceX96After,
        uint32  initializedTicksCrossed,
        uint256 gasEstimate
    );
}

/// @title UniswapV3Adapter
/// @notice Adapter for executing exact-input swaps through the Uniswap V3 SwapRouter.
///
/// Two execution modes (determined by the `data` parameter encoding):
///   - Single-hop: encode as (uint24 fee)                          → exactInputSingle
///   - Multi-hop:  encode as (bytes path, bool isMultiHop=true)    → exactInput
///
/// The adapter:
///   1. Pulls tokenIn from msg.sender (CapabilityKernel) via transferFrom.
///   2. Approves the Uniswap router for amountIn.
///   3. Calls exactInputSingle or exactInput with recipient = msg.sender (kernel).
///   4. Returns the actual amountOut.
///
/// The kernel receives tokenOut directly from Uniswap — no intermediate transfer.

contract UniswapV3Adapter is IAdapter {
    using SafeERC20 for IERC20;

    // ─────────────────────────────────────────────────────────────────────────
    // Immutables
    // ─────────────────────────────────────────────────────────────────────────

    ISwapRouter public immutable router;
    IQuoterV2   public immutable quoter;

    /// @notice Execution deadline offset from block.timestamp (seconds).
    uint256 public constant DEADLINE_BUFFER = 60;

    // ─────────────────────────────────────────────────────────────────────────
    // Data encoding helpers
    //
    // Single-hop:  abi.encode(uint24 fee)
    // Multi-hop:   abi.encode(bytes path, bool isMultiHop) where isMultiHop == true
    // ─────────────────────────────────────────────────────────────────────────

    constructor(address _router, address _quoter) {
        router = ISwapRouter(_router);
        quoter = IQuoterV2(_quoter);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // IAdapter: name / target
    // ─────────────────────────────────────────────────────────────────────────

    function name() external pure override returns (string memory) {
        return "UniswapV3Adapter";
    }

    function target() external view override returns (address) {
        return address(router);
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
        if (tokenIn == tokenOut)    return (false, "tokenIn == tokenOut");
        if (amountIn == 0)          return (false, "amountIn is zero");
        if (data.length == 0)       return (false, "data is empty");

        // Try to decode as single-hop (uint24 fee)
        if (data.length == 32) {
            uint24 fee = abi.decode(data, (uint24));
            if (fee == 0) return (false, "fee is zero");
            if (fee > 1_000_000) return (false, "fee exceeds 100%");
            return (true, "");
        }

        // Try to decode as multi-hop (bytes path, bool isMultiHop)
        if (data.length > 32) {
            (bytes memory path, bool isMultiHop) = abi.decode(data, (bytes, bool));
            if (!isMultiHop) return (false, "multi-hop data must set isMultiHop=true");
            if (path.length < 43) return (false, "path too short"); // min: addr(20) + fee(3) + addr(20)
            return (true, "");
        }

        return (false, "unrecognised data encoding");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // IAdapter: quote
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Off-chain quote via QuoterV2. Simulates the swap without state changes.
    /// @dev QuoterV2.quoteExactInputSingle is a view function in V2 (uses state overrides).
    ///      Only supports single-hop quotes; multi-hop quotes require off-chain path construction.
    function quote(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        bytes calldata data
    ) external override returns (uint256 amountOut) {
        if (data.length == 32) {
            uint24 fee = abi.decode(data, (uint24));
            (amountOut,,,) = quoter.quoteExactInputSingle(tokenIn, tokenOut, fee, amountIn, 0);
        } else {
            revert("multi-hop quote not supported on-chain - use off-chain quoter");
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // IAdapter: execute
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Execute a swap through Uniswap V3.
    /// @dev msg.sender must have approved this contract for amountIn of tokenIn.
    ///      Output (tokenOut) is sent directly to msg.sender (CapabilityKernel) by Uniswap.
    function execute(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        bytes calldata data
    ) external override returns (uint256 amountOut) {
        // Pull tokenIn from kernel.
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        // Approve router for exactly amountIn.
        IERC20(tokenIn).forceApprove(address(router), amountIn);

        uint256 deadline = block.timestamp + DEADLINE_BUFFER;

        if (data.length == 32) {
            // Single-hop swap.
            uint24 fee = abi.decode(data, (uint24));

            amountOut = router.exactInputSingle(
                ISwapRouter.ExactInputSingleParams({
                    tokenIn:           tokenIn,
                    tokenOut:          tokenOut,
                    fee:               fee,
                    recipient:         msg.sender,  // kernel receives tokenOut directly
                    deadline:          deadline,
                    amountIn:          amountIn,
                    amountOutMinimum:  minAmountOut,
                    sqrtPriceLimitX96: 0
                })
            );
        } else {
            // Multi-hop swap.
            (bytes memory path,) = abi.decode(data, (bytes, bool));

            amountOut = router.exactInput(
                ISwapRouter.ExactInputParams({
                    path:             path,
                    recipient:        msg.sender,  // kernel receives tokenOut directly
                    deadline:         deadline,
                    amountIn:         amountIn,
                    amountOutMinimum: minAmountOut
                })
            );
        }

        // Clear any residual approval.
        IERC20(tokenIn).forceApprove(address(router), 0);

        // Enforce minimum output (Uniswap also checks but we double-enforce).
        require(amountOut >= minAmountOut, "UniswapV3Adapter: insufficient output");
    }
}
