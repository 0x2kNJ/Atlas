# Proving Authority: ZK Proving Architecture for Agents and Human Wallets

**February 2026 — Envelope Protocol Engineering Notes**

---

## Overview

This document covers a structural constraint in ZK systems that becomes critical the moment you need autonomous agents to generate proofs. It explains why every existing wallet standard (MetaMask, Privy, Coinbase AgentKit) faces this constraint, why the Envelope Protocol architecture resolves it for agents, and what the roadmap looks like for human users.

The short version:
- **Agents: fully solved today** — 110ms, trustless, wallet-agnostic
- **Humans: configuration problem** — solvable, timeline depends on execution environment
- **The constraint is not cryptographic** — it is a consequence of wallet key isolation invariants

---

## 1. The Proving Authority Gap

### 1.1 Transaction authority vs. proving authority

Every existing wallet delegation standard — ERC-7715 session keys, ERC-7710 (MetaMask Delegation Toolkit), ERC-4337, Coinbase AgentKit — solves the same problem: giving an agent the right to submit signed transactions on behalf of a user.

This is *transaction authority*. It is necessary but not sufficient for ZK-enabled agent systems.

*Proving authority* is different. To generate a ZK proof, the prover must know the private witness — the secret inputs that the proof is computed over. For the Envelope Protocol, the critical witness material is:

- `note_rand` — a 32-byte secret from which the nullifier is derived
- `note_value` — the amount committed in the note
- `owner_pk` — the owner's public key (semi-public, but part of the commitment preimage)

These are derived from key material. Whoever holds the key holds the witness. Whoever holds the witness can generate the proof.

### 1.2 The wallet isolation invariant

Every production wallet enforces a single invariant:

> **The private key never leaves the secure context.**

This invariant is correct. It is the foundational security property that makes wallets safe. Hardware wallets (Ledger, Trezor), browser extension wallets (MetaMask), mobile wallets (Coinbase Wallet, Rainbow), MPC wallets (Privy, Web3Auth), and smart account frameworks (ERC-4337) all enforce it without exception.

The consequence for ZK proving is structural: **no existing wallet will expose the key material from which `note_rand` is derived to an external prover**. An agent holding a session key or capability token delegation from a MetaMask user cannot generate a ZK proof over that user's private notes — not because of a missing API, but because the witness is inaccessible by design.

This is not a MetaMask limitation. It applies identically to Privy, hardware wallets, and every other wallet architecture. It applies to every ZK protocol: Aztec, RAILGUN, Penumbra, and any future privacy system faces the identical constraint.

### 1.3 How existing privacy protocols handle it

Every deployed ZK privacy protocol resolves this by requiring the human user to generate proofs in the browser:

| Protocol | Proving location | Agent compatible? |
|---|---|---|
| Aztec | Browser WASM | No |
| RAILGUN | Browser WASM | No |
| Tornado Cash | Browser WASM | No |
| Penumbra | Desktop native | No |
| **Envelope Protocol** | **Agent native / Browser WASM** | **Yes (agent path)** |

The entire existing ecosystem assumes a human user with a browser. The Envelope Protocol is the first concrete implementation of an agent-compatible ZK proving architecture.

---

## 2. Native vs. WASM Performance

### 2.1 The 110ms benchmark

The Binius64 Envelope Protocol circuits produce real cryptographic proofs at approximately 110ms on native aarch64 hardware (M-series Mac, iPhone-class ARM):

| Circuit | SHA256 rounds | Native time |
|---|---|---|
| Encumber | 66 | ~110ms |
| Spend | 69 | ~110ms |
| Settle | 69 | ~110ms |

This uses: NEON+AES hardware acceleration, AVX2/CLMUL on x86, rayon parallelism across all cores. These are real Binius IOP proofs — not simulated, not mocked.

### 2.2 WASM performance today

The WASM prover (`binius-research/wasm-prover/`) compiles the same circuits to `wasm32-unknown-unknown`. The same cryptography runs in the browser. Current performance:

| Configuration | Desktop (M2) | iPhone 15 Pro | Mid-range Android |
|---|---|---|---|
| Current (no SIMD, no threads) | ~15–25s | ~25–40s | ~55–90s |

The overhead (~150–200×) comes from three compounding penalties:

```
No SIMD     → GF(2^128) multiply uses portable u128 software (~8-16x slower)
No threads  → rayon disabled, single JS thread (~4-8x slower)
JIT vs AOT  → WASM JIT vs native machine code (~1.5-2x slower)
```

### 2.3 WASM is not inherently slow — the current state is a configuration floor, not a ceiling

With SIMD and threads enabled, WASM approaches native speed:

```
                  Today      +SIMD only    +SIMD+Threads    Theoretical floor
Native (110ms)    110ms      110ms         110ms            110ms
WASM overhead     ×150-200   ×30-50        ×2-4             ×1.5-2
WASM result       15-25s     3-6s          200-500ms        165-220ms
```

Sub-500ms WASM proving is achievable. This is commercially viable for any wallet operation.

### 2.4 Why Binius particularly benefits from SIMD

Binary field arithmetic (GF(2^128)) maps directly to hardware SIMD operations:

```
GF(2^128) multiply → XOR + CLMUL operations
                   → maps 1:1 to SIMD128 v128 instructions
                   → ARM NEON, x86 SSE2, WASM SIMD128 all have these natively
```

Elliptic curve arithmetic (BN254, BLS12-381) involves 254-bit modular arithmetic that does not vectorize as cleanly. Binius WASM should ultimately perform *better* relative to native than pairing-based systems once SIMD is enabled.

### 2.5 Current SIMD status

`binius-field` already has a `wasm32` SIMD module (`arch/wasm32/m128.rs`, `arch/wasm32/packed_ghash_128.rs`) that wraps `v128` intrinsics. The path is:

```rust
// arch/wasm32/mod.rs — already exists in binius-field
if #[cfg(target_feature = "simd128")] {
    mod m128;           // M128 wraps v128 (WASM SIMD vector)
    pub mod packed_ghash_128;  // GF(2^128) using SIMD lane ops
}
```

**Current blocker**: the wasm32 SIMD path has an incomplete upstream implementation — `BinaryField1b` subfield packed over M128 is missing trait impls required by the prover. This is an Irreducible upstream issue.

**To enable when fixed**: uncomment in `.cargo/config.toml`:
```toml
[target.wasm32-unknown-unknown]
rustflags = ["-C", "target-feature=+simd128"]
```

---

## 3. Who Controls What

The performance of a WASM prover depends on two independent configuration levers. **Who controls each lever depends on the execution context.**

### 3.1 The two levers

```
SIMD128    → compile-time flag baked into the WASM binary
             controlled by: whoever builds the WASM module

Threads    → runtime: requires SharedArrayBuffer
             SharedArrayBuffer requires HTTP headers:
               Cross-Origin-Opener-Policy: same-origin
               Cross-Origin-Embedder-Policy: require-corp
             controlled by: whoever controls the execution environment
```

### 3.2 Control matrix by execution context

| Context | SIMD128 | Threads (SharedArrayBuffer) | Notes |
|---|---|---|---|
| **Your own dapp** | You (compile flag) | You (COOP/COEP on your server) | Both levers yours |
| **MetaMask Snap** | You (compile flag) | MetaMask must ship it | Threading gated on MetaMask |
| **Privy embedded wallet** | You | You (COOP/COEP on your dapp) | Both levers yours |
| **Browser extension** | You | You (COOP/COEP on background page) | Both levers yours |
| **React Native app** | N/A | N/A | Native Rust, no WASM at all |
| **Agent server** | N/A | N/A | Native Rust, no WASM at all |

### 3.3 MetaMask Snaps specifically

MetaMask Snaps run inside the Snaps Execution Environment (SES — Secure ECMAScript), a sandboxed iframe with restricted globals. A Snap developer can:

- ✓ Compile their WASM with `+simd128` (baked into the binary)
- ✓ Use WASM itself (supported in Snaps)
- ✗ Enable SharedArrayBuffer (MetaMask controls the execution environment headers)
- ✗ Use Web Workers directly (restricted in SES)

Result for Snaps:
- **SIMD**: available when upstream SIMD fix lands → ~3–6s
- **Threads**: gated on MetaMask shipping SharedArrayBuffer support → stuck at 3–6s until then

### 3.4 Privy specifically

Privy has two distinct wallet modes:

**Privy Embedded Wallet** (browser iframe):
- Runs in a browser context
- SIMD: you control (compile flag)
- Threads: you control (COOP/COEP headers on your dapp server)
- Both levers available → 200–500ms achievable

**Privy Server Wallet** (Authorization API):
- Runs server-side
- Use native Rust directly, no WASM
- 110ms, fully trustless

---

## 4. Agent Architecture: Fully Solved

### 4.1 Why agents have no wallet proving problem

The Envelope Protocol resolves the proving authority gap for agents structurally, not as an engineering workaround. The resolution comes from the Identity separation in the Five Separations framework:

> *Owner's sk used only inside ZK proofs; no on-chain account presence required.*

In the envelope architecture, the agent holds its own autonomous key. The agent does not prove over the user's key — it proves about its own notes, within capability-token-bounded outcomes that the user has pre-registered.

```
Human user
    └── signs EIP-712 capability token
        └── cryptographically bounds what agent's assets can become
            └── Agent
                ├── holds its own key
                ├── derives its own note_rand
                ├── proves with local Rust binary  ← 110ms
                └── submits tx via any wallet
```

The proving authority is co-located with the proving key. No separation, no trust assumption, no browser execution environment.

### 4.2 Wallet compatibility for agents

Because proving happens before the wallet is involved, any wallet can submit the resulting transaction:

| Agent wallet | Proving | Tx submission | Works? |
|---|---|---|---|
| Coinbase AgentKit | Native Rust (same server) | AgentKit CDP | ✓ 110ms |
| Privy Server Wallet | Native Rust (same server) | Privy API | ✓ 110ms |
| ElizaOS plugin | Native Rust sidecar | ElizaOS tx layer | ✓ 110ms |
| Custom EOA | Native Rust | ethers-rs / viem | ✓ 110ms |

The agent architecture is wallet-agnostic. Any wallet that can submit a transaction works, because the proof is generated independently.

### 4.3 Trust model

This is genuinely trustless:
- The agent's note and key are agent-controlled
- The capability token bounds are cryptographically enforced by the smart contract
- A compromised agent can produce only the pre-registered outcomes
- No external proving server, no TEE, no trust assumption

---

## 5. Human Architecture: Configuration Problem

### 5.1 Proof frequency in the lending lifecycle

For human users, not every protocol operation requires a ZK proof:

| Operation | ZK proof required? | When |
|---|---|---|
| Shield (create note) | No | Deposit |
| **Encumber** (lock collateral) | **Yes** | Loan open |
| Keeper enforce/liquidate | No | Automated |
| **Settle** (repay) | **Yes** | Loan close |
| **Spend** (transfer note) | **Yes** | Any transfer |

A human borrower touches the prover twice per loan lifecycle. This makes WASM proving tolerable for the lending use case even today — a one-time 20s wait to open a collateralized loan is similar to the original Tornado Cash browser prover, which deployed at real volume.

### 5.2 The performance roadmap for humans

```
Today (no SIMD, no threads)
    ~15-25s desktop, ~25-40s iPhone
    Acceptable for: low-frequency operations (loan open/close)
    Not acceptable for: high-frequency (derivatives, frequent transfers)

Step 1: SIMD128 (upstream binius-field fix)
    ~3-6s desktop, ~8-15s iPhone
    Acceptable for: most wallet operations
    Blocked on: Irreducible completing wasm32 SIMD impl

Step 2: SIMD + Threads (wasm-bindgen-rayon + COOP/COEP)
    ~200-500ms desktop, ~500ms-1s iPhone
    Acceptable for: all use cases
    Blocked on: owning the execution environment (dapp or Privy, not Snaps)

Step 3: Native mobile app (React Native + Rust FFI)
    ~110ms on any modern phone
    Fully trustless, no browser dependency
    Blocked on: building the app (~4-6 weeks)
```

### 5.3 Wallet recommendations by timeline

| Timeline | Human wallet recommendation | Why |
|---|---|---|
| Now | Privy embedded + dapp (WASM, ~15-25s) | Both SIMD+thread levers yours; tolerable for low-frequency |
| +SIMD (weeks) | Privy embedded + dapp (WASM, ~3-6s) | Acceptable for most users |
| +Threads (weeks after) | Privy embedded + dapp (WASM, ~200-500ms) | Production viable |
| +MetaMask threads (unknown) | MetaMask Snap (WASM, ~200-500ms) | When MetaMask ships SharedArrayBuffer |
| Production wallet | React Native app (native, ~110ms) | Full speed, any user |

---

## 6. The Five Separations Framework

This analysis surfaces a fifth structural separation that no existing wallet standard addresses. The Envelope Protocol's Five Separations (§1.3 of the protocol paper) are:

| Concern | Envelope Protocol | ERC-4337 | ERC-7715 Session Keys |
|---|---|---|---|
| **Custody** | Shielded note in commitment tree | Smart account holds balance | Smart account holds balance |
| **Identity** | Owner sk only inside ZK proofs | Account address | Account address |
| **Authorization** | Off-chain EIP-712 capability token | On-chain session key | On-chain session key |
| **Enforcement** | Permissionless keeper network | Account code + agent liveness | Caveat enforcer + agent liveness |
| **Proving authority** | Agent holds own key; proves over own notes within bounded outcomes | Assumed browser/user | Assumed browser/user |

The fifth row — **proving authority** — is not addressed by any existing delegation standard. Every standard that assumes proving happens in the browser, by the human user, at human-interactive latency, will require architectural revision as ZK becomes standard on L2s.

The capability-token-bounded autonomous key model — agent holds own key, proves about own capital within owner-registered bounds — is the correct general architecture for ZK-enabled agent systems. The Envelope Protocol is its first concrete implementation.

---

## 7. Summary

```
Agent use case
    Status:       SOLVED TODAY
    Proving:      Native Rust, 110ms
    Trust:        Fully trustless
    Wallet:       Any (AgentKit, Privy server, ElizaOS, custom EOA)
    Dependency:   None

Human use case — Privy dapp
    Status:       CONFIGURATION PROBLEM
    Proving:      WASM today (~15-25s), SIMD+threads target (~200-500ms)
    Trust:        Fully trustless
    Dependency:   (1) upstream SIMD fix, (2) COOP/COEP headers (you control)

Human use case — MetaMask Snap
    Status:       CONFIGURATION PROBLEM (partially gated)
    Proving:      WASM today (~15-25s), SIMD target (~3-6s)
    Trust:        Fully trustless
    Dependency:   (1) upstream SIMD fix, (2) MetaMask ships SharedArrayBuffer

Human use case — Native mobile app
    Status:       ENGINEERING TASK (~4-6 weeks)
    Proving:      Native Rust, 110ms
    Trust:        Fully trustless
    Dependency:   React Native + Rust FFI build
```

**The strategic recommendation**: ship agent-first. The agent path has no external dependencies, is fully solved today, and directly addresses the Phase 2 market (AI agent authorization). The human path has a clear roadmap and reasonable WASM performance for the low-frequency lending operations in Phase 1. By the time high-frequency human proving is needed (Phase 3: derivatives), the WASM optimization stack will have matured.

---

## 8. File References

| File | Description |
|---|---|
| `binius-research/wasm-prover/` | The WASM prover crate (wasm-bindgen, prove_encumber/spend/settle) |
| `binius-research/wasm-prover/pkg/` | Built WASM package (851 KB, `+simd128` ready when upstream fixed) |
| `binius-research/wasm-prover/demo/` | Browser demo harness |
| `binius-research/wasm-prover/.cargo/config.toml` | SIMD128 flag (uncomment when upstream fixed) |
| `binius-research/wasm-prover/README.md` | Build instructions and performance notes |
| `zk_envelopes_protocol_v4.md §1.3` | Five Separations table |
| `zk_envelopes_protocol_v4.md §5.10` | Proving Authority Gap (full paper section) |
