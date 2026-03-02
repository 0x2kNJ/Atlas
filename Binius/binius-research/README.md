# Binius Research

This directory contains research and exploratory work from before the ZK stack
was migrated to the `binius64-compliance` implementation. It is retained for
historical reference.

## Active codebase

The production Binius64 prover lives at:

```
Binius/binius64-compliance/   — Rust crate (service binary + compliance circuit)
Binius/binius64/              — vendored Binius64 framework (path dependency)
```

The compliance circuit proves a SHA-256 rolling receipt hash chain of up to 64
steps and exposes public inputs `(capability_hash, final_root)` that match the
`ReceiptAccumulatorSHA256` contract exactly.

## What is in this directory

| Path | Status | Notes |
|---|---|---|
| `envelope-circuits/src/compliance.rs` | Active | Earlier Binius m3 research circuit (kept for comparison) |
| `envelope-circuits/src/compliance_bench.rs` | Active | Benchmark binary |
| `envelope-circuits/src/legacy/` | Archived | Old circuit implementations superseded by `binius64-compliance` |
| `evm-verifier/` | Research | Solidity Binius64 verifier — not yet deployed, under development |
| `wasm-prover/` | Research | WASM-compiled prover (experimental browser-side proving) |

## Building

These crates use a separate `rust-toolchain.toml` to pin the Rust toolchain
version required by the Binius m3 API. Run from this directory:

```bash
cargo build --release
```

The `evm-verifier/` subdirectory is a standalone Foundry project:

```bash
cd evm-verifier && forge build
```
