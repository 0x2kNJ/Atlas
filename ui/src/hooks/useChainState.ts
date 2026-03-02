import { useReadContracts, useAccount } from "wagmi";
import { ADDRESSES } from "../contracts/addresses";
import {
  ERC20_ABI,
  CLAWLOAN_POOL_ABI,
  VAULT_ABI,
  CREDIT_VERIFIER_ABI,
  ACCUMULATOR_ABI,
} from "../contracts/abis";

const BOT_ID = 1n;

export function useChainState(positionHash?: `0x${string}`, _envelopeHash?: `0x${string}`, capabilityHash?: `0x${string}`) {
  const { address } = useAccount();

  const results = useReadContracts({
    contracts: [
      // USDC balance of connected wallet
      {
        address: ADDRESSES.MockUSDC as `0x${string}`,
        abi: ERC20_ABI,
        functionName: "balanceOf",
        args: [address ?? "0x0000000000000000000000000000000000000000"],
      },
      // USDC balance of vault
      {
        address: ADDRESSES.MockUSDC as `0x${string}`,
        abi: ERC20_ABI,
        functionName: "balanceOf",
        args: [ADDRESSES.SingletonVault as `0x${string}`],
      },
      // Outstanding debt
      {
        address: ADDRESSES.MockClawloanPool as `0x${string}`,
        abi: CLAWLOAN_POOL_ABI,
        functionName: "getDebt",
        args: [BOT_ID],
      },
      // USDC allowance for vault
      {
        address: ADDRESSES.MockUSDC as `0x${string}`,
        abi: ERC20_ABI,
        functionName: "allowance",
        args: [
          address ?? "0x0000000000000000000000000000000000000000",
          ADDRESSES.SingletonVault as `0x${string}`,
        ],
      },
      // Position exists (if we have a hash)
      {
        address: ADDRESSES.SingletonVault as `0x${string}`,
        abi: VAULT_ABI,
        functionName: "positionExists",
        args: [positionHash ?? "0x0000000000000000000000000000000000000000000000000000000000000000"],
      },
      // Position encumbered
      {
        address: ADDRESSES.SingletonVault as `0x${string}`,
        abi: VAULT_ABI,
        functionName: "isEncumbered",
        args: [positionHash ?? "0x0000000000000000000000000000000000000000000000000000000000000000"],
      },
      // Credit tier
      {
        address: ADDRESSES.CreditVerifier as `0x${string}`,
        abi: CREDIT_VERIFIER_ABI,
        functionName: "getCreditTier",
        args: [capabilityHash ?? "0x0000000000000000000000000000000000000000000000000000000000000000"],
      },
      // Max borrow
      {
        address: ADDRESSES.CreditVerifier as `0x${string}`,
        abi: CREDIT_VERIFIER_ABI,
        functionName: "getMaxBorrow",
        args: [capabilityHash ?? "0x0000000000000000000000000000000000000000000000000000000000000000"],
      },
      // Receipt count
      {
        address: ADDRESSES.ReceiptAccumulator as `0x${string}`,
        abi: ACCUMULATOR_ABI,
        functionName: "receiptCount",
        args: [capabilityHash ?? "0x0000000000000000000000000000000000000000000000000000000000000000"],
      },
    ],
    query: { refetchInterval: 2000 },
  });

  const [
    walletUsdcRaw,
    vaultUsdcRaw,
    debtRaw,
    allowanceRaw,
    positionExistsRaw,
    isEncumberedRaw,
    creditTierRaw,
    maxBorrowRaw,
    receiptCountRaw,
  ] = results.data ?? [];

  return {
    walletUsdc:     (walletUsdcRaw?.result as bigint | undefined) ?? 0n,
    vaultUsdc:      (vaultUsdcRaw?.result as bigint | undefined) ?? 0n,
    debt:           (debtRaw?.result as bigint | undefined) ?? 0n,
    allowance:      (allowanceRaw?.result as bigint | undefined) ?? 0n,
    positionExists: (positionExistsRaw?.result as boolean | undefined) ?? false,
    isEncumbered:   (isEncumberedRaw?.result as boolean | undefined) ?? false,
    creditTier:     (creditTierRaw?.result as number | undefined) ?? 0,
    maxBorrow:      (maxBorrowRaw?.result as bigint | undefined) ?? 10_000_000n,
    receiptCount:   (receiptCountRaw?.result as bigint | undefined) ?? 0n,
    isLoading:      results.isLoading,
  };
}
