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

/// @title PriceSwapAdapter
/// @notice Atlas Protocol adapter for price-triggered stop-loss and take-profit envelopes.
///
/// Converts an exact amount of WETH (18-decimal) into USDC (6-decimal) at the
/// current oracle spot price. The adapter holds USDC reserves (pre-seeded at deployment)
/// to fund the output side of the swap.
///
/// Stop-loss demo flow:
///   1. Agent deposits 1 WETH into SingletonVault.
///   2. Agent registers envelope: condition = ETH/USD < $1,800, adapter = PriceSwapAdapter.
///   3. Oracle is pushed below $1,800 by the demo (or by a real price drop).
///   4. Any keeper triggers → kernel calls execute() → WETH exchanged for USDC at oracle price.
///   5. Agent's vault position switches from WETH to USDC automatically.
///
/// Conversion formula:
///   usdcOut = (amountIn_weth * price_usd_per_eth) / 1e20
///   Example: 1e18 WETH * 1700e8 / 1e20 = 1700e6 USDC (1700 USDC for 1 ETH at $1,700)
///
/// Security properties:
///   - Price is read from the oracle at execution time — the keeper cannot manipulate it.
///   - minReturn in the intent provides a hard floor on USDC output.
///   - If USDC reserves are insufficient, execute() reverts (never produces a bad fill).
///
/// adapterData: empty (all params embedded in oracle address at construction)
contract PriceSwapAdapter is IAdapter {
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
        return "PriceSwapAdapter";
    }

    function target() external pure override returns (address) {
        return address(0);
    }

    /// @notice Quote: how many USDC would `amountIn` WETH produce at current oracle price.
    function quote(
        address,
        address,
        uint256 amountIn,
        bytes calldata
    ) external view override returns (uint256) {
        (, int256 p, , , ) = priceOracle.latestRoundData();
        if (p <= 0) return 0;
        return (amountIn * uint256(p)) / 1e20;
    }

    function validate(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        bytes calldata
    ) external view override returns (bool valid, string memory reason) {
        if (tokenIn  != address(weth)) return (false, "tokenIn must be WETH");
        if (tokenOut != address(usdc)) return (false, "tokenOut must be USDC");
        if (amountIn == 0)             return (false, "amountIn is zero");

        (, int256 p, , , ) = priceOracle.latestRoundData();
        if (p <= 0)                    return (false, "oracle price is zero or negative");

        uint256 usdcOut = (amountIn * uint256(p)) / 1e20;
        if (usdc.balanceOf(address(this)) < usdcOut)
            return (false, "insufficient USDC reserves in adapter");

        return (true, "");
    }

    /// @notice Swap amountIn WETH for USDC at the current oracle price.
    function execute(
        address tokenIn,
        address,
        uint256 amountIn,
        uint256 minAmountOut,
        bytes calldata
    ) external override returns (uint256 amountOut) {
        // Pull WETH from kernel (kernel holds it after releasing from vault).
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        // Read oracle price (8 decimals, e.g. 1700e8 = $1,700/ETH).
        (, int256 p, , , ) = priceOracle.latestRoundData();
        require(p > 0, "PriceSwapAdapter: oracle price not positive");

        // WETH is 18 dec, price is 8 dec, USDC is 6 dec:
        //   usdcOut = amountIn * price / 10^(18+8-6) = amountIn * price / 10^20
        amountOut = (amountIn * uint256(p)) / 1e20;
        require(amountOut >= minAmountOut, "PriceSwapAdapter: output below minReturn");

        // Send USDC to kernel (which will commit it as the new vault position).
        usdc.safeTransfer(msg.sender, amountOut);

        // WETH received is kept as a "burning" mechanism — in production this
        // would route to a real DEX. For the demo it stays in the adapter.
    }
}
