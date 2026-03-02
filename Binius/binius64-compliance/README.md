# binius64-compliance

The active Binius64 compliance prover for Atlas Protocol. Reads execution
receipts, proves a SHA-256 rolling hash chain, and exposes the result for
on-chain credit verification.

## Binaries

| Binary | Entry | Purpose |
|---|---|---|
| `compliance-service` | `src/service.rs` | JSON stdin → proof + digest → JSON stdout |
| `compliance-bench` | `src/main.rs` | Benchmark proving and verification time |

## Circuit (`src/lib.rs`)

The circuit proves `n_steps` (default 64) SHA-256 iterations over a rolling
hash chain of execution receipts.

Each step hashes a 160-byte message:

```
prevRoot(32) | index_LE64(8) | padding(24) | receiptHash(32) | nullifier(32) | adapter(32)
```

This byte layout matches `ReceiptAccumulatorSHA256._sha256RollingStep()` exactly.
Any mismatch between the circuit and the contract would produce a root that
doesn't verify on-chain.

**Public inputs:** `capability_hash` (8 × 32-bit words) and `final_root` (8 × 32-bit words)

**Private inputs:** per-step receipt hashes, nullifiers, and adapter addresses

## Running the service

```bash
cargo build --release

echo '{"capability_hash":"0x...","receipts":[...],"n_steps":1}' \
  | ./target/release/compliance-service
```

Output:

```json
{
  "success": true,
  "final_root": "0x...",
  "proof_digest": "0x...",
  "proof_size_bytes": 290816,
  "prove_ms": 173,
  "verify_ms": 47,
  "total_ms": 220
}
```

The `proof_digest` is `keccak256(proof_bytes)` and is what the attester signs
for `BiniusCircuit1Verifier`.

## Integration

The `ui/proof-server.mjs` HTTP server wraps this binary. The UI calls
`POST http://localhost:3001/api/prove` with the same JSON shape above.

## Dependencies

Dependencies are resolved from the local path `../binius64/` (vendored Binius64
framework). The `rust-toolchain.toml` pins the exact Rust toolchain version
required by the Binius64 API.
