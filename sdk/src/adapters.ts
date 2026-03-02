/**
 * Atlas Protocol SDK — Adapter Data Encoding
 *
 * Helpers for encoding the `adapterData` field in Intents for each supported adapter.
 */

import { encodeAbiParameters, encodePacked, type Address, type Hex } from "viem";
import { AaveOp } from "./types.js";

// ─────────────────────────────────────────────────────────────────────────────
// UniswapV3Adapter
// ─────────────────────────────────────────────────────────────────────────────

/** Fee tiers supported by Uniswap V3. */
export const FEE = {
  LOWEST:  100  as const,  // 0.01%
  LOW:     500  as const,  // 0.05%  ← highest liquidity for most stablecoin pairs
  MEDIUM:  3000 as const,  // 0.30%
  HIGH:    10000 as const, // 1.00%
} as const;

export type FeeTier = (typeof FEE)[keyof typeof FEE];

/**
 * Encode adapter data for a single-hop Uniswap V3 swap.
 *
 * @param fee — Uniswap V3 fee tier (use FEE constants above).
 *
 * Example:
 *   const data = uniswapSingleHop(FEE.LOW);  // USDC → WETH via 0.05% pool
 */
export function uniswapSingleHop(fee: FeeTier): Hex {
  return encodeAbiParameters([{ type: "uint24" }], [fee]);
}

/**
 * Encode adapter data for a multi-hop Uniswap V3 swap.
 *
 * @param path — The encoded path: [tokenA, feeAB, tokenB, feeBC, tokenC, ...].
 *               Build with buildUniswapPath().
 *
 * Example:
 *   const path = buildUniswapPath([USDC, FEE.LOW, WETH, FEE.LOW, USDT]);
 *   const data = uniswapMultiHop(path);
 */
export function uniswapMultiHop(path: Hex): Hex {
  return encodeAbiParameters(
    [{ type: "bytes" }, { type: "bool" }],
    [path, true]
  );
}

/**
 * Build a Uniswap V3 path encoding.
 * Alternates between token addresses (20 bytes) and fee tiers (3 bytes).
 *
 * @param hops — Array alternating [address, fee, address, fee, address, ...]
 *               Must start and end with an address; length must be odd.
 *
 * Example: USDC → (500) → WETH → (500) → USDT
 *   buildUniswapPath([USDC, 500, WETH, 500, USDT])
 */
export function buildUniswapPath(hops: (Address | FeeTier)[]): Hex {
  if (hops.length < 3 || hops.length % 2 === 0) {
    throw new Error("path must have odd length >= 3: [addr, fee, addr, fee, addr, ...]");
  }

  // Build packed bytes: [addr(20)][fee(3)][addr(20)][fee(3)][addr(20)]
  const parts: Hex[] = [];
  for (let i = 0; i < hops.length; i++) {
    if (i % 2 === 0) {
      // Address
      parts.push(hops[i] as Address);
    } else {
      // Fee — 3 bytes
      const fee = hops[i] as FeeTier;
      parts.push(
        encodePacked(["uint24"], [fee])
      );
    }
  }

  // Concatenate all parts.
  const combined = parts.map(p => p.slice(2)).join("");
  return `0x${combined}` as Hex;
}

// ─────────────────────────────────────────────────────────────────────────────
// ClawloanRepayAdapter
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Encode adapter data for repaying a Clawloan loan (static debt, known at envelope creation).
 *
 * tokenIn == tokenOut == USDC.
 * The adapter repays exactly `debtAmount` and returns the surplus to the vault.
 *
 * Use when the loan carries no variable interest between envelope creation and trigger.
 */
export function clawloanRepayStatic(
  pool:       Address,
  botId:      bigint,
  debtAmount: bigint
): Hex {
  return encodeAbiParameters(
    [{ type: "address" }, { type: "uint256" }, { type: "uint256" }],
    [pool, botId, debtAmount]
  );
}

/**
 * Encode adapter data for repaying a Clawloan loan (live debt, queried at trigger time).
 *
 * At trigger time the adapter calls `pool.getDebt(botId)` and repays the live value.
 * Reverts if live debt > debtCap (protects the operator from unexpected interest growth).
 *
 * Use when the loan accrues interest between envelope creation and keeper trigger.
 */
export function clawloanRepayLive(
  pool:    Address,
  botId:   bigint,
  debtCap: bigint
): Hex {
  return encodeAbiParameters(
    [{ type: "address" }, { type: "uint256" }, { type: "uint256" }, { type: "bool" }],
    [pool, botId, debtCap, true]
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// AaveV3Adapter
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Encode adapter data for supplying an asset to Aave V3.
 *
 * tokenIn  = underlying (e.g. USDC)
 * tokenOut = corresponding aToken (e.g. aUSDC)
 */
export function aaveSupply(): Hex {
  return encodeAbiParameters([{ type: "uint8" }], [AaveOp.SUPPLY]);
}

/**
 * Encode adapter data for withdrawing from Aave V3.
 *
 * tokenIn  = aToken (e.g. aUSDC)
 * tokenOut = underlying (e.g. USDC)
 */
export function aaveWithdraw(): Hex {
  return encodeAbiParameters([{ type: "uint8" }], [AaveOp.WITHDRAW]);
}
