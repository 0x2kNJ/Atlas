import type { PublicClient, WalletClient } from "viem";
import { encodeAbiParameters, encodePacked, keccak256, pad } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { ADDRESSES, ANVIL_ACCOUNTS } from "../contracts/addresses";
import { ACCUMULATOR_ABI, CREDIT_VERIFIER_ABI } from "../contracts/abis";

type LogLevel = "info" | "success" | "warn" | "error";

export interface SubmitCreditProofParams {
  publicClient: PublicClient;
  walletClient: WalletClient;
  capabilityHash: `0x${string}`;
  adapterAddr: `0x${string}`;
  log: (level: LogLevel, message: string) => void;
  onProvingStart?: () => void;
  onProvingEnd?: () => void;
}

/**
 * Read on-chain receipts for the given capability + adapter, generate a Binius64
 * compliance proof via the local proof server, have the demo attester sign it,
 * and submit it to CreditVerifier on-chain.
 *
 * Throws on proof server unreachability, prover failure, or reverted TX.
 */
export async function submitCreditProof(params: SubmitCreditProofParams): Promise<void> {
  const {
    publicClient, walletClient, capabilityHash, adapterAddr, log,
    onProvingStart, onProvingEnd,
  } = params;

  log("info", `Reading receipts from SHA-256 accumulator (cap: ${capabilityHash.slice(0, 12)}…)`);

  const [receiptHashes, nullifiers] = await Promise.all([
    publicClient.readContract({
      address: ADDRESSES.ReceiptAccumulator as `0x${string}`,
      abi: ACCUMULATOR_ABI,
      functionName: "getAdapterReceiptHashes",
      args: [capabilityHash, adapterAddr],
    }) as Promise<`0x${string}`[]>,
    publicClient.readContract({
      address: ADDRESSES.ReceiptAccumulator as `0x${string}`,
      abi: ACCUMULATOR_ABI,
      functionName: "getAdapterNullifiers",
      args: [capabilityHash, adapterAddr],
    }) as Promise<`0x${string}`[]>,
  ]);

  const n = BigInt(receiptHashes.length);
  if (n === 0n) {
    log("warn", `No receipts for cap ${capabilityHash.slice(0, 12)}… — did the trigger TX execute?`);
    return;
  }

  const adapterBytes32 = pad(adapterAddr, { size: 32 }) as `0x${string}`;
  const proverReq = {
    capability_hash: capabilityHash,
    receipts: receiptHashes.map((rh, i) => ({
      index: i,
      receipt_hash: rh,
      nullifier: nullifiers[i],
      adapter: adapterBytes32,
    })),
    n_steps: Number(n),
  };

  log("info", `Generating Binius64 compliance proof for ${n} receipt(s)…`);
  onProvingStart?.();

  type ProverResponse = {
    success: boolean;
    final_root?: string;
    proof_digest?: string;
    proof_size_bytes?: number;
    prove_ms?: number;
    verify_ms?: number;
    error?: string;
  };

  let proverResult: ProverResponse;
  try {
    const resp = await fetch("http://localhost:3001/api/prove", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(proverReq),
    });
    proverResult = await resp.json() as ProverResponse;
  } catch (e) {
    onProvingEnd?.();
    throw new Error(`Proof server unreachable — run: node proof-server.mjs\n${e}`);
  }
  onProvingEnd?.();

  if (!proverResult.success) {
    throw new Error(`Prover failed: ${proverResult.error}`);
  }

  const proveMs  = proverResult.prove_ms?.toFixed(0) ?? "?";
  const verifyMs = proverResult.verify_ms?.toFixed(0) ?? "?";
  const proofKiB = proverResult.proof_size_bytes
    ? (proverResult.proof_size_bytes / 1024).toFixed(0)
    : "?";
  log("success", `Binius64 proof: ${proveMs}ms prove, ${verifyMs}ms verify, ${proofKiB} KiB`);

  const proofDigest = proverResult.proof_digest as `0x${string}`;

  // Verify that the prover's final root matches what the on-chain accumulator recorded.
  const onChainRoot = await publicClient.readContract({
    address: ADDRESSES.ReceiptAccumulator as `0x${string}`,
    abi: ACCUMULATOR_ABI,
    functionName: "adapterRootAtIndex",
    args: [capabilityHash, adapterAddr, n],
  }) as `0x${string}`;

  if (onChainRoot.toLowerCase() !== proverResult.final_root!.toLowerCase()) {
    log("warn", `Root mismatch: prover=${proverResult.final_root}, chain=${onChainRoot}`);
  }

  const minReturnBps = 0n;

  // Attestation hash must match BiniusCircuit1Verifier._attestationHash() exactly:
  // keccak256(abi.encodePacked(proofDigest, capHash, n, accRoot, adapterAddr, minReturnBps))
  const attestHash = keccak256(
    encodePacked(
      ["bytes32", "bytes32", "uint256", "bytes32", "address", "uint256"],
      [proofDigest, capabilityHash, n, onChainRoot, adapterAddr, minReturnBps]
    )
  );

  log("info", "Attester signing proof attestation…");
  const attester  = privateKeyToAccount(ANVIL_ACCOUNTS[1].privateKey as `0x${string}`);
  const signature = await attester.signMessage({ message: { raw: attestHash } });

  // Proof encoding: abi.encode(bytes32 proofDigest, bytes signature)
  const proof = encodeAbiParameters(
    [{ type: "bytes32" }, { type: "bytes" }],
    [proofDigest, signature]
  );

  log("info", `Submitting Binius64 attestation on-chain for ${n} receipt(s)…`);
  const hash = await walletClient.writeContract({
    address: ADDRESSES.CreditVerifier as `0x${string}`,
    abi: CREDIT_VERIFIER_ABI,
    functionName: "submitProof",
    args: [capabilityHash, n, adapterAddr, minReturnBps, proof],
  });
  await publicClient.waitForTransactionReceipt({ hash });
  log("success", `Credit proof verified on-chain — tx ${hash.slice(0, 10)}…`);
  log("success", "Credit tier upgraded! Click 'New cycle →' to run again.");
}
