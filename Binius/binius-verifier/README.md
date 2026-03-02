# Binius64 Solidity Verifier — Research Implementation

A Solidity implementation of the verification logic for [Binius64](https://github.com/binius-zk/binius64) SNARK proofs on the EVM. This is a **research prototype** — the first known attempt at an on-chain verifier for the binary tower field SNARK.

## Architecture

```
Binius64Verifier.sol           ← Top-level orchestrator
├── SumcheckVerifier.sol       ← Sumcheck protocol (shift, MUL, AND reductions)
│   └── FiatShamirTranscript.sol  ← Keccak256 Fiat-Shamir
├── BiniusPCSVerifier.sol      ← Polynomial commitment scheme
│   ├── FRIVerifier.sol        ← Binary-field FRI (BaseFold)
│   │   └── MerkleVerifier.sol ← Merkle authentication paths
│   └── SumcheckVerifier.sol   ← Ring-switching reduction
└── BinaryFieldLib.sol         ← Tower field arithmetic GF(2) → GF(2^128)
```

## Binary Tower Field

The field arithmetic matches the **canonical Binius tower** from [DP23](https://eprint.iacr.org/2023/1784), Section 2.3:

```
T_0 = GF(2)
T_{k+1} = T_k[β_k] / (β_k² + β_{k-1}·β_k + 1)
```

This is **not** the Artin-Schreier tower `X² + X + α`. The irreducible at each level is `X² + β_{k-1}·X + 1`, matching the binius64 Rust crate's `pairwise_recursive_arithmetic.rs`.

Key recursive operations:
- **mulAlpha_k(a₀, a₁)** = `(a₁, a₀ ⊕ mulAlpha_{k-1}(a₁))`
- **multiply**: `lo = p₀ ⊕ p₁`, `hi = (pm ⊕ p₀ ⊕ p₁) ⊕ mulAlpha(p₁)`
- **square**: `lo = sq(a₀) ⊕ sq(a₁)`, `hi = mulAlpha(sq(a₁))`

## Gas Benchmarks

All benchmarks measured via Foundry (`forge test -vv`), Solc 0.8.30, with anti-constant-folding inputs.

### Field Arithmetic — Four Tiers

| Operation | Baseline | `via-ir` | Yul asm + tables | Yul + tables + `via-ir` | Best speedup |
|-----------|----------|----------|-----------------|------------------------|-------------|
| `mulGF2_64` | 115,389 | 61,130 | — | — | 1.9× |
| `mulGF2_128` | 347,145 | 183,932 | 31,949 | **25,775** | **13.5×** |
| `squareGF2_128` | 32,623 | 14,369 | 20,634 | **11,720** | **2.8×** |
| `invGF2_64` | 2,570,188 | 1,234,516 | — | — | 2.1× |
| `invGF2_128` | 10,177,650 | 4,860,435 | — | — | 2.1× |
| **100× inv (batch)** | **1,017,774,147** | — | **19,870,145** | **12,706,372** | **80×** |

**`mulGF2_128` improvements explained:**
- **`via-ir`** (1.9×): Yul optimizer inlines the recursive call tree
- **Yul asm** (10.9×): All 7 tower levels hand-inlined in assembly, eliminating Solidity ABI overhead
- **Zech tables** (inside Yul): GF(2⁸) base replaced with 3 MLOAD lookups instead of 63 XOR/AND ops
- **Combined** (13.5×): All three together

**Batch inversion (Montgomery's trick):**
- 100 GF(2¹²⁸) inversions: 1,017M gas (naive) → 12.7M gas (batch) = **80× faster**
- Formula: 1 `invGF2_128` + 3(n−1) `mulGF2_128` instead of n × `invGF2_128`
- For FRI's ~1280 inversions per proof: replaces ~13B gas budget with ~400M gas

**Scaling pattern (baseline)**: Each tower level roughly 3× the previous (Karatsuba: 3 sub-muls per level, 3⁷ = 2187 GF(2²) multiplications for a single GF(2¹²⁸) multiply).

### Protocol Components (measured, `Binius64NativeVerifier` stack)

| Operation | Gas | Notes |
|-----------|-----|-------|
| `BiniusCompress.compress` | 62,066 | Manual SHA256 rounds, custom IV |
| `MerkleLib.verify` depth 1 | 532 | SHA256 precompile |
| `MerkleLib.verify` depth 20 | 7,587 | 20 × SHA256 precompile |
| `FRIFold.foldChunk` (16 vals, 4 rounds) | 625,470 | 64 GF128.mul @ ~10k each |
| `FRIFold.foldInterleaved` (16 vals) | ~460,000 | 46 GF128.mul |
| `RingSwitch._transpose` (128×128) | 699,597 | Butterfly O(n log n), 448 ops |
| `BaseFold._hashCoset` | ~10,500 | **Assembly bswap128 + SHA256 precompile** |
| Sumcheck verify (20 vars) | 14,812,264 | 20 rounds of degree-2 check |

### Estimated Full Verification Cost (Encumber circuit, 232 queries)

Bottom-up model; dominant cost is the FRI query phase.

| Component | Per-unit gas | Count | Total |
|-----------|-------------|-------|-------|
| BiniusCompress (Merkle path, oracle0) | 62,066 | 232 × 6 | ~86M |
| BiniusCompress (Merkle path, oracle1) | 62,066 | 232 × 2 | ~29M |
| `_hashCoset` (SHA256 of 256-byte coset) | ~10,500 | 232 × 3 | ~7.3M |
| `foldChunk` (NTT fold) | 625,470 | 232 × 2 | ~290M |
| `foldInterleaved` (interleaved fold) | ~460,000 | 232 × 1 | ~107M |
| Sumcheck + Ring-switch + early phases | — | — | ~20M |
| **Grand total (N=232, 100-bit security)** | | | **~540M** |

**Mainnet (30M block) is not feasible** for full 232-query proofs in a single transaction.

### Deployment Targets

| Environment | Gas limit | N_QUERIES recommended | Security |
|-------------|-----------|----------------------|----------|
| Mainnet (single tx) | 30M | ❌ not viable | — |
| Base / Optimism | 60M | ❌ not viable | — |
| Arbitrum One (no block limit) | ~∞ | 232 | 100-bit |
| L3 appchain / dedicated rollup | ~∞ | 232 | 100-bit |
| Future: CLMUL precompile (EIP-7762) | 30M | 80 | ~87-bit |

**With a CLMUL precompile** GF128.mul drops from ~10k gas to ~200 gas, reducing
`foldChunk` from 625k → ~13k and bringing the 80-query total to ~50M gas — within
the Arbitrum One single-tx budget and close to Base block limits.

**Configuring query count**: pass `nFriQueries` to the `ConstraintSystemParams`
constructor.  The Rust prover must be compiled with the same value.

```solidity
Binius64NativeVerifier v = new Binius64NativeVerifier(
    Binius64NativeVerifier.ConstraintSystemParams({
        nWitnessWords: 1 << 18,  // 2^18 for Encumber
        nPublicWords:  128,
        logInvRate:    1,
        nFriQueries:   80         // 87-bit security, ~190M gas on Arbitrum
    })
);
```
| **Total** | **~990M** | **~530M** | **~71M** |

The dramatic FRI improvement comes from Montgomery batch inversion replacing ~1280 individual `invGF2_128` calls
(~13B gas) with 1 inversion + 3837 fast multiplications using `BinaryFieldLibOpt.mulGF2_128` (~400M gas → ~42M gas with tables).

Both remain above the Ethereum L1 block gas limit (30M). The optimizations give **~1.9× improvement**
but the structural bottleneck — no native binary field multiply on EVM — requires an EIP to close.

| Target | Gas budget | Tier 1 only | Tier 1+2 (all SW opts) |
|--------|-----------|-------------|------------------------|
| Ethereum L1 | 30M/block | No (530M) | No (71M) |
| Optimism / Base | 100M/tx | No (530M) | **Borderline (71M)** |
| Arbitrum (high-gas tx) | 1B gas/tx | Yes | **Yes ✓** |
| With CLMUL EIP | — | ~500K | **~500K ✓** |

## Optimization Roadmap

### Tier 1: Done (1.9–13.5× improvement)

1. **`via-ir` + optimizer** (`FOUNDRY_PROFILE=optimized`): Solc's Yul optimizer flattens the deep recursive call tree. Gives ~1.9× on all operations. Enable with `optimizer = true; via_ir = true` in `foundry.toml`.

2. **Inline Yul assembly** (`BinaryFieldLibOpt.sol`): Hand-written assembly that explicitly inlines all 7 tower levels, eliminating Solidity ABI encoding and return-value stack management.

3. **GF(2⁸) Zech logarithm tables** (baked into `BinaryFieldLibOpt.sol`): Generator g=19, tables exhaustively verified against BinaryFieldLib. Replaces the 3-level recursive base (63 XOR/AND ops per GF(2⁸) multiply) with 3 MLOAD lookups. Combined with Yul assembly + `via-ir`: **13.5× for mul128**.

4. **Montgomery batch inversion** (`BinaryFieldLibOpt.batchInvertGF2_128`): Replaces n individual inversions with 1 inversion + 3(n−1) multiplications. **51× faster for 100 elements; ~80× with via-ir**. Critical for FRI which performs ~1280 inversions per proof.

### Tier 2: Implementable now (est. additional 3–10×)

3. **GF(2⁸) lookup table**: Replace the 3-level base recursion with a 256-entry Zech logarithm table stored in bytecode (CODECOPY to memory at construction). `mul8(a,b) = exp[(log[a] + log[b]) % 255]`. Collapses 3 tower levels into 3 MLOADs — estimated **4× improvement** on mul128.

4. **Batch inversion (Montgomery's trick)**: Replace per-element inversions in FRI with one inversion + 3(n-1) multiplications. FRI has 64 queries × 20 rounds = 1280 inversions. Replaces `1280 × invGF2_128` (~13B gas) with `1 × invGF2_128 + 3839 × mulGF2_128` (~605M gas) — **22× improvement** on the inversion budget alone.

5. **Precomputed FRI domain**: The FRI domain points `s_i` are deterministic per circuit size. They can be hardcoded as a calldata array, replacing on-the-fly computation.

### Tier 3: Requires EIP (1000×+ improvement)

6. **EIP for CLMUL (Carry-Less Multiply)**: A precompile or opcode for binary field multiplication would reduce `mulGF2_128` from ~155K gas to ~100 gas. This alone makes the verifier L1-feasible.

   Proposed: `CLMUL(a, b) → a ×_{GF(2)[X]} b` as a new EVM opcode costing ~8 gas (similar to MULMOD), plus `CLMULMOD(a, b, poly)` for field reduction.

7. **Binary field batch precompile**: A precompile accepting a batch of (op, a, b) tuples and executing them natively. Would make FRI's 1280 multiplications a single cheap precompile call.

### L2 Deployment

On L2s (Arbitrum, Optimism, Base), the gas cost is dominated by calldata, not execution. The proof size for Binius64 is ~50-100 KB, costing:
- **Calldata**: ~50KB × 16 gas/byte = ~800K gas
- **Execution (current)**: ~530M gas — too expensive
- **Execution (with Tier 2 optimizations)**: estimated ~50-100M gas — feasible on Arbitrum

## Research Findings

### Why Binary Field Arithmetic Is Expensive on EVM

The EVM operates natively on 256-bit prime field elements (mod p for secp256k1/BN254). Binary field arithmetic (XOR-based) requires:

1. **No native CLMUL**: Carry-less multiplication must be decomposed into bit operations, requiring O(n²) EVM operations for n-bit fields.

2. **Recursive tower overhead**: Each tower level requires 3 sub-multiplications (Karatsuba) + 1 mulAlpha. For GF(2¹²⁸), this recurses 7 levels deep → 3⁷ = 2187 base multiplications.

3. **Function call overhead**: Solidity's internal function calls add ~100 gas each for stack management. With thousands of recursive calls, this accumulates.

### Comparison with Existing Verifiers

| System | Field | Verify Gas (L1) | Proof Size |
|--------|-------|-----------------|------------|
| Groth16 (BN254) | Prime 254-bit | ~220K | 128 bytes |
| PLONK (BN254) | Prime 254-bit | ~300K | ~1.5 KB |
| UltraHonk (BLS12-381) | Prime 381-bit | ~270K* | ~2 KB |
| **Binius64 (this, unopt.)** | **Binary 128-bit** | **~990M** | **~50-100 KB** |
| **Binius64 (est. w/ CLMUL EIP)** | **Binary 128-bit** | **~500K** | **~50-100 KB** |

*With EIP-2537 precompiles (Pectra).

### Key Takeaway

Binius64 verification is **cryptographically sound and structurally feasible** on EVM, but the lack of native binary field arithmetic makes it **3-4 orders of magnitude** more expensive than pairing-based SNARKs. A CLMUL precompile would close this gap entirely.

## Test Suite

```bash
forge test -vv                          # All tests, no optimizer
FOUNDRY_PROFILE=optimized forge test    # All tests, via-ir + optimizer
forge test --match-path test/GasBench.t.sol -vvv          # Gas comparison benchmarks
forge test --match-path test/BinaryFieldLibOpt.t.sol -vvv # Yul assembly correctness + bench
```

### Test Coverage

- **BinaryFieldLib**: 43 tests — exhaustive correctness for GF(2²) through GF(2¹²⁸) (identity, commutativity, associativity, Fermat's theorem, square-vs-multiply, inverse, distributivity)
- **FiatShamirTranscript**: 8 tests — determinism, domain separation, squeeze ranges
- **SumcheckVerifier**: 6 tests — 1-var trivial, 2-var product, round evaluation, gas benchmark
- **MerkleVerifier**: 5 tests — depth-1, depth-2, wrong leaf rejection, batch verify
- **FRIVerifier**: 4 tests — binary fold correctness and gas

## Production Paths (No EIP Required)

The EIP process for adding a CLMUL opcode to Ethereum mainnet takes 2-4 years. Two paths
achieve comparable or better gas costs **right now**, without waiting:

### Path A — zkVM Wrapping (L1 mainnet today, ~280K gas)

Run the Binius64 verifier off-chain inside [SP1](https://github.com/succinctlabs/sp1) or
[Risc0](https://github.com/risc0/risc0). SP1 wraps the execution in a Groth16 proof.
On-chain, only verify the Groth16 proof — a single pairing check.

```
                            OFF-CHAIN (prover)                ON-CHAIN (~280K gas)
  ┌─────────────┐   proof    ┌──────────────────────┐        ┌──────────────────────┐
  │ Your circuit│ ────────── │  SP1 guest program   │  π_g16 │ Binius64SP1Verifier  │
  │ (Binius64)  │            │  (runs Binius64       │ ──────►│ .verify(publicValues,│
  └─────────────┘            │   verifier in RISC-V) │        │  sp1Proof)           │
                             └──────────────────────┘        └──────────────────────┘
```

**Files:**
- `src/Binius64SP1Verifier.sol` — on-chain contract (~280K gas)
- `sp1-guest/src/main.rs` — SP1 guest program (runs the binius64 Rust crate)

**Setup:**
```bash
# Install SP1 toolchain
curl -L https://sp1up.succinct.xyz | bash && sp1up

# Build the guest program (produces the vkey hash for the constructor)
cd sp1-guest && cargo prove build
# Copy the printed vkey hash into Binius64SP1Verifier constructor arg

# Prove (dev mode, fast, no real proof)
cargo prove execute --input proof.json

# Prove (production Groth16, ~30s on 32-core machine or via Succinct's hosted prover)
cargo prove --groth16 --input proof.json
```

**Trade-offs:**
| | Native (71M gas) | SP1 Groth16 (~280K gas) |
|-|------------------|-------------------------|
| L1 feasible | No | **Yes** |
| Proving time | 0 (verify only) | 10-30s off-chain |
| Proof size | ~50-100KB calldata | ~800 bytes calldata |
| Prover centralization | None | Prover must be trusted OR use decentralized prover network |
| Dependencies | None | SP1 verifier contract |

---

### Path B — Custom L2 Precompile (Arbitrum Orbit / OP Stack, ~100 gas per mul)

Add a native CLMUL precompile to your own L2/appchain. You don't need Ethereum's permission —
you control your L2's execution environment.

**Files:**
- `src/CLMULPrecompile.sol` — the interface + software fallback + auto-routing library
- See the file's inline comments for Arbitrum Orbit (Go) and OP Stack (op-geth) implementation

**Architecture:**
```
All contracts use CLMULRouter.mulGF2_128(a, b)
                      │
          ┌───────────┴────────────┐
          │ extcodesize(0xA0) > 0? │
          └───────────┬────────────┘
               Yes ◄──┤──► No
                │             │
         staticcall to    BinaryFieldLibOpt
         address 0xA0    (Yul + Zech tables,
         (native CLMUL)   25,775 gas)
         (~100 gas)
```

**Result on your Orbit chain:**
- `mulGF2_128`: ~100 gas (vs 25,775 software, vs 155K baseline)
- Full proof verification: **~500K gas** (same as the eventual EIP would give)
- Works immediately, no governance, no EIP

**Result on regular EVM (testnet, mainnet without EIP):**
- Automatic fallback to Yul+Zech tables (25,775 gas)
- Zero code changes when you later enable the native precompile

---

### Path C — EIP (eventual, 2-4 years)

Propose and champion an EIP adding `CLMUL(a, b)` as an EVM opcode costing ~8 gas.
Path A and B are fully compatible with this: once the EIP lands, update `CLMULRouter`
to use the opcode instead of `address(0xA0)`, and retire the SP1 wrapper if desired.

**Proposed EIP spec:**
```
Opcode: CLMUL128 (0xBn TBD)
Input:  a (256-bit, treated as 128-bit GF(2^128) element)
        b (256-bit, treated as 128-bit GF(2^128) element)
Output: a × b in the Binius canonical tower GF(2^128)
Cost:   8 gas (similar to MULMOD)
Note:   equivalent to PCLMULQDQ × 4 + tower reduction
```

The reference implementation for the EIP spec is this repository's `BinaryFieldLibOpt.sol`.

---

### Decision Tree

```
Where are you deploying?
├── L1 mainnet / major L2 (Arbitrum, Optimism, Base)
│   └── Use Path A (SP1 wrapping) — ~280K gas, works today
├── Your own appchain (Orbit, CDK, OP Stack fork)
│   └── Use Path B (custom precompile) — ~500K gas, full throughput
└── Long-term (2-4 years)
    └── Path C (EIP) — same gas as B but on mainnet
```

## Proof Format and ABI Encoding

This section documents how a proof generated by the binius64 Rust crate is
serialized and passed to the Solidity verifier, so a developer can wire the
two ends together without guesswork.

### Native Verifier (`Binius64Verifier.sol`)

The native verifier accepts a structured `Binius64Proof` object. The expected
on-chain format mirrors the Rust `ProofData` serialization from binius64:

```
FRIProof {
  commitments: FRIRoundCommitment[]   // one bytes32 Merkle root per fold round
  queries: FRIQuery[]                  // numQueries entries
  finalPoly: uint256                   // the final constant evaluation
}

FRIQuery {
  queryIndex: uint256                  // index into the initial domain
  rounds: FRIQueryRound[]              // one per fold round
  finalValue: uint256                  // claimed fold output at this query
}

FRIQueryRound {
  val0: uint256                        // evaluation at idx0
  val1: uint256                        // evaluation at idx1 = idx0 + half
  merkleProof0: bytes32[]              // Merkle path for val0
  merkleProof1: bytes32[]              // Merkle path for val1
}
```

Encoding: use `abi.encode(proof)` (Solidity ABI encoding of the struct), then
pass the resulting `bytes` to the verifier. All `uint256` field elements must
be packed into 32 bytes, **little-endian within the 128-bit word**, zero-padded
to 256 bits (upper 128 bits zero). The binius64 Rust crate serializes
GF(2^128) elements in this canonical form.

**Leaf hashing:** `MerkleVerifier.hashLeaf(v) = keccak256(abi.encodePacked(uint8(0x00), v))`.
The binius64 Rust crate must use the identical leaf hash when building its
Merkle trees, or the proofs will not verify.

### SP1-Wrapped Verifier (`Binius64SP1Verifier.sol`)

For the production-viable SP1 path, the on-chain interface is:

```solidity
verifier.verify(publicValues, sp1Proof)
```

| Argument | Type | Size | Content |
|---|---|---|---|
| `publicValues` | `bytes` | 96 bytes | `abi.encode(circuitId, publicInputsHash, proofHash)` |
| `sp1Proof` | `bytes` | ~256 bytes | SP1 Groth16 proof bytes from `cargo prove --groth16` |

**`publicValues` breakdown (3 × bytes32):**

```
circuitId       = keccak256(serialized ConstraintSystem bytes)  [computed in-guest]
publicInputsHash = keccak256(abi.encode(public_witness_words))  [computed in-guest]
proofHash       = keccak256(raw binius64 proof bytes)           [computed in-guest]
```

All three values are computed inside the SP1 guest program
(`sp1-guest/src/main.rs`). The on-chain contract trusts them because they
are committed to by the SP1 Groth16 proof — the prover cannot forge them.

**Generating `publicValues` and `sp1Proof` from Rust:**

```bash
cd sp1-guest

# Simulate (fast, no real proof — for development)
cargo prove execute --input proof.json

# Produce real Groth16 proof (~30s on 32-core, or use Succinct's hosted prover)
cargo prove --groth16 --input proof.json --output output.json

# output.json contains:
#   "publicValues": "0x<96 hex bytes>"
#   "proof": "0x<~512 hex bytes>"
```

Pass these directly to `verifier.verify(publicValues, sp1Proof)`.

### Input encoding rules (both paths)

- GF(2^128) elements are packed into the **low 128 bits** of a `uint256`.
  Bits 128–255 must be zero. The Solidity verifier masks these away internally
  (see `BinaryFieldLibOpt.mulGF2_128`), but the binius64 Rust crate should
  produce correctly-sized values.
- Merkle roots are `bytes32` (keccak256 output, big-endian as returned by EVM).
- All multi-element arrays are ABI-encoded with a 32-byte length prefix followed
  by the elements.

---

## Relationship to `binius-research/evm-verifier`

This repository (`binius-verifier/`) and `binius-research/evm-verifier/` are **two separate Solidity implementations** of the Binius64 verifier, maintained in parallel for distinct reasons:

| Dimension | `binius-verifier/` (this repo) | `binius-research/evm-verifier/` |
|---|---|---|
| **Purpose** | Clean, auditable, modular | Rust-fixture-driven, step-by-step match to Rust |
| **Field library** | `BinaryFieldLib` / `BinaryFieldLibOpt` | `GF128` |
| **Transcript** | `FiatShamirTranscript` (domain-sep, squeeze counter) | `Transcript` (Keccak sponge, different layout) |
| **Proof format** | `Binius64Proof` struct (ABI-encoded) | Byte-stream parser matching `ProofData` |
| **Test coverage** | 176 unit + property tests | 93 tests incl. E2E with real proof fixture |
| **Gas** | Tier 1+2 optimized (~71M target) | Unoptimized baseline (~736M, research only) |
| **Production path** | Yes (native or SP1-wrapped) | No — reference / research only |

### Convergence plan

**Step 1 (current):** Validate correctness independently.
`binius-research/evm-verifier` is validated against the Rust crate using real proof fixtures. This confirms the Fiat-Shamir ordering and proof structure. `binius-verifier/` is validated against `BinaryFieldLib` reference arithmetic.

**Step 2 (next):** Align transcript and proof parsing.
Once `binius-research` transcript is confirmed correct end-to-end, `FiatShamirTranscript.sol` and the proof struct in `Binius64Verifier.sol` will be updated to match — enabling real Rust-generated proofs to pass through the production verifier. After Step 2, `binius-research/evm-verifier` will be archived and this repo becomes canonical.

**Key divergence to resolve:** The `FRIFold` chunk/interleaved folding in `binius-research` uses a different domain representation than the per-query `binaryFold` here. These must be reconciled before a real proof passes here.

---

## References

- [DP23] Diamond & Posen, "Succinct Arguments over Towers of Binary Fields", https://eprint.iacr.org/2023/1784
- [DP24] Diamond & Posen, "Polylogarithmic Proofs for Multilinears over Binary Towers", https://eprint.iacr.org/2024/504
- [binius64] https://github.com/binius-zk/binius64
- [binius.xyz] https://binius.xyz/blueprint

## License

Apache-2.0 OR MIT (dual-licensed, matching binius64)
