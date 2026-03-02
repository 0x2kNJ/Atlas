// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AaveV3Adapter} from "../../contracts/adapters/AaveV3Adapter.sol";

/// @dev Minimal Aave V3 DataTypes access — used for reading reserve data in tests.
interface IPoolDataProvider {
    function getReserveTokensAddresses(address asset) external view returns (
        address aTokenAddress,
        address stableDebtTokenAddress,
        address variableDebtTokenAddress
    );
}

interface IPoolAddressesProvider {
    function getPool() external view returns (address);
    function getPoolDataProvider() external view returns (address);
}

/// @title AaveV3Adapter Fork Tests
/// @notice Tests the adapter against a live Arbitrum mainnet fork.
///
/// Skipped automatically if ARBITRUM_RPC_URL env var is not set.
///
/// To run:
///   ARBITRUM_RPC_URL=<your-url> forge test --match-path "test/fork/AaveV3*" -v
///
/// Pinned block: 295_000_000 (~Feb 2025, Arbitrum Mainnet).

contract AaveV3AdapterForkTest is Test {

    // ─────────────────────────────────────────────────────────────────────────
    // Arbitrum mainnet addresses
    // ─────────────────────────────────────────────────────────────────────────

    uint256 constant FORK_BLOCK = 295_000_000;

    // Aave V3 Addresses Provider (Arbitrum mainnet, canonical)
    address constant ADDRESSES_PROVIDER = 0xa97684ead0e402dC232d5A977953DF7ECBaB3CDb;

    // Tokens on Arbitrum mainnet
    address constant USDC  = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831; // native USDC, 6 dec
    address constant WETH  = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address constant USDT  = 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9; // USDT,  6 dec

    // ─────────────────────────────────────────────────────────────────────────
    // State
    // ─────────────────────────────────────────────────────────────────────────

    AaveV3Adapter adapter;
    address       kernel;

    // aToken addresses — resolved at setUp time from the Aave data provider.
    address aUSDC;
    address aWETH;

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

        adapter = new AaveV3Adapter(ADDRESSES_PROVIDER);
        kernel  = address(this);

        // Resolve aToken addresses from the live Aave data provider.
        IPoolAddressesProvider provider = IPoolAddressesProvider(ADDRESSES_PROVIDER);
        IPoolDataProvider       dataProvider =
            IPoolDataProvider(provider.getPoolDataProvider());

        (aUSDC,,) = dataProvider.getReserveTokensAddresses(USDC);
        (aWETH,,) = dataProvider.getReserveTokensAddresses(WETH);

        // Fund kernel with underlying tokens.
        deal(USDC, kernel, 100_000e6);  // 100k USDC
        deal(WETH, kernel, 100e18);     // 100 WETH
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────────────────

    bytes constant SUPPLY_DATA   = abi.encode(AaveV3Adapter.AaveOp.SUPPLY);
    bytes constant WITHDRAW_DATA = abi.encode(AaveV3Adapter.AaveOp.WITHDRAW);

    function _supply(address underlying, address aToken, uint256 amount)
        internal returns (uint256 aTokenOut)
    {
        IERC20(underlying).approve(address(adapter), amount);
        aTokenOut = adapter.execute(underlying, aToken, amount, 0, SUPPLY_DATA);
    }

    function _withdraw(address aToken, address underlying, uint256 aTokenAmount)
        internal returns (uint256 underlyingOut)
    {
        IERC20(aToken).approve(address(adapter), aTokenAmount);
        underlyingOut = adapter.execute(aToken, underlying, aTokenAmount, 0, WITHDRAW_DATA);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Supply: USDC → aUSDC
    // ─────────────────────────────────────────────────────────────────────────

    function test_fork_supply_usdc() public {
        uint256 amountIn    = 10_000e6;  // 10k USDC
        uint256 usdcBefore  = IERC20(USDC).balanceOf(kernel);
        uint256 aUsdcBefore = IERC20(aUSDC).balanceOf(kernel);

        uint256 aTokenOut = _supply(USDC, aUSDC, amountIn);

        assertGt(aTokenOut, 0, "no aUSDC received");
        assertEq(IERC20(USDC).balanceOf(kernel), usdcBefore - amountIn, "USDC not deducted");
        assertEq(IERC20(aUSDC).balanceOf(kernel), aUsdcBefore + aTokenOut, "aUSDC not credited");
    }

    function test_fork_supply_weth() public {
        uint256 amountIn    = 5e18;  // 5 WETH
        uint256 wethBefore  = IERC20(WETH).balanceOf(kernel);
        uint256 aWethBefore = IERC20(aWETH).balanceOf(kernel);

        uint256 aTokenOut = _supply(WETH, aWETH, amountIn);

        assertGt(aTokenOut, 0, "no aWETH received");
        assertEq(IERC20(WETH).balanceOf(kernel), wethBefore - amountIn, "WETH not deducted");
        assertEq(IERC20(aWETH).balanceOf(kernel), aWethBefore + aTokenOut, "aWETH not credited");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Supply 1:1 ratio
    // ─────────────────────────────────────────────────────────────────────────

    function test_fork_supply_aTokenRatioIsNearOne() public {
        uint256 amountIn  = 1_000e6;  // 1000 USDC
        uint256 aTokenOut = _supply(USDC, aUSDC, amountIn);

        // aToken should be within 0.01% of amountIn (interest accrual since pool inception is tiny).
        assertGe(aTokenOut, (amountIn * 9999) / 10_000, "aUSDC minted less than 0.01% below input");
        assertLe(aTokenOut, (amountIn * 10001) / 10_000, "aUSDC minted more than 0.01% above input");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Withdraw: aUSDC → USDC
    // ─────────────────────────────────────────────────────────────────────────

    function test_fork_withdraw_usdc() public {
        // First supply to get some aUSDC.
        uint256 supplied  = 5_000e6;
        uint256 aTokenIn  = _supply(USDC, aUSDC, supplied);

        uint256 usdcBefore  = IERC20(USDC).balanceOf(kernel);
        uint256 aUsdcBefore = IERC20(aUSDC).balanceOf(kernel);

        uint256 underlyingOut = _withdraw(aUSDC, USDC, aTokenIn);

        assertGt(underlyingOut, 0, "no USDC received");
        assertGe(IERC20(USDC).balanceOf(kernel), usdcBefore + underlyingOut - 1, "USDC not returned");
        assertEq(IERC20(aUSDC).balanceOf(kernel), aUsdcBefore - aTokenIn, "aUSDC not burned");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Round-trip: supply then withdraw loses at most 1 wei per unit (rounding)
    // ─────────────────────────────────────────────────────────────────────────

    function test_fork_roundtrip_supply_withdraw_usdc() public {
        uint256 amountIn    = 10_000e6;  // 10k USDC
        uint256 usdcBefore  = IERC20(USDC).balanceOf(kernel);

        uint256 aTokenOut     = _supply(USDC, aUSDC, amountIn);
        uint256 underlyingOut = _withdraw(aUSDC, USDC, aTokenOut);

        uint256 usdcAfter = IERC20(USDC).balanceOf(kernel);

        // Allow at most 1 wei loss per 1e6 units due to rounding.
        // In practice Aave V3 returns >= supplied due to interest accrual within the block.
        uint256 minExpected = amountIn - (amountIn / 1_000_000) - 1;
        assertGe(usdcAfter - (usdcBefore - amountIn), minExpected,
            "round-trip lost more than expected rounding");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // No residual approvals
    // ─────────────────────────────────────────────────────────────────────────

    function test_fork_supply_noResidualApproval() public {
        _supply(USDC, aUSDC, 1_000e6);
        address pool = IPoolAddressesProvider(ADDRESSES_PROVIDER).getPool();
        assertEq(IERC20(USDC).allowance(address(adapter), pool), 0, "residual approval on pool");
    }

    function test_fork_withdraw_noResidualApproval() public {
        uint256 aTokenIn = _supply(USDC, aUSDC, 1_000e6);
        _withdraw(aUSDC, USDC, aTokenIn);
        address pool = IPoolAddressesProvider(ADDRESSES_PROVIDER).getPool();
        assertEq(IERC20(aUSDC).allowance(address(adapter), pool), 0, "residual aToken approval on pool");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Slippage guard
    // ─────────────────────────────────────────────────────────────────────────

    function test_fork_supply_revert_insufficientOutput() public {
        uint256 amountIn = 1_000e6;
        IERC20(USDC).approve(address(adapter), amountIn);
        vm.expectRevert("AaveV3Adapter: insufficient output");
        adapter.execute(USDC, aUSDC, amountIn, type(uint256).max, SUPPLY_DATA);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Quote
    // ─────────────────────────────────────────────────────────────────────────

    function test_fork_quote_supply_isAmountIn() public view {
        uint256 q = adapter.quote(USDC, aUSDC, 1_000e6, SUPPLY_DATA);
        assertEq(q, 1_000e6, "supply quote should be 1:1");
    }

    function test_fork_quote_withdraw_isAmountIn() public view {
        uint256 q = adapter.quote(aUSDC, USDC, 500e6, WITHDRAW_DATA);
        assertEq(q, 500e6, "withdraw quote should be 1:1");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Validate: SUPPLY
    // ─────────────────────────────────────────────────────────────────────────

    function test_fork_validate_supply_usdc_valid() public view {
        (bool valid, string memory reason) = adapter.validate(
            USDC, aUSDC, 1_000e6, SUPPLY_DATA
        );
        assertTrue(valid, reason);
    }

    function test_fork_validate_supply_rejects_wrongAToken() public view {
        // Pass aWETH as the output for a USDC supply — should reject.
        (bool valid,) = adapter.validate(USDC, aWETH, 1_000e6, SUPPLY_DATA);
        assertFalse(valid, "should reject mismatched aToken");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Validate: WITHDRAW
    // ─────────────────────────────────────────────────────────────────────────

    function test_fork_validate_withdraw_usdc_valid() public view {
        (bool valid, string memory reason) = adapter.validate(
            aUSDC, USDC, 1_000e6, WITHDRAW_DATA
        );
        assertTrue(valid, reason);
    }

    function test_fork_validate_withdraw_rejects_wrongUnderlying() public view {
        // Pass WETH as the underlying for an aUSDC withdrawal — should reject.
        (bool valid,) = adapter.validate(aUSDC, WETH, 1_000e6, WITHDRAW_DATA);
        assertFalse(valid, "should reject mismatched underlying");
    }

    function test_fork_validate_rejects_wrongDataLength() public view {
        (bool valid,) = adapter.validate(USDC, aUSDC, 1_000e6, bytes(""));
        assertFalse(valid, "should reject empty data");
    }

    function test_fork_validate_rejects_zeroAmountIn() public view {
        (bool valid,) = adapter.validate(USDC, aUSDC, 0, SUPPLY_DATA);
        assertFalse(valid, "should reject zero amountIn");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Adapter metadata
    // ─────────────────────────────────────────────────────────────────────────

    function test_fork_name() public view {
        assertEq(adapter.name(), "AaveV3Adapter");
    }

    function test_fork_target_isPool() public view {
        address pool = IPoolAddressesProvider(ADDRESSES_PROVIDER).getPool();
        assertEq(adapter.target(), pool, "target should be Aave V3 pool");
    }
}
