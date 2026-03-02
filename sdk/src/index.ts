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

// Binius64 prover
export {
  generateComplianceProof,
} from "./prover.js";

export type {
  ReceiptInput,
  ProverRequest,
  ProverResult,
  ProverError,
  ProverResponse,
} from "./prover.js";

// Binius64 proof attestation
export {
  attestationHash,
  signAttestation,
  encodeProofForContract,
} from "./attester.js";

export type { AttestationInput } from "./attester.js";
