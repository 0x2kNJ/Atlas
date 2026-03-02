/**
 * Atlas Protocol SDK
 *
 * Public API surface. Import from here, not from individual modules.
 */

// Types
export type {
  Position,
  Constraints,
  Capability,
  Intent,
  Conditions,
  Envelope,
} from "./types.js";

export {
  ComparisonOp,
  LogicOp,
  AaveOp,
  SCOPE,
  ZERO_HASH,
  ZERO_ADDRESS,
} from "./types.js";

// EIP-712 hashing (off-chain, matches HashLib.sol)
export {
  ATLAS_TYPES,
  kernelDomain,
  registryDomain,
  hashAddressArray,
  hashConstraints,
  hashCapability,
  hashIntent,
  hashEnvelope,
} from "./eip712.js";

// Position utilities
export {
  hashPosition,
  buildPosition,
  randomSalt,
  hashNullifier,
  outputPositionSalt,
} from "./position.js";

// Signing
export {
  signCapability,
  signManageCapability,
  signIntent,
} from "./signing.js";

// Builders
export {
  noConstraints,
  buildCapability,
  buildManageCapability,
  buildIntent,
  buildEnvelope,
  hashConditions,
  hashIntentCommitment,
} from "./builders.js";

// Adapter data encoding
export {
  FEE,
  uniswapSingleHop,
  uniswapMultiHop,
  buildUniswapPath,
  clawloanRepayStatic,
  clawloanRepayLive,
  aaveSupply,
  aaveWithdraw,
} from "./adapters.js";

export type { FeeTier } from "./adapters.js";
