// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {UniswapV3Adapter} from "../../contracts/adapters/UniswapV3Adapter.sol";

/// @title UniswapV3Adapter Fork Tests
/// @notice Tests the adapter against a live Arbitrum mainnet fork.
///
/// Skipped automatically if ARBITRUM_RPC_URL env var is not set.
///
/// To run:
///   ARBITRUM_RPC_URL=<your-url> forge test --match-path "test/fork/UniswapV3*" -v
///
/// Pinned block: 295_000_000 (~Feb 2025, Arbitrum Mainnet).
/// If you hit stale state errors, bump FORK_BLOCK to a more recent value.

contract UniswapV3AdapterForkTest is Test {

    // ─────────────────────────────────────────────────────────────────────────
    // Arbitrum mainnet addresses (pinned, well-tested)
    // ─────────────────────────────────────────────────────────────────────────

    uint256 constant FORK_BLOCK  = 295_000_000;

    // Uniswap V3 on Arbitrum (same as mainnet deployments)
    address constant SWAP_ROUTER = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45; // SwapRouter02
    address constant QUOTER_V2   = 0x61fFE014bA17989E743c5F6cB21bF9697530B21e;

    // Tokens
    address constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831; // native USDC, 6 dec
    address constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1; // WETH, 18 dec
    address constant USDT = 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9; // USDT,  6 dec

    // Fee tiers
    uint24 constant FEE_500  = 500;   // 0.05% — highest USDC/WETH liquidity
    uint24 constant FEE_3000 = 3000;  // 0.30%

    // ─────────────────────────────────────────────────────────────────────────
    // State
    // ─────────────────────────────────────────────────────────────────────────

    UniswapV3Adapter adapter;
    address          kernel;  // simulated kernel — the test contract acts as the kernel

    uint256 forkId;

    // ─────────────────────────────────────────────────────────────────────────
    // Setup
    // ─────────────────────────────────────────────────────────────────────────

    function setUp() public {
        string memory rpcUrl = vm.envOr("ARBITRUM_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) {
            vm.skip(true);
            return;
        }

        forkId = vm.createSelectFork(rpcUrl, FORK_BLOCK);

        adapter = new UniswapV3Adapter(SWAP_ROUTER, QUOTER_V2);
        kernel  = address(this); // test contract plays the role of the kernel

        // Fund the kernel with USDC and WETH for testing.
        deal(USDC, kernel, 100_000e6);   // 100k USDC
        deal(WETH, kernel,     100e18);  // 100 WETH
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Approve the adapter and execute a single-hop swap.
    function _swapSingle(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut,
        uint24  fee
    ) internal returns (uint256 amountOut) {
        IERC20(tokenIn).approve(address(adapter), amountIn);
        amountOut = adapter.execute(
            tokenIn,
            tokenOut,
            amountIn,
            minOut,
            abi.encode(fee)
        );
    }

    /// @dev Build a multi-hop Uniswap V3 path: tokenA → (feeAB) → tokenB → (feeBC) → tokenC.
    function _encodePath(
        address tokenA,
        uint24  feeAB,
        address tokenB,
        uint24  feeBC,
        address tokenC
    ) internal pure returns (bytes memory) {
        return abi.encodePacked(tokenA, feeAB, tokenB, feeBC, tokenC);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Single-hop: USDC → WETH
    // ─────────────────────────────────────────────────────────────────────────

    function test_fork_singleHop_usdc_to_weth() public {
        uint256 amountIn  = 1_000e6;  // 1000 USDC
        uint256 usdcBefore = IERC20(USDC).balanceOf(kernel);
        uint256 wethBefore = IERC20(WETH).balanceOf(kernel);

        // Accept anything > 0 — we're testing routing works, not checking price.
        uint256 amountOut = _swapSingle(USDC, WETH, amountIn, 1, FEE_500);

        assertGt(amountOut, 0, "amountOut is zero");
        assertEq(IERC20(USDC).balanceOf(kernel), usdcBefore - amountIn, "USDC not deducted");
        assertEq(IERC20(WETH).balanceOf(kernel), wethBefore + amountOut, "WETH not received");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Single-hop: WETH → USDC
    // ─────────────────────────────────────────────────────────────────────────

    function test_fork_singleHop_weth_to_usdc() public {
        uint256 amountIn   = 1e18;   // 1 WETH
        uint256 wethBefore = IERC20(WETH).balanceOf(kernel);
        uint256 usdcBefore = IERC20(USDC).balanceOf(kernel);

        uint256 amountOut = _swapSingle(WETH, USDC, amountIn, 1, FEE_500);

        assertGt(amountOut, 0, "amountOut is zero");
        assertEq(IERC20(WETH).balanceOf(kernel), wethBefore - amountIn, "WETH not deducted");
        assertEq(IERC20(USDC).balanceOf(kernel), usdcBefore + amountOut, "USDC not received");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Single-hop: output plausible (rough sanity — don't assume exact price)
    // ─────────────────────────────────────────────────────────────────────────

    function test_fork_singleHop_outputInReasonableRange() public {
        // At any reasonable ETH price ($500–$10000), 1 WETH → USDC should give > $500.
        uint256 amountOut = _swapSingle(WETH, USDC, 1e18, 500e6, FEE_500);
        assertGe(amountOut, 500e6, "output suspiciously low (<$500 per ETH)");
        // And not more than $100k (sanity upper bound).
        assertLe(amountOut, 100_000e6, "output suspiciously high (>$100k per ETH)");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Multi-hop: USDC → WETH → USDT
    // ─────────────────────────────────────────────────────────────────────────

    function test_fork_multiHop_usdc_to_usdt_via_weth() public {
        uint256 amountIn   = 1_000e6; // 1000 USDC
        uint256 usdcBefore = IERC20(USDC).balanceOf(kernel);
        uint256 usdtBefore = IERC20(USDT).balanceOf(kernel);

        // Build multi-hop path: USDC → (500) → WETH → (500) → USDT
        bytes memory path     = _encodePath(USDC, FEE_500, WETH, FEE_500, USDT);
        bytes memory adapterData = abi.encode(path, true); // isMultiHop = true

        IERC20(USDC).approve(address(adapter), amountIn);
        uint256 amountOut = adapter.execute(USDC, USDT, amountIn, 1, adapterData);

        assertGt(amountOut, 0, "amountOut is zero");
        assertEq(IERC20(USDC).balanceOf(kernel), usdcBefore - amountIn, "USDC not deducted");
        assertEq(IERC20(USDT).balanceOf(kernel), usdtBefore + amountOut, "USDT not received");

        // 1000 USDC → ~1000 USDT (stablecoin-to-stablecoin, allow 2% slippage through WETH).
        assertGe(amountOut, 970e6, "multi-hop stablecoin output too low");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Quote: single-hop off-chain simulation
    // ─────────────────────────────────────────────────────────────────────────

    function test_fork_quote_singleHop_usdc_to_weth() public {
        uint256 amountIn  = 1_000e6;
        uint256 quotedOut = adapter.quote(USDC, WETH, amountIn, abi.encode(FEE_500));

        assertGt(quotedOut, 0, "quote returned zero");

        // Quote should be close to execution (within 1% for a stable block).
        uint256 actualOut = _swapSingle(USDC, WETH, amountIn, 1, FEE_500);
        uint256 diff = quotedOut > actualOut ? quotedOut - actualOut : actualOut - quotedOut;
        assertLe(diff, (quotedOut * 100) / 10_000, "quote vs execution delta > 1%");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // No leftover approvals after execution
    // ─────────────────────────────────────────────────────────────────────────

    function test_fork_noResidualApproval_afterSwap() public {
        _swapSingle(USDC, WETH, 1_000e6, 1, FEE_500);

        // After execution, the adapter must have zero allowance on the router for tokenIn.
        uint256 residual = IERC20(USDC).allowance(address(adapter), SWAP_ROUTER);
        assertEq(residual, 0, "residual approval left on router");
    }

    function test_fork_noResidualApproval_afterWethSwap() public {
        _swapSingle(WETH, USDC, 1e18, 1, FEE_500);
        uint256 residual = IERC20(WETH).allowance(address(adapter), SWAP_ROUTER);
        assertEq(residual, 0, "residual WETH approval left on router");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Slippage guard: revert when actual output < minAmountOut
    // ─────────────────────────────────────────────────────────────────────────

    function test_fork_revert_insufficientOutput() public {
        uint256 amountIn   = 1_000e6;
        uint256 absurdMin  = type(uint256).max; // impossible to satisfy

        IERC20(USDC).approve(address(adapter), amountIn);
        vm.expectRevert();
        adapter.execute(USDC, WETH, amountIn, absurdMin, abi.encode(FEE_500));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Validate: correct encoding accepted
    // ─────────────────────────────────────────────────────────────────────────

    function test_fork_validate_singleHop_valid() public view {
        (bool valid, string memory reason) = adapter.validate(
            USDC, WETH, 1_000e6, abi.encode(FEE_500)
        );
        assertTrue(valid, reason);
    }

    function test_fork_validate_multiHop_valid() public view {
        bytes memory path     = _encodePath(USDC, FEE_500, WETH, FEE_500, USDT);
        bytes memory adapterData = abi.encode(path, true);
        (bool valid, string memory reason) = adapter.validate(USDC, USDT, 1_000e6, adapterData);
        assertTrue(valid, reason);
    }

    function test_fork_validate_rejects_zeroFee() public view {
        (bool valid,) = adapter.validate(USDC, WETH, 1_000e6, abi.encode(uint24(0)));
        assertFalse(valid);
    }

    function test_fork_validate_rejects_emptyData() public view {
        (bool valid,) = adapter.validate(USDC, WETH, 1_000e6, bytes(""));
        assertFalse(valid);
    }

    function test_fork_validate_rejects_sameToken() public view {
        (bool valid,) = adapter.validate(USDC, USDC, 1_000e6, abi.encode(FEE_500));
        assertFalse(valid);
    }

    function test_fork_validate_rejects_zeroAmountIn() public view {
        (bool valid,) = adapter.validate(USDC, WETH, 0, abi.encode(FEE_500));
        assertFalse(valid);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Adapter metadata
    // ─────────────────────────────────────────────────────────────────────────

    function test_fork_name() public view {
        assertEq(adapter.name(), "UniswapV3Adapter");
    }

    function test_fork_target_isRouter() public view {
        assertEq(adapter.target(), SWAP_ROUTER);
    }
}
