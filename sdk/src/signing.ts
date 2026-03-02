/**
 * Atlas Protocol SDK — Signing Helpers
 *
 * High-level functions for signing capabilities and intents.
 * Uses viem's WalletClient (works with MetaMask, hardware wallets, private keys).
 *
 * Usage:
 *   const capSig = await signCapability(walletClient, capability, kernelAddress, chainId);
 *   const intentSig = await signIntent(walletClient, intent, kernelAddress, chainId);
 *
 * For envelope.manage capabilities (registered in EnvelopeRegistry):
 *   const manageCapSig = await signManageCapability(walletClient, cap, registryAddress, chainId);
 */

import type { WalletClient, Address, Hex } from "viem";
import { kernelDomain, registryDomain } from "./eip712.js";
import type { Capability, Intent } from "./types.js";

// Only include types reachable from the primaryType — MetaMask rejects orphaned types.
const CAPABILITY_TYPES = {
  Constraints: [
    { name: "maxSpendPerPeriod", type: "uint256"   },
    { name: "periodDuration",    type: "uint256"   },
    { name: "minReturnBps",      type: "uint256"   },
    { name: "allowedAdapters",   type: "address[]" },
    { name: "allowedTokensIn",   type: "address[]" },
    { name: "allowedTokensOut",  type: "address[]" },
  ],
  Capability: [
    { name: "issuer",               type: "address"     },
    { name: "grantee",              type: "address"     },
    { name: "scope",                type: "bytes32"     },
    { name: "expiry",               type: "uint256"     },
    { name: "nonce",                type: "bytes32"     },
    { name: "constraints",          type: "Constraints" },
    { name: "parentCapabilityHash", type: "bytes32"     },
    { name: "delegationDepth",      type: "uint8"       },
  ],
} as const;

const INTENT_TYPES = {
  Intent: [
    { name: "positionCommitment", type: "bytes32" },
    { name: "capabilityHash",     type: "bytes32" },
    { name: "adapter",            type: "address" },
    { name: "adapterData",        type: "bytes"   },
    { name: "minReturn",          type: "uint256" },
    { name: "deadline",           type: "uint256" },
    { name: "nonce",              type: "bytes32" },
    { name: "outputToken",        type: "address" },
    { name: "returnTo",           type: "address" },
    { name: "submitter",          type: "address" },
    { name: "solverFeeBps",       type: "uint16"  },
  ],
} as const;

// ─────────────────────────────────────────────────────────────────────────────
// Sign a vault.spend Capability against the CapabilityKernel domain.
// Called by the position owner (alice) to authorise an agent.
// ─────────────────────────────────────────────────────────────────────────────

export async function signCapability(
  wallet: WalletClient,
  capability: Capability,
  kernelAddress: Address,
  chainId: number
): Promise<Hex> {
  const domain = kernelDomain(kernelAddress, chainId);
  return wallet.signTypedData({
    account:     wallet.account!,
    domain,
    types:       CAPABILITY_TYPES,
    primaryType: "Capability",
    message:     capabilityToMessage(capability),
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// Sign an envelope.manage Capability against the EnvelopeRegistry domain.
// Called by the position owner to authorise envelope registration.
// ─────────────────────────────────────────────────────────────────────────────

export async function signManageCapability(
  wallet: WalletClient,
  capability: Capability,
  registryAddress: Address,
  chainId: number
): Promise<Hex> {
  const domain = registryDomain(registryAddress, chainId);
  return wallet.signTypedData({
    account:     wallet.account!,
    domain,
    types:       CAPABILITY_TYPES,
    primaryType: "Capability",
    message:     capabilityToMessage(capability),
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// Sign an Intent against the CapabilityKernel domain.
// Called by the grantee (bob / the agent) to authorise a specific execution.
// ─────────────────────────────────────────────────────────────────────────────

export async function signIntent(
  wallet: WalletClient,
  intent: Intent,
  kernelAddress: Address,
  chainId: number
): Promise<Hex> {
  const domain = kernelDomain(kernelAddress, chainId);
  return wallet.signTypedData({
    account:     wallet.account!,
    domain,
    types:       INTENT_TYPES,
    primaryType: "Intent",
    message:     intentToMessage(intent),
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// Internal: convert SDK types to viem message format (bigint → bigint is fine,
// but arrays and nested structs need to be plain objects).
// ─────────────────────────────────────────────────────────────────────────────

function capabilityToMessage(cap: Capability) {
  return {
    issuer:               cap.issuer,
    grantee:              cap.grantee,
    scope:                cap.scope,
    expiry:               cap.expiry,
    nonce:                cap.nonce,
    constraints: {
      maxSpendPerPeriod: cap.constraints.maxSpendPerPeriod,
      periodDuration:    cap.constraints.periodDuration,
      minReturnBps:      cap.constraints.minReturnBps,
      allowedAdapters:   cap.constraints.allowedAdapters,
      allowedTokensIn:   cap.constraints.allowedTokensIn,
      allowedTokensOut:  cap.constraints.allowedTokensOut,
    },
    parentCapabilityHash: cap.parentCapabilityHash,
    delegationDepth:      cap.delegationDepth,
  };
}

function intentToMessage(intent: Intent) {
  return {
    positionCommitment: intent.positionCommitment,
    capabilityHash:     intent.capabilityHash,
    adapter:            intent.adapter,
    adapterData:        intent.adapterData,
    minReturn:          intent.minReturn,
    deadline:           intent.deadline,
    nonce:              intent.nonce,
    outputToken:        intent.outputToken,
    returnTo:           intent.returnTo,
    submitter:          intent.submitter,
    solverFeeBps:       intent.solverFeeBps,
  };
}
