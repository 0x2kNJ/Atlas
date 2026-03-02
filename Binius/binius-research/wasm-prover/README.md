# binius-wasm-prover

**First browser-side Binius IOP prover.** Generates real Binius64 zero-knowledge proofs
entirely in WebAssembly — no server, no trusted setup, no native binary required.

## What this is

The three Envelope Protocol circuits (Encumber, Spend, Settle) compiled to
`wasm32-unknown-unknown` and exposed as a JS/TS package via `wasm-bindgen`.

Each proof:
- ~265 KB at `log_inv_rate=1` (FRI rate 1/2)  
- ~10–30 s in a modern browser (single-threaded portable GF(2¹²⁸))  
- Cryptographically identical to the native Rust prover output  
- Self-verified: the WASM module verifies each proof before returning it

## Build

```bash
# one-time toolchain setup
rustup target add wasm32-unknown-unknown
cargo install wasm-pack

# from this directory
wasm-pack build --target web --release
# → pkg/  (binius_wasm_prover.js, binius_wasm_prover_bg.wasm, .d.ts)
```

## Run the demo

```bash
cd demo
python3 -m http.server 8080
# open http://localhost:8080
```

Or with Node:
```bash
npx serve demo
```

## JS API

```js
import init, { prove_encumber, prove_spend, prove_settle } from "./pkg/binius_wasm_prover.js";

await init();  // loads and instantiates the WASM module

// Encumber: prove note ownership + Merkle membership + LTV sufficiency
const enc = prove_encumber({
  note_value:        100_000_000,   // u64
  note_rand:         "0x" + "42".repeat(32),  // 32-byte hex
  owner_pk:          "0x" + "11".repeat(32),
  collateral_amount: 75_000_000,
  log_inv_rate:      1,  // optional, default 1
});
// enc.proof_hex     — "0x<hex>" raw proof bytes
// enc.proof_size_kb — ~265.0
// enc.public_inputs — ["<u64 LE hex>", ...]  (13 words for Encumber)

// Spend: prove note → output note with conservation
const sp = prove_spend({
  in_value: 100_000_000, in_rand: "0x"+"42".repeat(32), in_pk: "0x"+"11".repeat(32),
  out_value: 95_000_000, out_rand: "0x"+"ab".repeat(32), out_pk: "0x"+"cd".repeat(32),
});

// Settle: same structure as Spend but with DOMAIN_SETTLE nullifier
const se = prove_settle({
  in_value: 100_000_000, in_rand: "0x"+"42".repeat(32), in_pk: "0x"+"11".repeat(32),
  out_value: 90_000_000, out_rand: "0x"+"ef".repeat(32), out_pk: "0x"+"fe".repeat(32),
});
```

## Why this is novel

As of February 2026, no public Binius prover exists that compiles to WASM. The
[Irreducible Binius](https://github.com/IrreducibleOSS/binius) reference library
targets native x86_64/aarch64 only (rayon + CLMUL intrinsics). This crate achieves
WASM compatibility by:

1. **Disabling `rayon`** — `binius-utils` uses a "maybe-rayon" shim: when the `rayon`
   feature is off, all parallel iterators degrade to sequential. One feature flag,
   zero code changes in the core library.

2. **Portable field arithmetic** — `binius-field` dispatches to architecture-optimal
   packed types at compile time. For `wasm32`, it falls back to `PackedBinaryGhash1x128b`
   (pure Rust GF(2¹²⁸) using 128-bit integers), which is slower than AVX2 but
   architecturally correct and fully functional.

3. **No `binius-examples`** — the examples crate pulls in `ureq`, `ethsign`, and
   `jwt-simple` (→ `ring` C library), none of which support `wasm32-unknown-unknown`.
   The WASM crate inlines the four-line `setup_sha256` function directly.

4. **`getrandom/wasm_js`** — the FRI prover uses CSPRNG-seeded challenge generation.
   Adding `getrandom = { features = ["wasm_js"] }` routes entropy through
   `crypto.getRandomValues()`.

## Performance profile

**Native aarch64 (reference):** ~110 ms per proof.

### Desktop browser (current portable build)

| Circuit  | SHA256 rounds | M-series Mac (Chrome/Safari) |
|----------|---------------|------------------------------|
| Encumber | 66            | ~15–25 s                     |
| Spend    | 69            | ~16–26 s                     |
| Settle   | 69            | ~16–26 s                     |

WASM overhead is ~150–200× due to: no SIMD (portable u128), no threads (rayon off), JIT tier-up.

### Mobile (current portable build)

| Device                       | Single-core vs M2 | Estimated prove time | Usable? |
|------------------------------|-------------------|----------------------|---------|
| iPhone 15 Pro (A17 Pro)      | ~65%              | ~25–40 s             | Marginal |
| iPhone 13/14 (A15/A16)       | ~55%              | ~30–50 s             | Marginal |
| Snapdragon 8 Gen 3 flagship  | ~55%              | ~30–55 s             | Marginal |
| Snapdragon 7 Gen 1 mid-range | ~35%              | ~55–90 s             | Poor    |
| Low-end Android              | ~15%              | ~3–5 min             | No      |

**Thermal throttling note:** mobile chips sustain peak for ~20–40 s then drop to 50–70% —
proofs in the 30–50 s range will finish on a throttled chip at higher latency.

### SIMD128 path (future optimization)

`binius-field` already has a `wasm32` SIMD module (`arch/wasm32/m128.rs`,
`packed_ghash_128.rs`) that wraps `v128` intrinsics. The multiply hot path would use
native WASM SIMD128 operations (maps to ARM NEON on mobile). Current status: **incomplete
upstream** — the `BinaryField1b` subfield packed over M128 is missing trait impls.

When Irreducible completes it (or we patch it):
1. Uncomment `rustflags = ["-C", "target-feature=+simd128"]` in `.cargo/config.toml`
2. Expected speedup: **~3–5× on GF(2¹²⁸) arithmetic**

Projected times with SIMD128:

| Device               | Current   | With SIMD128 |
|----------------------|-----------|--------------|
| M-series Mac browser | ~15–25 s  | ~5–8 s       |
| iPhone 15 Pro        | ~25–40 s  | ~8–15 s      |
| Snapdragon 8 Gen 3   | ~30–55 s  | ~10–18 s     |
| Mid-range Android    | ~55–90 s  | ~18–30 s     |

SIMD128 browser coverage: Chrome 91+ (May 2021), Firefox 89+, Safari 16.4+ (iOS 16.4+).

### Further optimization: multithreading

`wasm-bindgen-rayon` + SharedArrayBuffer (requires COOP/COEP headers) would add
~4–8× from parallelism. Combined with SIMD: flagship iPhone could reach **~2–4 s**,
which is commercially viable for a wallet flow.

## WASM binary size

| File | Size |
|------|------|
| `binius_wasm_prover_bg.wasm` (after `wasm-opt`) | ~851 KB |
| `binius_wasm_prover.js` (ES module glue) | ~16 KB |
