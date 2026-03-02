// Binius64 Envelope Protocol Circuits — Research Implementation
//
// RESEARCH ONLY: This crate benchmarks binius64 proving times for envelope-equivalent
// circuits. The Noir + UltraHonk implementation remains the primary production stack.
//
// Circuit design philosophy:
//   - Uses SHA256 as the hash primitive (binius64 is optimized for this)
//   - Production Noir circuits use Poseidon2 over BLS12-381 — the computational
//     structure (Merkle paths, hash preimages, range checks) is equivalent for
//     timing purposes; the hash function constant factor is similar
//   - Fixed Merkle depth = 20 (matches SingletonVault commitment tree)
//   - All circuits use the ExampleCircuit pattern for consistent benchmarking

pub mod common;
pub mod encumber;
pub mod settle;
pub mod spend;
