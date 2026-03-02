/**
 * Shared utilities for strategy-graph scenarios.
 * Matches the deterministic hash computation in CapabilityKernel.sol.
 */
import { keccak256, encodeAbiParameters } from "viem";

/** Matches keccak256(abi.encode(position)) in SingletonVault/CapabilityKernel. */
export function computePositionHash(
  owner:  `0x${string}`,
  asset:  `0x${string}`,
  amount: bigint,
  salt:   `0x${string}`,
): `0x${string}` {
  return keccak256(encodeAbiParameters(
    [{ type: "tuple", components: [
      { name: "owner",  type: "address" },
      { name: "asset",  type: "address" },
      { name: "amount", type: "uint256" },
      { name: "salt",   type: "bytes32" },
    ]}],
    [{ owner, asset, amount, salt }],
  ));
}

/**
 * Matches the kernel's output-salt derivation:
 *   nullifier = keccak256(abi.encode(intent.nonce, intent.positionCommitment))
 *   outputSalt = keccak256(abi.encode(nullifier, "output"))
 */
export function computeOutputSalt(
  intentNonce:        `0x${string}`,
  positionCommitment: `0x${string}`,
): `0x${string}` {
  const nullifier = keccak256(encodeAbiParameters(
    [{ type: "bytes32" }, { type: "bytes32" }],
    [intentNonce, positionCommitment],
  ));
  return keccak256(encodeAbiParameters(
    [{ type: "bytes32" }, { type: "string" }],
    [nullifier, "output"],
  ));
}
