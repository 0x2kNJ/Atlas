/**
 * Atlas Protocol SDK — Binius64 Compliance Prover
 *
 * Spawns the Rust `compliance-service` binary to generate and verify
 * Binius64 proofs for the rolling-root compliance circuit.
 *
 * Usage:
 *   import { generateComplianceProof } from "@atlas-protocol/sdk";
 *
 *   const result = await generateComplianceProof({
 *     capabilityHash: "0xca...",
 *     receipts: [{ index: 0n, receiptHash: "0x10...", nullifier: "0x20...", adapter: "0xab..." }],
 *     nSteps: 64,
 *   });
 *
 *   console.log(result.proveMs);     // ~173
 *   console.log(result.proofDigest); // "0x..."
 */

import { execFile } from "node:child_process";
import { resolve } from "node:path";
import type { Hex } from "viem";

// ─────────────────────────────────────────────────────────────────────────────
// Types
// ─────────────────────────────────────────────────────────────────────────────

export interface ReceiptInput {
  index: bigint;
  receiptHash: Hex;
  nullifier: Hex;
  adapter: Hex;
}

export interface ProverRequest {
  capabilityHash: Hex;
  receipts: ReceiptInput[];
  /** Number of hash-chain steps (default: 64 = MAX_N). */
  nSteps?: number;
}

export interface ProverResult {
  success: true;
  finalRoot: Hex;
  /** SHA-256 digest of the raw proof bytes. Use keccak256 on the TS side for on-chain submission. */
  proofDigest: Hex;
  proofSizeBytes: number;
  proveMs: number;
  verifyMs: number;
  totalMs: number;
}

export interface ProverError {
  success: false;
  error: string;
}

export type ProverResponse = ProverResult | ProverError;

// ─────────────────────────────────────────────────────────────────────────────
// Default binary path — relative to the SDK package root
// ─────────────────────────────────────────────────────────────────────────────

const DEFAULT_BINARY = resolve(
  import.meta.dirname ?? ".",
  "../../Binius/binius64-compliance/target/release/compliance-service"
);

// ─────────────────────────────────────────────────────────────────────────────
// Core function
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Generate and verify a Binius64 compliance proof.
 *
 * Spawns the Rust binary, passes receipt data as JSON via stdin,
 * and returns the proof result (digest, timing, size).
 *
 * @param request - Receipt data and configuration
 * @param binaryPath - Optional override for the compliance-service binary path
 */
export async function generateComplianceProof(
  request: ProverRequest,
  binaryPath?: string
): Promise<ProverResponse> {
  const bin = binaryPath ?? DEFAULT_BINARY;

  const input = JSON.stringify({
    capability_hash: request.capabilityHash,
    receipts: request.receipts.map((r) => ({
      index: Number(r.index),
      receipt_hash: r.receiptHash,
      nullifier: r.nullifier,
      adapter: r.adapter,
    })),
    n_steps: request.nSteps ?? 64,
  });

  return new Promise((resolve, reject) => {
    const child = execFile(bin, { maxBuffer: 10 * 1024 * 1024 }, (err, stdout, stderr) => {
      if (err) {
        reject(new Error(`Prover binary failed: ${err.message}\nstderr: ${stderr}`));
        return;
      }

      try {
        const raw = JSON.parse(stdout.trim());
        if (raw.success) {
          resolve({
            success: true,
            finalRoot: raw.final_root as Hex,
            proofDigest: raw.proof_digest as Hex,
            proofSizeBytes: raw.proof_size_bytes,
            proveMs: raw.prove_ms,
            verifyMs: raw.verify_ms,
            totalMs: raw.total_ms,
          });
        } else {
          resolve({ success: false, error: raw.error ?? "Unknown prover error" });
        }
      } catch {
        reject(new Error(`Failed to parse prover output: ${stdout}`));
      }
    });

    child.stdin?.write(input);
    child.stdin?.end();
  });
}
