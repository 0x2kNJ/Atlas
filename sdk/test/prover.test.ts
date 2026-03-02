/**
 * Binius64 Compliance Prover — SDK integration test
 *
 * Tests the full flow: generate proof → create attestation → encode for contract.
 * Requires the compliance-service binary to be built (cargo build --release).
 */

import { describe, it, expect } from "vitest";
import { resolve } from "node:path";
import { privateKeyToAccount } from "viem/accounts";
import { createWalletClient, http } from "viem";
import { foundry } from "viem/chains";
import {
  generateComplianceProof,
  attestationHash,
  encodeProofForContract,
} from "../src/index.js";
import type { AttestationInput } from "../src/index.js";

const BINARY_PATH = resolve(
  import.meta.dirname ?? ".",
  "../../Binius/binius64-compliance/target/release/compliance-service"
);

const ATTESTER_PK =
  "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80" as const;

describe("Binius64 Compliance Prover", () => {
  it("generates a valid proof for 1 receipt / 4 steps", async () => {
    const result = await generateComplianceProof(
      {
        capabilityHash:
          "0xcacacacacacacacacacacacacacacacacacacacacacacacacacacacacacacaca",
        receipts: [
          {
            index: 0n,
            receiptHash:
              "0x1010101010101010101010101010101010101010101010101010101010101010",
            nullifier:
              "0x2020202020202020202020202020202020202020202020202020202020202020",
            adapter:
              "0x000000000000000000000000abababababababababababababababababababab",
          },
        ],
        nSteps: 4,
      },
      BINARY_PATH
    );

    expect(result.success).toBe(true);
    if (!result.success) return;

    expect(result.finalRoot).toMatch(/^0x[0-9a-f]{64}$/);
    expect(result.proofDigest).toMatch(/^0x[0-9a-f]{64}$/);
    expect(result.proofSizeBytes).toBeGreaterThan(0);
    expect(result.proveMs).toBeGreaterThan(0);
    expect(result.verifyMs).toBeGreaterThan(0);
    expect(result.totalMs).toBeLessThan(10_000); // sanity: under 10s
  }, 30_000);

  it("computes attestation hash deterministically", () => {
    const input: AttestationInput = {
      proofDigest:
        "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      capabilityHash:
        "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      n: 4n,
      accumulatorRoot:
        "0xcccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
      adapterFilter: "0x0000000000000000000000000000000000000000",
      minReturnBps: 0n,
    };

    const hash1 = attestationHash(input);
    const hash2 = attestationHash(input);
    expect(hash1).toBe(hash2);
    expect(hash1).toMatch(/^0x[0-9a-f]{64}$/);
  });

  it("encodes proof for contract submission", () => {
    const proofDigest =
      "0xdddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd" as const;
    const signature = ("0x" + "ab".repeat(65)) as `0x${string}`;

    const encoded = encodeProofForContract(proofDigest, signature);
    expect(encoded).toMatch(/^0x/);
    expect(encoded.length).toBeGreaterThan(66 * 2); // at least proofDigest + sig
  });

  it("full flow: prove → attest → encode", async () => {
    const account = privateKeyToAccount(ATTESTER_PK);
    const wallet = createWalletClient({
      account,
      chain: foundry,
      transport: http(),
    });

    // Generate proof
    const result = await generateComplianceProof(
      {
        capabilityHash:
          "0xcacacacacacacacacacacacacacacacacacacacacacacacacacacacacacacaca",
        receipts: [],
        nSteps: 2,
      },
      BINARY_PATH
    );

    expect(result.success).toBe(true);
    if (!result.success) return;

    // Create attestation
    const input: AttestationInput = {
      proofDigest: result.proofDigest,
      capabilityHash:
        "0xcacacacacacacacacacacacacacacacacacacacacacacacacacacacacacacaca",
      n: 0n,
      accumulatorRoot: result.finalRoot,
      adapterFilter: "0x0000000000000000000000000000000000000000",
      minReturnBps: 0n,
    };

    const signature = await wallet.signMessage({
      account,
      message: { raw: attestationHash(input) },
    });

    // Encode for contract
    const proofBytes = encodeProofForContract(result.proofDigest, signature);
    expect(proofBytes).toMatch(/^0x/);
    expect(proofBytes.length).toBeGreaterThan(200);
  }, 30_000);
});
