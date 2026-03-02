# binius-groth16-wrapper

Off-chain aggregator that wraps N binius64 proofs into a single PLONK proof,
reducing on-chain settlement cost to ~3,500 gas per user operation.

## Performance headline (Production v3 — current)

| Stage | Proof gen | User-facing latency | On-chain gas |
|---|---|---|---|
| Barretenberg UltraHonk | 1–3 s | 12 s (block) | ~240,000 |
| binius64 native (Solidity) | **100 ms** | 12 s (block) | ~540,000,000 ❌ |
| **binius64 + PLONK batch (v3)** | **100 ms** | **~100 ms (soft)** | **~3,500 ✓** |

The user generates a binius64 proof in 100 ms on their own device.  The
aggregator collects N=100 proofs and runs the PLONK prover on a server GPU.

## Constraint budget (Production v3 — full MiMC transcript + MiMC Merkle)

| Component | Per-proof constraints | N=100 total |
|---|---|---|
| MiMC transcript (Sumcheck × 14 + RS + fold × 4 + query × 232) | ~150,000 | ~15M |
| MiMC Merkle leaf hash (232 queries × 16 elements) | ~1,262,000 | ~126M |
| MiMC Merkle path (232 queries × depth 20) | ~1,578,000 | ~158M |
| FRI fold (232 queries × GF128 ops) | ~5,336,000 | ~534M |
| Sumcheck + ring-switch GF128 arithmetic | ~22,400 | ~2.2M |
| Batch transcript | ~371 | ~37k |
| Shared lookup tables (byteXorTable) | — | ~65k |
| **Total** | **~8.35M** | **~835M** |

### Proving time trajectory

| Version | Circuit design | Constraints (N=100) | GPU time (4M c/s) |
|---|---|---|---|
| Production v1 | SHA256 everywhere | ~15.7B | ~65 min |
| Production v2 | MiMC Merkle + SHA256 transcript | ~1.48B | ~6 min |
| **Production v3 (this)** | **Full MiMC (Merkle + transcript)** | **~835M** | **~3.5 min** |

## Architecture

```
User device (100 ms)                  Aggregator server (~3.5 min GPU)
────────────────────                  ──────────────────────────────────
binius64 Rust prover                  BatchBiniusVerifier gnark circuit
  ↓                                     ├── GF128 gadget (binary tower Karatsuba)
  proof_i.json  ─────────────────→      ├── MiMC Merkle verifier (field-element nodes)
                                         ├── FRI fold verifier (GF128 ops)
                                         ├── MiMC Fiat-Shamir transcript
                                         ├── Sumcheck verifier (14 rounds)
                                         ├── Ring-switch gadget
                                         └── PLONK prover → batch.plonk
                                                   ↓
                                          Ethereum/L2 ← ~350k gas total
```

## Project layout

```
circuit/
  gf128/          GF(2^128) arithmetic gadgets (lookup tables, Karatsuba tower)
  hash/           MiMC-BN254 leaf hash + field element packing helpers
  transcript/     MiMCState Fiat-Shamir transcript (Production v3)
                  State     SHA256 transcript (retained for reference)
  merkle/         FieldPath / VerifyField (MiMC); Path / Verify (SHA256 — legacy)
  fri/            FRI fold gadget (VerifyMiMCQuery)
  sumcheck/       Sumcheck protocol verifier (14 rounds, GF128)
  ringswitch/     Ring-switch reduction gadget
  circuit.go      BatchBiniusVerifier top-level circuit

aggregator/       Off-chain batch builder (parses proofs, builds gnark witness)

cmd/
  setup/          One-time key generation (pk.bin, vk.bin, ccs.bin)
  prove/          Batch PLONK prover
  gentest/        Synthetic proof fixture generator for E2E testing
  export/         Export Solidity verifier (BiniusBatchVerifier.sol)
```

## Quick start

### 1. One-time setup (generate proving/verification keys)

```bash
go run ./cmd/setup --batch-size 100 --out-dir ./keys
```

Compiles the ~835M-constraint PLONK circuit and generates the proving and
verification keys.  Expected time: 5–20 min, 32–64 GB RAM.

> **Production note**: Replace the test SRS (`unsafekzg`) with a real
> Powers-of-Tau ceremony SRS.  The Hermez ceremony (ppot28) is compatible.

### 2. Prove a batch

```bash
# Put proof_0.json ... proof_99.json in ./batch_proofs/
go run ./cmd/prove \
  --pk ./keys/pk.bin \
  --ccs ./keys/ccs.bin \
  --proofs-dir ./batch_proofs \
  --out ./batch.plonk
```

Expected proving time: **~3.5 minutes on a server GPU (RTX 4090 or A100)**.

### 3. Export the Solidity verifier

```bash
go run ./cmd/export --vk ./keys/vk.bin --out ./BiniusBatchVerifier.sol
```

Deploy `BiniusBatchVerifier.sol` once.  The public input is now a **single
BN254 field element** (the MiMC batch digest), cheaper to check on-chain than
the previous 32-byte SHA256 digest.

## Gas model

| Item | Gas |
|---|---|
| PLONK verifier (one pairing + 5 MSMs) | ~350,000 |
| Batch size N=100 | 3,500 per proof |
| Batch size N=500 | 700 per proof |
| Barretenberg UltraHonk (reference) | 240,000 per proof |

## Fiat-Shamir transcript (Production v3)

All challenges are derived from **MiMC-BN254** in Miyaguchi–Preneel streaming mode
(state h = 0 initially; each absorbed element: h = h + E(h, m) + m):

```
AbsorbVar(traceRoot)       [field element — MiMC Merkle root]
for 14 sumcheck rounds:
    AbsorbVars(lo, hi)     [GF128 coeff × 3, lo+hi each = 6 field elements]
    ChallengeGF128()       [→ lo = bits[0..63], hi = bits[64..127] of h]
AbsorbVars(finalLo, finalHi)  [sumcheck final evaluation]
ChallengeGF128()           [ring-switch challenge]
for 4 fold challenges:
    ChallengeGF128()
for 232 queries:
    ChallengeBits(10)      [→ coset index = low 10 bits of challenge]
```

Batch digest:
```
MiMC( packed(publicInputsHash[0]), traceRoot[0],
      packed(publicInputsHash[1]), traceRoot[1], ... )
```

where `packed(SHA256_bytes)` = Horner32(SHA256_bytes) mod p.

**Go-side simulation note**: `gnark-crypto`'s MiMC `Write()` silently drops
elements ≥ field modulus p.  The circuit auto-reduces via field arithmetic.
Always apply `fr.Element.SetBytes` to reduce inputs mod p before writing in
Go-side simulations (see `aggregator/aggregator.go: ComputeBatchPublicInputsHash`).

## Protocol change requirements (before production)

This circuit implements Production v3.  Two coordinated changes are required
before production deployment:

| Component | Required change |
|---|---|
| **Rust binius64 prover** | Switch Merkle tree to MiMC-BN254 (Miyaguchi–Preneel) |
| **Rust binius64 prover** | Switch Fiat-Shamir transcript to MiMC-BN254 |
| **BiniusBatchVerifier.sol** | Verify MiMC Merkle paths (not SHA256/BiniusCompress) |
| **BiniusBatchVerifier.sol** | Batch digest check: MiMC field element (not SHA256 32 bytes) |

Until these changes land, the circuit is structurally complete and all E2E tests
pass (`go test ./... ` — Groth16 + PLONK backends), but the binius64 Rust prover
will produce proofs that don't satisfy the circuit.

## Challenge derivation in gnark-crypto

```go
// ChallengeGF128 — matches the in-circuit MiMCState.ChallengeGF128()
func challengeGF128(h hash.Hash) (lo, hi uint64) {
    b := h.Sum(nil)  // Miyaguchi-Preneel of current data, flushes buffer
    h.Write(b)       // seed for next round
    v := new(big.Int).SetBytes(b)
    lo = v.Uint64()                              // bits [0..63]
    hi = new(big.Int).Rsh(v, 64).Uint64()       // bits [64..127]
    return
}
```

## MiMC binary tower

The GF(2^128) multiplication in `circuit/gf128/gf128.go` implements the
binius canonical binary tower exactly:

| Level | Field | Irreducible | α |
|---|---|---|---|
| 1 | GF(2²) | x²+x+1 | 1 ∈ GF(2) |
| 2 | GF(2⁴) | x²+x+β | β=2 ∈ GF(4) |
| 3 | GF(2⁸) | x²+x+γ | γ=4 ∈ GF(16) |
| 4 | GF(2¹⁶) | x²+x+δ | δ=16 ∈ GF(256) |
| 5 | GF(2³²) | x²+x+ε | ε=0x0100 ∈ GF(2¹⁶) |
| 6 | GF(2⁶⁴) | x²+x+ζ | ζ=0x00010000 ∈ GF(2³²) |
| 7 | GF(2¹²⁸) | x²+x+η | η=0x0000000100000000 ∈ GF(2⁶⁴) |

All 6 constant-arithmetic tests in `circuit/gf128/gf128_test.go` pass.

## Deployment targets

| Environment | Gas limit | Recommended batch N | Gas per op |
|---|---|---|---|
| Mainnet | 30M | 1 (batch overhead) | ~350k |
| Base / Optimism | 60M | 100 | ~3,500 |
| Arbitrum One | ∞ (no block limit) | 500 | ~700 |
| L3 appchain (Envelopes) | ∞ | 1,000+ | <350 |

## Trusted setup

**Short answer**: yes, PLONK with KZG requires a trusted setup.

| Property | This project | Groth16 (per-circuit) |
|---|---|---|
| Ceremony type | Universal (Powers of Tau) | Per-circuit |
| Ceremony needed per circuit change | No | Yes |
| Existing ceremony usable | Yes (Hermez ppot28) | No |
| Participants in largest ceremony | 141,000+ (Ethereum KZG) | N/A |
| Trust assumption | ≥1 of N participants honest | ≥1 of N participants honest |

## Test status

```
go test ./...
```

- `circuit/`: E2E solve test passes on **Groth16** and **PLONK** backends ✓
- `circuit/gf128/`: All 6 constant-arithmetic tests pass ✓
- All packages build with `go build ./...` ✓
