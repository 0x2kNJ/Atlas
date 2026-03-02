// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IAdapter} from "../interfaces/IAdapter.sol";

interface IPriceOracle {
    function latestRoundData() external view returns (
        uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound
    );
    function decimals() external view returns (uint8);
}

/// @title MockReverseSwapAdapter
/// @notice Atlas adapter for USDC→WETH rebuy at oracle spot price.
///
/// Used in chained strategy graphs as the "buy the dip" leg: after a
/// PriceSwapAdapter converts WETH→USDC on a price drop, this adapter
/// converts the USDC back to WETH when the next stage triggers.
///
/// Conversion:
///   wethOut = (usdcIn * 1e20) / price_usd_per_eth
///   Example: 1700e6 USDC / 1700e8 = 1e18 WETH  (buy 1 ETH at $1,700)
///
/// Reserves: pre-seeded with WETH at deploy time via seed().
contract MockReverseSwapAdapter is IAdapter {
    using SafeERC20 for IERC20;

    IPriceOracle public immutable priceOracle;
    IERC20       public immutable usdc;
    IERC20       public immutable weth;

    constructor(address _priceOracle, address _usdc, address _weth) {
        priceOracle = IPriceOracle(_priceOracle);
        usdc        = IERC20(_usdc);
        weth        = IERC20(_weth);
    }

    function name() external pure override returns (string memory) {
        return "MockReverseSwapAdapter";
    }

    function target() external pure override returns (address) {
        return address(0);
    }

    function quote(
        address,
        address,
        uint256 amountIn,
        bytes calldata
    ) external view override returns (uint256) {
        (, int256 p, , , ) = priceOracle.latestRoundData();
        if (p <= 0) return 0;
        return (amountIn * 1e20) / uint256(p);
    }

    function validate(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        bytes calldata
    ) external view override returns (bool valid, string memory reason) {
        if (tokenIn  != address(usdc)) return (false, "tokenIn must be USDC");
        if (tokenOut != address(weth)) return (false, "tokenOut must be WETH");
        if (amountIn == 0)             return (false, "amountIn is zero");
        (, int256 p, , , ) = priceOracle.latestRoundData();
        if (p <= 0)                    return (false, "oracle price is zero or negative");
        uint256 wethOut = (amountIn * 1e20) / uint256(p);
        if (weth.balanceOf(address(this)) < wethOut)
            return (false, "insufficient WETH reserves in adapter");
        return (true, "");
    }

    function execute(
        address tokenIn,
        address,
        uint256 amountIn,
        uint256 minAmountOut,
        bytes calldata
    ) external override returns (uint256 amountOut) {
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        (, int256 p, , , ) = priceOracle.latestRoundData();
        require(p > 0, "MockReverseSwapAdapter: oracle price not positive");

        // USDC 6 dec, price 8 dec, WETH 18 dec → wethOut = usdcIn * 1e20 / price
        amountOut = (amountIn * 1e20) / uint256(p);
        require(amountOut >= minAmountOut, "MockReverseSwapAdapter: output below minReturn");

        weth.safeTransfer(msg.sender, amountOut);
    }
}
