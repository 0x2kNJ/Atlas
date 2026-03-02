/**
 * Atlas Protocol SDK — Capability and Intent Builders
 *
 * Convenient factory functions that assemble Capability and Intent structs
 * with sensible defaults while keeping all security-critical fields explicit.
 *
 * Design principle: builders never choose security-sensitive values for you.
 * Expiry, nonce, scope, and constraints are always explicit parameters.
 */

import type { Address, Hex } from "viem";
import { keccak256, encodeAbiParameters } from "viem";
import { hashCapability } from "./eip712.js";
import { SCOPE, ZERO_ADDRESS, ZERO_HASH } from "./types.js";
import type { Capability, Constraints, Intent, Position } from "./types.js";
import { hashPosition, randomSalt } from "./position.js";

// ─────────────────────────────────────────────────────────────────────────────
// No-constraints helper
// ─────────────────────────────────────────────────────────────────────────────

/** Return an unconstrained Constraints struct. Use for root capabilities with no limits. */
export function noConstraints(): Constraints {
  return {
    maxSpendPerPeriod: 0n,
    periodDuration:    0n,
    minReturnBps:      0n,
    allowedAdapters:   [],
    allowedTokensIn:   [],
    allowedTokensOut:  [],
  };
}

// ─────────────────────────────────────────────────────────────────────────────
// Build a vault.spend Capability (root, Phase 1)
// ─────────────────────────────────────────────────────────────────────────────

export interface BuildCapabilityParams {
  /** The position owner who is granting authority. */
  issuer:      Address;
  /** The agent wallet that will sign intents. */
  grantee:     Address;
  /** Unix timestamp (seconds) when this capability expires. */
  expiry:      bigint;
  /** Unique nonce — use randomSalt() or increment a counter. Must not reuse. */
  nonce:       Hex;
  /** Optional spending and routing constraints. Defaults to unconstrained. */
  constraints?: Constraints;
}

/**
 * Build a root vault.spend Capability for Phase 1.
 * The issuer (position owner) signs this with signCapability() against the kernel domain.
 */
export function buildCapability(params: BuildCapabilityParams): Capability {
  return {
    issuer:               params.issuer,
    grantee:              params.grantee,
    scope:                SCOPE.VAULT_SPEND,
    expiry:               params.expiry,
    nonce:                params.nonce,
    constraints:          params.constraints ?? noConstraints(),
    parentCapabilityHash: ZERO_HASH,
    delegationDepth:      0,
  };
}

/**
 * Build an envelope.manage Capability for registering envelopes.
 * The issuer signs this with signManageCapability() against the registry domain.
 */
export function buildManageCapability(params: BuildCapabilityParams): Capability {
  return {
    issuer:               params.issuer,
    grantee:              params.grantee,
    scope:                SCOPE.ENVELOPE_MANAGE,
    expiry:               params.expiry,
    nonce:                params.nonce,
    constraints:          params.constraints ?? noConstraints(),
    parentCapabilityHash: ZERO_HASH,
    delegationDepth:      0,
  };
}

// ─────────────────────────────────────────────────────────────────────────────
// Build an Intent
// ─────────────────────────────────────────────────────────────────────────────

export interface BuildIntentParams {
  /** The position being spent. Must exist in the vault. */
  position:       Position;
  /** The signed Capability authorising this intent. */
  capability:     Capability;
  /** The registered adapter to execute through. */
  adapter:        Address;
  /** ABI-encoded adapter parameters. Use helpers from adapters.ts. */
  adapterData:    Hex;
  /** Minimum output amount (absolute floor). The kernel reverts if not met. */
  minReturn:      bigint;
  /** Unix timestamp after which this intent is invalid. */
  deadline:       bigint;
  /** Unique nonce — prevents nullifier reuse. */
  nonce:          Hex;
  /** Token the execution must output (received in the output position). */
  outputToken:    Address;
  /** Where the output position is created — almost always address(vault). */
  returnTo:       Address;
  /**
   * Address that must submit this intent.
   * Use ZERO_ADDRESS for permissionless execution.
   * Use a specific solver address for MEV protection.
   */
  submitter:      Address;
  /** Solver fee in basis points (0–500). Taken from gross output. */
  solverFeeBps:   number;
}

/**
 * Build an Intent struct.
 * The grantee (agent wallet) signs this with signIntent() against the kernel domain.
 */
export function buildIntent(params: BuildIntentParams): Intent {
  const positionCommitment = hashPosition(params.position);
  const capabilityHash     = hashCapability(params.capability);

  return {
    positionCommitment,
    capabilityHash,
    adapter:      params.adapter,
    adapterData:  params.adapterData,
    minReturn:    params.minReturn,
    deadline:     params.deadline,
    nonce:        params.nonce,
    outputToken:  params.outputToken,
    returnTo:     params.returnTo,
    submitter:    params.submitter,
    solverFeeBps: params.solverFeeBps,
  };
}

// ─────────────────────────────────────────────────────────────────────────────
// Build Envelope commitments
// ─────────────────────────────────────────────────────────────────────────────

import type { Conditions, Envelope } from "./types.js";
import { hashCapability as hashCap, hashEnvelope } from "./eip712.js";

/**
 * Compute the conditionsHash to embed in an Envelope.
 * Matches: keccak256(abi.encode(conditions)) in EnvelopeRegistry.
 */
export function hashConditions(conditions: Conditions): Hex {
  return keccak256(
    encodeAbiParameters(
      [
        { type: "address" }, // priceOracle
        { type: "address" }, // baseToken
        { type: "address" }, // quoteToken
        { type: "uint256" }, // triggerPrice
        { type: "uint8"   }, // op
        { type: "address" }, // secondaryOracle
        { type: "uint256" }, // secondaryTriggerPrice
        { type: "uint8"   }, // secondaryOp
        { type: "uint8"   }, // logicOp
      ],
      [
        conditions.priceOracle,
        conditions.baseToken,
        conditions.quoteToken,
        conditions.triggerPrice,
        conditions.op,
        conditions.secondaryOracle,
        conditions.secondaryTriggerPrice,
        conditions.secondaryOp,
        conditions.logicOp,
      ]
    )
  );
}

/**
 * Compute the intentCommitment to embed in an Envelope.
 * Must match: keccak256(abi.encode(intent)) in EnvelopeRegistry.trigger().
 *
 * CRITICAL: Intent contains `bytes adapterData` — a dynamic field — making Intent a
 * dynamic struct.  Solidity's abi.encode(intent) therefore emits a 32-byte outer
 * offset header before the struct body (total encoding = 32 + 11×32 + 32 + adapterData).
 * Using encodeAbiParameters with 11 flat types omits that outer offset header, producing
 * a different byte sequence and a different keccak256 → IntentMismatch revert.
 *
 * The correct approach: encode as a single tuple argument so encodeAbiParameters also
 * emits the 32-byte outer offset, exactly matching Solidity's abi.encode(intent).
 */
export function hashIntentCommitment(intent: Intent): Hex {
  return keccak256(
    encodeAbiParameters(
      [{
        type: "tuple",
        components: [
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
      }],
      [{
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
      }]
    )
  );
}

export interface BuildEnvelopeParams {
  position:           Position;
  conditions:         Conditions;
  intent:             Intent;
  manageCapability:   Capability;   // envelope.manage cap — hash stored in envelope.capabilityHash
  expiry:             bigint;
  keeperRewardBps:    number;       // 0–500
  minKeeperRewardWei: bigint;
}

/**
 * Build an Envelope struct ready to pass to EnvelopeRegistry.register().
 */
export function buildEnvelope(params: BuildEnvelopeParams): Envelope {
  return {
    positionCommitment: hashPosition(params.position),
    conditionsHash:     hashConditions(params.conditions),
    intentCommitment:   hashIntentCommitment(params.intent),
    capabilityHash:     hashCap(params.manageCapability),
    expiry:             params.expiry,
    keeperRewardBps:    params.keeperRewardBps,
    minKeeperRewardWei: params.minKeeperRewardWei,
  };
}
