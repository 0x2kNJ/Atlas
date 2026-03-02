import type { PublicClient, WalletClient } from "viem";
import { toHex } from "viem";
import type { Conditions, Position, Intent, Capability } from "@atlas-protocol/sdk";
import { ADDRESSES } from "../contracts/addresses";
import { REGISTRY_ABI } from "../contracts/abis";

type LogLevel = "info" | "success" | "warn" | "error";

export interface TriggerEnvelopeParams {
  publicClient: PublicClient;
  walletClient: WalletClient;
  address: `0x${string}`;
  envelopeHash: `0x${string}`;
  conditions: Conditions;
  position: Position;
  intent: Intent;
  spendCap: Capability;
  capSig: `0x${string}`;
  intentSig: `0x${string}`;
  loanDeadline: bigint;
  positionAmount: bigint;
  keeperRewardBps: bigint;
  log: (level: LogLevel, message: string) => void;
}

export interface TriggerResult {
  triggerTx: `0x${string}`;
  feeEarned: bigint;
}

/**
 * Warp Anvil time past the loan deadline, simulate the trigger call, and broadcast it.
 *
 * Returns the trigger TX hash and the keeper fee earned. Throws on simulation failure
 * or a reverted TX so callers receive the exact revert reason, not a raw tx hash.
 */
export async function triggerEnvelope(params: TriggerEnvelopeParams): Promise<TriggerResult> {
  const {
    publicClient, walletClient, address,
    envelopeHash, conditions, position, intent, spendCap, capSig, intentSig,
    loanDeadline, positionAmount, keeperRewardBps, log,
  } = params;

  log("info", "Keeper: checking condition (block.timestamp > loanDeadline)…");

  // Set Anvil block timestamp past deadline. Use max(latestBlock.timestamp + 1, deadline + 1)
  // so repeated calls never try to set a timestamp ≤ the current chain tip.
  const latestBlock = await publicClient.getBlock({ blockTag: "latest" });
  const minTs    = latestBlock.timestamp + 1n;
  const targetTs = loanDeadline + 1n > minTs ? loanDeadline + 1n : minTs;
  await publicClient.request({
    method: "evm_setNextBlockTimestamp" as never,
    params: [toHex(targetTs)] as never,
  });
  await publicClient.request({ method: "evm_mine" as never, params: [] as never });
  log("info", `Warped to ${new Date(Number(targetTs) * 1000).toLocaleString()} — condition now met`);

  log("info", `Triggering envelope ${envelopeHash.slice(0, 14)}…`);

  // Verify envelope is still Active before broadcasting — stale in-memory state can survive
  // a chain restart, producing a confusing revert message rather than a clear user error.
  const envelopeActive = await publicClient.readContract({
    address: ADDRESSES.EnvelopeRegistry as `0x${string}`,
    abi: REGISTRY_ABI,
    functionName: "isActive",
    args: [envelopeHash],
  }) as boolean;

  if (!envelopeActive) {
    throw new Error(
      "Envelope not found or already triggered on this chain.\n" +
      "Hard-refresh (Cmd+Shift+R) then redo steps 2–4 (deposit → register → trigger)."
    );
  }

  const triggerArgs = [
    envelopeHash,
    conditions as never,
    position   as never,
    intent     as never,
    spendCap   as never,
    capSig,
    intentSig,
  ] as const;

  // Simulate before broadcasting to surface the exact revert reason on failure.
  try {
    await publicClient.simulateContract({
      address: ADDRESSES.EnvelopeRegistry as `0x${string}`,
      abi: REGISTRY_ABI,
      functionName: "trigger",
      args: triggerArgs,
      account: address,
    });
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    throw new Error(`Trigger simulation failed: ${msg.slice(0, 400)}`);
  }

  const hash = await walletClient.writeContract({
    address: ADDRESSES.EnvelopeRegistry as `0x${string}`,
    abi: REGISTRY_ABI,
    functionName: "trigger",
    args: triggerArgs,
  });

  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  if (receipt.status === "reverted") {
    throw new Error(`Trigger TX reverted: ${hash}`);
  }

  const feeEarned = (positionAmount * keeperRewardBps) / 10000n;
  const feeUsdc   = (Number(feeEarned) / 1e6).toFixed(2);
  const posUsdc   = (Number(positionAmount) / 1e6).toFixed(0);
  log("success", `Loan repaid by keeper! tx ${hash.slice(0, 10)}…`);
  log("success", `Keeper earned: ${feeUsdc} USDC (${keeperRewardBps / 100n}% of ${posUsdc} USDC position)`);
  log("success", "Surplus returned to vault as new position — agent keeps the profit");

  return { triggerTx: hash, feeEarned };
}
