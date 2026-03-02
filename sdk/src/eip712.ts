/**
 * Atlas Protocol SDK — EIP-712 Type Definitions and Hashing
 *
 * All type strings and field definitions mirror HashLib.sol exactly.
 * Any change to a struct's fields in Types.sol must be reflected here.
 *
 * EIP-712 reference: https://eips.ethereum.org/EIPS/eip-712
 */

import {
  encodeAbiParameters,
  encodePacked,
  keccak256,
  type Address,
  type Hex,
  type TypedDataDomain,
} from "viem";
import type { Capability, Constraints, Envelope, Intent } from "./types.js";

// ─────────────────────────────────────────────────────────────────────────────
// EIP-712 type definitions
//
// These are passed to viem's signTypedData / verifyTypedData helpers.
// ─────────────────────────────────────────────────────────────────────────────

export const ATLAS_TYPES = {
  Constraints: [
    { name: "maxSpendPerPeriod", type: "uint256" },
    { name: "periodDuration",    type: "uint256" },
    { name: "minReturnBps",      type: "uint256" },
    { name: "allowedAdapters",   type: "address[]" },
    { name: "allowedTokensIn",   type: "address[]" },
    { name: "allowedTokensOut",  type: "address[]" },
  ],
  Capability: [
    { name: "issuer",               type: "address"  },
    { name: "grantee",              type: "address"  },
    { name: "scope",                type: "bytes32"  },
    { name: "expiry",               type: "uint256"  },
    { name: "nonce",                type: "bytes32"  },
    { name: "constraints",          type: "Constraints" },
    { name: "parentCapabilityHash", type: "bytes32"  },
    { name: "delegationDepth",      type: "uint8"    },
  ],
  Intent: [
    { name: "positionCommitment", type: "bytes32"  },
    { name: "capabilityHash",     type: "bytes32"  },
    { name: "adapter",            type: "address"  },
    { name: "adapterData",        type: "bytes"    },
    { name: "minReturn",          type: "uint256"  },
    { name: "deadline",           type: "uint256"  },
    { name: "nonce",              type: "bytes32"  },
    { name: "outputToken",        type: "address"  },
    { name: "returnTo",           type: "address"  },
    { name: "submitter",          type: "address"  },
    { name: "solverFeeBps",       type: "uint16"   },
  ],
  Envelope: [
    { name: "positionCommitment", type: "bytes32" },
    { name: "conditionsHash",     type: "bytes32" },
    { name: "intentCommitment",   type: "bytes32" },
    { name: "capabilityHash",     type: "bytes32" },
    { name: "expiry",             type: "uint256" },
    { name: "keeperRewardBps",    type: "uint16"  },
    { name: "minKeeperRewardWei", type: "uint128" },
  ],
} as const;

// ─────────────────────────────────────────────────────────────────────────────
// Domain factory
// ─────────────────────────────────────────────────────────────────────────────

/** EIP-712 domain for the CapabilityKernel (vault.spend capabilities + intents). */
export function kernelDomain(kernelAddress: Address, chainId: number): TypedDataDomain {
  return {
    name:              "CapabilityKernel",
    version:           "1",
    chainId,
    verifyingContract: kernelAddress,
  };
}

/** EIP-712 domain for the EnvelopeRegistry (envelope.manage capabilities). */
export function registryDomain(registryAddress: Address, chainId: number): TypedDataDomain {
  return {
    name:              "EnvelopeRegistry",
    version:           "1",
    chainId,
    verifyingContract: registryAddress,
  };
}

// ─────────────────────────────────────────────────────────────────────────────
// Off-chain struct hashing
//
// These produce the same bytes32 as HashLib.sol's hash functions.
// Used when you need the raw hash for embedding in another struct
// (e.g. intent.capabilityHash, envelope.capabilityHash).
// ─────────────────────────────────────────────────────────────────────────────

// ─────────────────────────────────────────────────────────────────────────────
// Type hash helpers
//
// EIP-712 type hashes are keccak256 of raw UTF-8 bytes, NOT ABI-encoded strings.
// Solidity: keccak256("Capability(...)") = keccak256(utf8_bytes("Capability(...)"))
// Viem equivalent: keccak256(encodePacked(["string"], ["Capability(..."]))
// ─────────────────────────────────────────────────────────────────────────────

function keccak256Utf8(s: string): Hex {
  return keccak256(encodePacked(["string"], [s]));
}

/** keccak256("vault.spend") — matches SCOPE.VAULT_SPEND */
export const VAULT_SPEND_SCOPE = keccak256Utf8("vault.spend");

/** keccak256("envelope.manage") — matches SCOPE.ENVELOPE_MANAGE */
export const ENVELOPE_MANAGE_SCOPE = keccak256Utf8("envelope.manage");

const CONSTRAINTS_TYPEHASH = keccak256Utf8(
  "Constraints(uint256 maxSpendPerPeriod,uint256 periodDuration," +
  "uint256 minReturnBps," +
  "address[] allowedAdapters,address[] allowedTokensIn,address[] allowedTokensOut)"
);

const CAPABILITY_TYPEHASH = keccak256Utf8(
  "Capability(address issuer,address grantee,bytes32 scope,uint256 expiry,bytes32 nonce," +
  "Constraints constraints,bytes32 parentCapabilityHash,uint8 delegationDepth)" +
  "Constraints(uint256 maxSpendPerPeriod,uint256 periodDuration," +
  "uint256 minReturnBps," +
  "address[] allowedAdapters,address[] allowedTokensIn,address[] allowedTokensOut)"
);

const INTENT_TYPEHASH = keccak256Utf8(
  "Intent(bytes32 positionCommitment,bytes32 capabilityHash,address adapter," +
  "bytes adapterData,uint256 minReturn,uint256 deadline,bytes32 nonce," +
  "address outputToken,address returnTo,address submitter,uint16 solverFeeBps)"
);

const ENVELOPE_TYPEHASH = keccak256Utf8(
  "Envelope(bytes32 positionCommitment,bytes32 conditionsHash,bytes32 intentCommitment," +
  "bytes32 capabilityHash,uint256 expiry,uint16 keeperRewardBps,uint128 minKeeperRewardWei)"
);

/**
 * EIP-712 encoding of address[] — matches HashLib._hashAddressArray().
 *
 * Each address is left-zero-padded to 32 bytes, elements concatenated, then keccak256'd.
 * This is the correct EIP-712 spec encoding; abi.encodePacked(address[]) is wrong
 * because it only uses 20 bytes per element.
 */
export function hashAddressArray(arr: Address[]): Hex {
  if (arr.length === 0) return keccak256("0x");
  // Encode each address as 32-byte padded (left-zero), then hash concatenation.
  const encoded = encodeAbiParameters(
    arr.map(() => ({ type: "address" as const })),
    arr
  );
  return keccak256(encoded);
}

/** Hash a Constraints struct — matches HashLib.hashConstraints(). */
export function hashConstraints(c: Constraints): Hex {
  return keccak256(encodeAbiParameters(
    [
      { type: "bytes32" }, // typehash
      { type: "uint256" }, // maxSpendPerPeriod
      { type: "uint256" }, // periodDuration
      { type: "uint256" }, // minReturnBps
      { type: "bytes32" }, // allowedAdapters hash
      { type: "bytes32" }, // allowedTokensIn hash
      { type: "bytes32" }, // allowedTokensOut hash
    ],
    [
      CONSTRAINTS_TYPEHASH,
      c.maxSpendPerPeriod,
      c.periodDuration,
      c.minReturnBps,
      hashAddressArray(c.allowedAdapters),
      hashAddressArray(c.allowedTokensIn),
      hashAddressArray(c.allowedTokensOut),
    ]
  ));
}

/** Hash a Capability struct — matches HashLib.hashCapability(). */
export function hashCapability(cap: Capability): Hex {
  return keccak256(encodeAbiParameters(
    [
      { type: "bytes32" }, // typehash
      { type: "address" }, // issuer
      { type: "address" }, // grantee
      { type: "bytes32" }, // scope
      { type: "uint256" }, // expiry
      { type: "bytes32" }, // nonce
      { type: "bytes32" }, // constraints hash
      { type: "bytes32" }, // parentCapabilityHash
      { type: "uint8"   }, // delegationDepth
    ],
    [
      CAPABILITY_TYPEHASH,
      cap.issuer,
      cap.grantee,
      cap.scope,
      cap.expiry,
      cap.nonce,
      hashConstraints(cap.constraints),
      cap.parentCapabilityHash,
      cap.delegationDepth,
    ]
  ));
}

/** Hash an Intent struct — matches HashLib.hashIntent(). */
export function hashIntent(intent: Intent): Hex {
  return keccak256(encodeAbiParameters(
    [
      { type: "bytes32" }, // typehash
      { type: "bytes32" }, // positionCommitment
      { type: "bytes32" }, // capabilityHash
      { type: "address" }, // adapter
      { type: "bytes32" }, // keccak256(adapterData)
      { type: "uint256" }, // minReturn
      { type: "uint256" }, // deadline
      { type: "bytes32" }, // nonce
      { type: "address" }, // outputToken
      { type: "address" }, // returnTo
      { type: "address" }, // submitter
      { type: "uint16"  }, // solverFeeBps
    ],
    [
      INTENT_TYPEHASH,
      intent.positionCommitment,
      intent.capabilityHash,
      intent.adapter,
      keccak256(intent.adapterData),
      intent.minReturn,
      intent.deadline,
      intent.nonce,
      intent.outputToken,
      intent.returnTo,
      intent.submitter,
      intent.solverFeeBps,
    ]
  ));
}

/** Hash an Envelope struct — matches HashLib.hashEnvelope(). */
export function hashEnvelope(env: Envelope): Hex {
  return keccak256(encodeAbiParameters(
    [
      { type: "bytes32" }, // typehash
      { type: "bytes32" }, // positionCommitment
      { type: "bytes32" }, // conditionsHash
      { type: "bytes32" }, // intentCommitment
      { type: "bytes32" }, // capabilityHash
      { type: "uint256" }, // expiry
      { type: "uint16"  }, // keeperRewardBps
      { type: "uint128" }, // minKeeperRewardWei
    ],
    [
      ENVELOPE_TYPEHASH,
      env.positionCommitment,
      env.conditionsHash,
      env.intentCommitment,
      env.capabilityHash,
      env.expiry,
      env.keeperRewardBps,
      env.minKeeperRewardWei,
    ]
  ));
}
