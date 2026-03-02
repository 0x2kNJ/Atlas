/**
 * Atlas Protocol SDK — Core Types
 *
 * These types mirror the Solidity structs in Types.sol exactly.
 * Field names, field order, and Solidity types are preserved so that
 * EIP-712 hashing produces byte-for-byte identical digests on both sides.
 */

import type { Address, Hex } from "viem";

// ─────────────────────────────────────────────────────────────────────────────
// Position
// ─────────────────────────────────────────────────────────────────────────────

export interface Position {
  owner:  Address;
  asset:  Address;
  amount: bigint;
  salt:   Hex;     // bytes32
}

// ─────────────────────────────────────────────────────────────────────────────
// Capability
// ─────────────────────────────────────────────────────────────────────────────

export interface Constraints {
  maxSpendPerPeriod: bigint;
  periodDuration:    bigint;
  minReturnBps:      bigint;
  allowedAdapters:   Address[];
  allowedTokensIn:   Address[];
  allowedTokensOut:  Address[];
}

export interface Capability {
  issuer:               Address;
  grantee:              Address;
  scope:                Hex;     // bytes32 — use scopeHash() helpers below
  expiry:               bigint;
  nonce:                Hex;     // bytes32
  constraints:          Constraints;
  parentCapabilityHash: Hex;     // bytes32 — bytes32(0) for root capabilities
  delegationDepth:      number;  // uint8 — 0 for Phase 1
}

// ─────────────────────────────────────────────────────────────────────────────
// Intent
// ─────────────────────────────────────────────────────────────────────────────

export interface Intent {
  positionCommitment: Hex;     // bytes32
  capabilityHash:     Hex;     // bytes32
  adapter:            Address;
  adapterData:        Hex;     // bytes
  minReturn:          bigint;
  deadline:           bigint;
  nonce:              Hex;     // bytes32
  outputToken:        Address;
  returnTo:           Address; // address(vault) for standard intents
  submitter:          Address; // address(0) = permissionless; specific address = MEV-protected
  solverFeeBps:       number;  // uint16
}

// ─────────────────────────────────────────────────────────────────────────────
// Envelope
// ─────────────────────────────────────────────────────────────────────────────

export enum ComparisonOp {
  LESS_THAN    = 0,
  GREATER_THAN = 1,
  EQUAL        = 2,
}

export interface Conditions {
  priceOracle:           Address;
  baseToken:             Address;
  quoteToken:            Address;
  triggerPrice:          bigint;
  op:                    ComparisonOp;
  // Phase 1+: compound conditions (set secondaryOracle to ZERO_ADDRESS for single-condition)
  secondaryOracle:       Address;
  secondaryTriggerPrice: bigint;
  secondaryOp:           ComparisonOp;
  logicOp:               LogicOp;
}

export enum LogicOp {
  AND = 0,
  OR  = 1,
}

export interface Envelope {
  positionCommitment: Hex;     // bytes32
  conditionsHash:     Hex;     // bytes32 — keccak256(abi.encode(conditions))
  intentCommitment:   Hex;     // bytes32 — keccak256(abi.encode(intent))
  capabilityHash:     Hex;     // bytes32 — HashLib.hashCapability(manageCapability)
  expiry:             bigint;
  keeperRewardBps:    number;  // uint16 — max 500 (5%)
  minKeeperRewardWei: bigint;  // uint128
}

// ─────────────────────────────────────────────────────────────────────────────
// Adapter data helpers
// ─────────────────────────────────────────────────────────────────────────────

/** Well-known scope hashes. Use these constants instead of raw keccak256 strings. */
export const SCOPE = {
  VAULT_SPEND:     "0xcf2b67fe6c92e22a25e33d9b6f2b70147c97daeeb305f12d942d74d6af6a9648" as Hex,
  ENVELOPE_MANAGE: "0x78e81be0d551bc08b5dac2017d40b3c0169cad957416370dfca700125f658dd7" as Hex,
} as const;

export const ZERO_HASH = "0x0000000000000000000000000000000000000000000000000000000000000000" as Hex;
export const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000" as Address;

// ─────────────────────────────────────────────────────────────────────────────
// Aave adapter types
// ─────────────────────────────────────────────────────────────────────────────

export enum AaveOp {
  SUPPLY   = 0,
  WITHDRAW = 1,
}
