/**
 * Atlas Protocol SDK — Binius64 Proof Attester
 *
 * Produces the on-chain attestation for a verified Binius64 proof.
 * The attester signs the (proofDigest, publicInputs) tuple, which
 * BiniusCircuit1Verifier.sol validates on-chain.
 *
 * Usage:
 *   import { signAttestation, encodeProofForContract } from "@atlas-protocol/sdk";
 *
 *   const attestation = await signAttestation(walletClient, {
 *     proofDigest: result.proofDigest,
 *     capabilityHash: "0x...",
 *     n: 4n,
 *     accumulatorRoot: result.finalRoot,
 *     adapterFilter: "0x...",
 *     minReturnBps: 0n,
 *   });
 *
 *   const proofBytes = encodeProofForContract(result.proofDigest, attestation);
 */

import type { WalletClient, Address, Hex } from "viem";
import { keccak256, encodePacked, encodeAbiParameters } from "viem";

// ─────────────────────────────────────────────────────────────────────────────
// Types
// ─────────────────────────────────────────────────────────────────────────────

export interface AttestationInput {
  proofDigest: Hex;
  capabilityHash: Hex;
  n: bigint;
  accumulatorRoot: Hex;
  adapterFilter: Address;
  minReturnBps: bigint;
}

// ─────────────────────────────────────────────────────────────────────────────
// Attestation hash — must match BiniusCircuit1Verifier._attestationHash()
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Compute the attestation message hash.
 * This is the raw hash before EIP-191 prefix (personal_sign adds the prefix).
 */
export function attestationHash(input: AttestationInput): Hex {
  return keccak256(
    encodePacked(
      ["bytes32", "bytes32", "uint256", "bytes32", "address", "uint256"],
      [
        input.proofDigest,
        input.capabilityHash,
        input.n,
        input.accumulatorRoot,
        input.adapterFilter,
        input.minReturnBps,
      ]
    )
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Sign attestation
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Sign a Binius64 proof attestation using the attester's wallet.
 *
 * Uses `personal_sign` (EIP-191) to match the Solidity `ECDSA.recover` +
 * `toEthSignedMessageHash` pattern in BiniusCircuit1Verifier.
 *
 * @returns The 65-byte ECDSA signature (r, s, v).
 */
export async function signAttestation(
  wallet: WalletClient,
  input: AttestationInput
): Promise<Hex> {
  const hash = attestationHash(input);
  return wallet.signMessage({
    account: wallet.account!,
    message: { raw: hash },
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// Encode for contract
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Encode (proofDigest, signature) into the `bytes proof` format expected
 * by BiniusCircuit1Verifier.verify() / CreditVerifier.submitProof().
 */
export function encodeProofForContract(proofDigest: Hex, signature: Hex): Hex {
  return encodeAbiParameters(
    [
      { type: "bytes32", name: "proofDigest" },
      { type: "bytes", name: "signature" },
    ],
    [proofDigest, signature]
  );
}
