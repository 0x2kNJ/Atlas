/**
 * Atlas Protocol SDK — Position Helpers
 *
 * Utilities for computing position commitment hashes and building
 * the Position struct used in vault interactions and intent submission.
 */

import { encodeAbiParameters, keccak256, type Address, type Hex } from "viem";
import type { Position } from "./types.js";

/**
 * Compute the position commitment hash.
 * Matches: keccak256(abi.encode(owner, asset, amount, salt)) in SingletonVault.
 */
export function hashPosition(position: Position): Hex {
  return keccak256(
    encodeAbiParameters(
      [
        { type: "address" }, // owner
        { type: "address" }, // asset
        { type: "uint256" }, // amount
        { type: "bytes32" }, // salt
      ],
      [position.owner, position.asset, position.amount, position.salt]
    )
  );
}

/**
 * Build a Position struct from deposit parameters.
 * Salt should be a random bytes32 unique per deposit to avoid hash collisions.
 */
export function buildPosition(
  owner:  Address,
  asset:  Address,
  amount: bigint,
  salt:   Hex
): Position {
  return { owner, asset, amount, salt };
}

/**
 * Generate a random salt for a new deposit.
 * Uses crypto.getRandomValues for browser and Node.js compatibility.
 */
export function randomSalt(): Hex {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  return `0x${Array.from(bytes).map(b => b.toString(16).padStart(2, "0")).join("")}` as Hex;
}

/**
 * Compute the nullifier for an intent.
 * Matches: keccak256(abi.encode(intent.nonce, intent.positionCommitment)) in CapabilityKernel.
 */
export function hashNullifier(intentNonce: Hex, positionCommitment: Hex): Hex {
  return keccak256(
    encodeAbiParameters(
      [{ type: "bytes32" }, { type: "bytes32" }],
      [intentNonce, positionCommitment]
    )
  );
}

/**
 * Compute the output position salt used by the kernel after executing an intent.
 * Matches: keccak256(abi.encode(nullifier, "output")) in CapabilityKernel.executeIntent().
 */
export function outputPositionSalt(nullifier: Hex): Hex {
  return keccak256(
    encodeAbiParameters(
      [{ type: "bytes32" }, { type: "string" }],
      [nullifier, "output"]
    )
  );
}
