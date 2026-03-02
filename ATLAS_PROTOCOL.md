# Atlas Protocol

**Stateless Agent Authorization and Conditional Settlement on EVM**

*February 2026 — Version 1.0*

---

> *"No agent signature can move more value than the capability bounds, regardless of whether the agent key is compromised, jailbroken, manipulated, or acting maliciously."*
>
> — Atlas Protocol Invariant

---

## Abstract

Every existing approach to on-chain agent authorization makes the same architectural mistake: it makes the agent the account. The agent holds custody. The agent is the enforcement mechanism. When something goes wrong — compromise, manipulation, liveness failure — there is no separation between "what the agent was allowed to do" and "what it can do now."

Atlas fixes this by separating four concerns that every existing protocol conflates: **custody**, **identity**, **authorization**, and **enforcement**. Assets live in a singleton vault as UTXO-style commitments. Agents hold signing keys and off-chain capability tokens — nothing on-chain. Execution is performed by ephemeral contracts that exist for the duration of a single transaction. And conditional execution fires automatically via a permissionless keeper network, with no dependence on agent liveness.

The result is a protocol where the blast radius of any failure is bounded by design rather than hope: a compromised agent key cannot exceed its capability constraints; a manipulated agent cannot exceed its spending limits; an offline agent's stop-loss still fires. Atlas is not an improvement to existing delegation standards. It is a different layer — not the consent rail, but the enforcement rail.

---

## 1. The Problem

### The Account-Agent Conflation

Every existing approach — ERC-4337 smart accounts, session keys, EIP-7702 — treats the account as the custody container. An agent authorized to act on an account has access to whatever the account holds, up to the session scope. Three structural consequences follow:

**Compromise blast radius is unbounded within session scope.** A compromised agent key can drain everything in the account the session permits — at machine speed, before the user notices. There is no architectural bound on the damage.

**Liveness-independent enforcement is architecturally impossible.** If the agent is offline when a stop-loss condition is met, nothing happens. Conditional execution is coupled to agent liveness. For AI agents that can be rate-limited, killed, or compromised, this is a fundamental safety gap — not a UX problem.

**Privacy migration requires a complete redesign.** Account balance models (`balances[user]`) cannot be mapped to private note systems without replacing the entire custody layer. The correct model — UTXO-style commitments over `(owner, asset, amount, salt)` tuples — must be designed in from the start.

### The Missing Layer

The agent infrastructure stack as it exists today has identifiable gaps that existing standards explicitly defer:

```
┌─────────────────────────────────────────────────────┐
│  Agent Identity / Discovery                          │  ERC-8004, ERC-8126
├─────────────────────────────────────────────────────┤
│  Multi-Agent Coordination                            │  ERC-8001
├─────────────────────────────────────────────────────┤
│  Delegation / Authorization                          │  ERC-7710, MetaMask MDT
├─────────────────────────────────────────────────────┤
│  Intent Execution                                    │  ERC-7521, ERC-7683
├─────────────────────────────────────────────────────┤
│  Custody Isolation                ← UNADDRESSED      │
├─────────────────────────────────────────────────────┤
│  Liveness-Independent Enforcement ← UNADDRESSED      │
├─────────────────────────────────────────────────────┤
│  Privacy Migration Path           ← UNADDRESSED      │
└─────────────────────────────────────────────────────┘
```

Atlas addresses exactly these three gaps.

---

## 2. Design

### The Four Separations

| Concern | Atlas | ERC-4337 | MetaMask MDT |
|---|---|---|---|
| Custody | Singleton vault, commitment-based | Smart account (per-user) | Smart account (per-user) |
| Identity | Signing key only — no on-chain presence | Account address | DeleGator address |
| Authorization | Off-chain capability token | On-chain session key | On-chain delegation |
| Enforcement | Kernel + ephemeral executor | Account code | Caveat enforcer bytecode |

These separations are not a feature list. They are the architectural consequence of treating each concern as a distinct primitive. When they are conflated — as in every alternative — a failure in any dimension propagates to the others. When they are separated, the blast radius of any failure is bounded and deterministic.

### The Commitment Model

The vault does not store balances. It stores hash commitments:

```
positionHash = keccak256(owner, asset, amount, salt)
```

Each position is an independent object. It can be encumbered (locked to an envelope), transferred, or spent — all without affecting any other position. An agent's compromise affects only the positions it was authorized to spend, not the user's entire portfolio.

This model maps directly to the Aztec note model. When private execution becomes available, migrating Atlas positions to private Aztec notes requires only changing the hash function (`keccak256` → `Poseidon2`) and the proof system — not the protocol architecture.

### Capability Tokens

Authorization is expressed as off-chain EIP-712 signed capability tokens:

```
Capability {
    issuer      // user's wallet
    grantee     // agent key
    scope       // what actions are permitted
    expiry      // when the capability dies
    nonce       // revocation handle
    constraints {
        maxSpendPerPeriod   // hard spending ceiling per time window
        periodDuration      // time window length
        minReturnBps        // minimum acceptable return ratio
        allowedAdapters     // which protocols the agent can route through
        allowedTokensIn     // which tokens can be sold
        allowedTokensOut    // which tokens can be bought
    }
}
```

Capability tokens are **never stored on-chain**. The issuer's signature is the proof of authorization, verified by the kernel on every execution. Revoking an agent requires one on-chain transaction from the user's wallet — no guardian, no timelock, no grace period. A new capability issued off-chain instantly supersedes the previous one.

Agents can delegate to sub-agents with strictly narrower constraints (less spend, tighter slippage, fewer adapters). Delegation chains up to depth 8 are supported. The kernel enforces full constraint monotonicity: a sub-agent can never exceed the constraints of its parent, regardless of what the sub-capability claims. Period spending is tracked against the root capability hash, so no combination of sub-capabilities can exceed the root's aggregate limit.

### Conditional Execution Envelopes

An envelope is a cryptographic commitment to a future action:

```
Envelope {
    positionCommitment  // which position is locked
    conditionsHash      // merkle root of condition tree (private until trigger)
    intentCommitment    // hash of the intent to execute (private until trigger)
    expiry              // after which the position is automatically released
    keeperRewardBps     // reward to whoever triggers
}
```

At registration, the strategy is fully hidden — only opaque hashes are stored on-chain. At trigger time, the keeper reveals the condition tree and intent, the registry verifies the hashes match, re-reads oracle values from live on-chain state (not keeper-provided data), and executes the intent through the kernel. The agent need not be present. The keeper has no discretion — they cannot forge oracle values or alter the intent.

Condition trees support composable logic: `AND`, `OR`, price leaves (with TWAP for manipulation resistance), time leaves, volatility leaves, and arbitrary on-chain state reads from an allowlisted oracle set. A dual-oracle design (Chainlink + Pyth consensus) prevents single-feed manipulation from triggering envelopes.

---

## 3. How It Works

### Direct Intent Execution

A user deposits an asset, receiving a position commitment. They sign a capability authorizing an agent key. The agent signs an intent specifying which position to spend, which adapter to route through, the minimum acceptable output, and a deadline. A solver submits both signatures to the kernel.

The kernel verifies the signatures, checks all constraints, writes the nullifier, then deploys an ephemeral CREATE2 executor at a pre-computed address. The vault releases the position's assets to the executor. The executor calls the adapter, enforces the minimum return, revokes its token approval, returns the output to the vault as a new position commitment, and self-destructs — all within a single atomic transaction. If any step fails, the input position is untouched.

**The key properties:**
- The agent never holds assets. It holds a capability token and produces a signed intent.
- The executor exists for exactly one transaction. It holds no state before or after.
- If the transaction reverts, the nullifier was never written. The position is recoverable.
- Even if the agent's key is compromised, the attacker is bounded by `maxSpendPerPeriod`.

### Envelope Execution

An agent pre-signs an intent and registers an envelope encoding the conditions under which it should fire. The agent can then go offline permanently. When oracle conditions are satisfied, any keeper calls `envelopeRegistry.trigger()`. The registry re-reads all oracle values from on-chain state in the same block as the trigger — the keeper cannot provide forged values — evaluates the condition tree, and forwards the revealed intent to the kernel. The keeper receives `keeperRewardBps` of the output. The user's conditional instruction executes correctly regardless of whether the agent is alive.

### Revocation and Recovery

The user calls `kernel.revokeCapability(nonce)` from their wallet. One transaction. From that block forward, every intent referencing that capability reverts immediately — no grace period, no guardian approval. Positions remain in the vault and are withdrawable directly by the owner via `vault.withdraw(positionPreimage)` at any time, without any agent or keeper involvement. Encumbered positions are released when their envelope expires. The user is never locked out.

---

## 4. Security Guarantees

### Protocol Invariants

Six properties hold unconditionally for any valid execution — enforced by contract code, not by trust:

| Invariant | Statement |
|---|---|
| **Spend Authenticity** | A position can only be spent by presenting a valid capability signature from the owner and a valid intent signature from the grantee |
| **Constraint Supremacy** | No intent can cause `amountSpent > maxSpendPerPeriod`, use an unlisted adapter, or return less than `minReturnBps` — the kernel checks all constraints before any asset movement |
| **Nullifier Uniqueness** | Each `(intent.nonce, positionCommitment)` pair produces at most one execution; the nullifier is written before assets move |
| **Output Preservation** | Value entering `vault.release()` equals value committed back to `vault.commit()` plus keeper reward; no value is created or destroyed |
| **Encumbrance Exclusivity** | A position locked to an envelope cannot be spent directly, and cannot be locked to a second envelope simultaneously |
| **Delegation Monotonicity** | Sub-capability constraints are always a strict subset of parent constraints; agents cannot grant downstream agents more authority than they hold |

### Threat Model

**Compromised agent key:** The attacker is bounded by `maxSpendPerPeriod`. With a 24-hour period and a $1,000 limit, the maximum loss is $1,000/day regardless of how many intents the attacker submits. The user revokes the capability in one transaction; from that block, the key is worthless. This is architecturally superior to session key models, where compromise requires rotating the account key through a guardian or social recovery process — introducing a window of continued risk.

**Vault drain:** An attacker cannot construct a forged capability — the kernel verifies the issuer signature from the revealed position preimage. Without the position owner's private key, no valid capability can be produced for that position.

**Oracle manipulation (envelopes):** Conditions are evaluated against 30-minute TWAPs, not spot prices. A flash manipulation cannot move the TWAP. N-block confirmation requirements filter noise. Dual-oracle consensus (Chainlink + Pyth) requires a sustained, coordinated manipulation across two independent data providers — economically prohibitive.

**Non-standard tokens:** The vault maintains a protocol-administered token allowlist. ERC-777, ERC-1363, and any token with non-standard transfer hooks are excluded by default. Only audited standard ERC-20 tokens are accepted. This is a Phase 1 invariant enforced from the first deployment.

**Keeper MEV:** Keepers submit trigger transactions through Flashbots Protect (private mempool), eliminating the front-running window available to MEV searchers in the public mempool. The keeper reward is set to cover gas costs plus MEV competition probability. Validator suppression is bounded to single-block windows; envelopes with sufficiently distant expiry are censorship-resistant by construction.

### What This Is Not

Atlas does not provide AI alignment. It does not prevent an agent from being manipulated into taking bad actions within its constraints. It does not provide private balances on a public chain. It does not replace consent mechanisms (ERC-7710) — those still govern whether the user authorized the agent at all. Atlas enforces that authorized actions stay within the bounds the user set, regardless of what happens to the agent.

---

## 5. Zero-Knowledge Layer

### What ZK Actually Delivers on a Public EVM

Precision is required here. Overclaiming is the most common failure in ZK papers.

**ZK provides on a public EVM:**
- **Proof of knowledge without full revelation** — an agent can prove it satisfied constraints across N historical executions without revealing the individual trade parameters
- **Computation compression** — O(N) constraint verification is replaced by O(1) SNARK proof verification (once Phase 2 accumulators are deployed)
- **Delegation chain compression** — a depth-8 sub-capability chain (~4 kB of calldata) is replaced by a ~2 kB proof
- **Portable compliance credentials** — a constant-size proof artifact any verifier can check without access to raw trade history

**ZK does not provide on a public EVM:**
- **Private balances** — amounts are visible in deposit and execution calldata
- **Private counterparties** — transaction senders are visible
- **Hidden execution history** — on-chain events are public regardless of ZK

The most valuable ZK capability in the Atlas context is the **selective disclosure proof**: an agent proves that a disclosed subset of its executions satisfied capability constraints, without revealing individual trade parameters. This transforms execution history from a privacy liability into a portable compliance credential.

### The Hash Bridge: An Honest Engineering Tradeoff

The protocol uses `keccak256` on-chain (standard, no new primitives). ZK circuits prefer `Poseidon2` (100× cheaper in constraints). A naïve circuit hashing 100 positions with `keccak256` costs ~2.7 million ACIR gates. The same circuit with `Poseidon2` costs ~580,000 gates.

The Phase 2 recommendation is a **dual-hash bridge**: the on-chain commitment stays `keccak256`; the circuit receives the keccak hash as a public input and the Poseidon2 hash as a private input, and proves both hash the same preimage. This adds one keccak256 call per commitment (~12,000 gates) as a one-time bridge cost, after which all in-circuit operations use Poseidon2. Net result: ~10× cheaper than all-keccak, while requiring zero on-chain changes.

The encoding is precise: a 256-bit keccak output splits into two 128-bit field elements `(lo_128, hi_128)` to fit within the BN254 scalar field. All implementations must use this canonical split.

### The Four Circuits

**Circuit 1 — Selective Disclosure Proof:** Proves that N disclosed intents satisfied capability constraints (adapter allowlist, per-period spend, minimum return). Critically: this is *selective* disclosure, not complete compliance. An agent chooses which intents to include; the circuit cannot prove that omitted intents were compliant. Complete compliance — proving *all* historical executions — requires a per-capability nullifier accumulator (Phase 2 infrastructure). Phase 1 proofs should be labelled "uncorroborated disclosure." Phase 2 proofs are anchored to on-chain state and cannot be fabricated. Gate count: ~2.7M (Phase 1), ~3.0M (Phase 2 with receipt accumulator). Proof system: UltraHonk (no circuit-specific trusted setup).

**Circuit 2 — Sub-Capability Chain Verification:** Compresses a depth-8 delegation chain from ~4 kB calldata + 8 on-chain reads to a single ~2 kB proof. Proves the full chain is valid, constraints are monotone, and no link in the chain is revoked. This circuit has the highest impact on routine protocol operations and should be the first built. One security note: the revocation check uses a Merkle accumulator with a 1-hour epoch interval — a capability revoked in the last hour could still produce a valid Circuit 2 proof. An emergency fast-revocation path triggers an immediate accumulator update for high-stakes revocations.

**Circuit 3 — Condition Tree Proof:** Allows keepers to prove a condition tree evaluates to `true` without revealing the oracle thresholds or boolean structure. Privacy is real for multi-condition strategies (AND/OR logic across price, volatility, on-chain state) and marginal for single-leaf stop-losses. Build only for composite condition trees. Single-leaf envelopes use plaintext reveal.

**Circuit 4 — M-of-N Threshold Aggregation:** Compresses M ECDSA signatures to one ZK proof. For M ≤ 20 (committee model), ZK-aggregated ECDSA is recommended. For M > 20 (swarm model), BLS signature aggregation is more gas-efficient and the setup overhead is operationally feasible.

---

## 6. Conditional Settlement Extensions

### The Generalization

The condition tree envelope was designed for AI agent stop-losses. Its actual generality is broader: every conditional financial contract reduces to the same three components.

1. One or more parties commit assets to the vault. Neither can withdraw unilaterally.
2. A condition tree defines when and how assets are redistributed.
3. The keeper network enforces settlement permissionlessly.

Every derivative is a configuration of these three components. No new protocol infrastructure is required for any of the following.

### Options

A user deposits 1 ETH and registers an envelope: `condition: ETH/USD < $1,800; intent: sell 1 ETH for USDC; minReturn: 1,791 USDC`. This is economically equivalent to a perpetual put option at $1,800 strike. Cost: one keeper reward (~$1 on Base). No premium, no counterparty, no protocol solvency risk.

For full bilateral contracts with hard price guarantees: both parties commit collateral to the vault at inception. If ETH drops to $200, the buyer receives exactly $1,800 — not approximately, not subject to pool solvency. The collateral was pre-committed. Default risk is zero by construction. This is qualitatively different from pool-based options protocols (Lyra, Hegic, Opyn) where pool insolvency under correlated stress is a live risk.

The full options structure covered with existing primitives:

| Contract type | Encoding |
|---|---|
| Protective put / covered call | Single `PriceLeaf` envelope |
| Straddle / strangle | `OR(PriceLeaf, PriceLeaf)` |
| Asian option | `TWAPLeaf` (manipulation-resistant) |
| Barrier option | `ConditionalCapability` + inner envelope |
| Forward | `TimeLeaf` + two-party vault commitment |
| Digital/binary | Any condition tree + fixed-output intent |

### Beyond Options

**Interest Rate Swaps:** Collateral committed at inception. Periodic `TimeLeaf` envelopes fire at each settlement date, read the floating rate from an `OnChainStateLeaf` (e.g., Aave's `currentLiquidityRate`), and transfer net payments. No ISDA agreement. No bank intermediary.

**Protocol Insurance (CDS):** Trigger condition reads on-chain protocol state (e.g., `AavePool.totalDeposits < inception_value × 0.5`). Parametric payout fires automatically. No governance vote on whether the hack "counts."

**Perpetual Futures:** Periodic funding payments via `TimeLeaf` chains. Health factor envelopes liquidate underwater positions when `pnl + collateral < threshold`. No centralized liquidation bot, no protocol-owned liquidity pool.

**Volatility Swaps:** Settlement reads realized volatility from a `VolatilityLeaf` oracle. Net payment: `notional × (realized_vol − strike_vol)`. The first trustless on-chain volatility product.

### The Meta-Primitive: Credible Commitment

The deepest insight is not financial. It is the ability to manufacture **credible commitment** — a guarantee that is cryptographically irreversible.

Legal contracts can be disputed. Social contracts can be abandoned. Smart contract multisigs can be rotated by their signers. A vault commitment + condition tree cannot. Once assets are in the vault, they cannot be redirected. Once a condition tree is committed, the execution logic cannot be altered. The committing party cannot renegotiate.

A protocol that cannot change its fee structure commands higher LP liquidity. A founder with a cryptographically locked vesting schedule commands higher investor confidence. A DAO that cannot claw back committed grants commands higher contributor engagement. Atlas does not merely settle financial contracts. It manufactures credibility.

---

## 7. Competitive Positioning

| Property | Atlas | MDT (ERC-7710) | ERC-4337 | AgentKit | ERC-7579 | ERC-7521 |
|---|---|---|---|---|---|---|
| Zero per-user contracts | ✓ | ✗ | ✗ | ✗ | ✗ | ✗ |
| Off-chain delegation (zero gas) | ✓ | ✗ | ✗ | ✗ | ✗ | ✗ |
| Liveness-independent enforcement | ✓ | ✗ | ✗ | ✗ | ✗ | ✗ |
| Commitment-based custody | ✓ | ✗ | ✗ | ✗ | ✗ | ✗ |
| Hard constraint enforcement | Kernel-level | Caveat bytecode | Session key scope | SDK-level | Module bytecode | Not specified |
| Aztec privacy migration path | ✓ | ✗ | ✗ | ✗ | ✗ | ✗ |
| Provable strategy track records | ✓ | ✗ | ✗ | ✗ | ✗ | ✗ |
| AI agent threat model | Designed for it | Partial | Partial | Partial | Partial | No |

**MetaMask Delegation Toolkit** is the most architecturally proximate. It solves consent — whether an agent is permitted to act. It does not solve liveness-independent enforcement, commitment-based custody, or privacy migration. Its caveat enforcer model means the audit surface scales with every new constraint type; Atlas's declarative `Constraints` struct is a fixed, bounded audit surface.

**AgentKit/CDP Wallet** is distribution-first. Any keeper infrastructure operated by a single company is a single point of failure and a single regulatory target. A permissionless keeper market with economic incentives is censorship-resistant by construction.

**ERC-7579** can replicate approximately 60% of Atlas Phase 1 value within the smart account ecosystem. It cannot replicate the commitment model, liveness-independent enforcement, or the privacy migration path. The strategic response is to demonstrate these as non-replicable, not to ignore the competition.

---

## 8. Build Roadmap

**Phase 1 (Weeks 1–8): Core Protocol**
`SingletonVault`, `CapabilityKernel`, `IntentExecutorFactory`, `UniswapV3Adapter`, `AaveV3Adapter`. No envelopes, no sub-capabilities, no ZK. One complete audit. Target: 5 AI agent integrations, $1M TVL.

**Phase 2 (Weeks 8–16): Envelopes + Sub-Capabilities + ZK Pilot**
`EnvelopeRegistry` with condition tree verification. Sub-capability chains. Chainlink oracle integration. Circuit 2 (sub-capability chain compression) and initial Circuit 1 (selective disclosure proof) build. Receipt and nullifier accumulator design resolved.

**Phase 3 (Weeks 16–24): Solver Market + ZK Production**
Open permissionless solver market with staking and slashing. Circuit 1 production deployment with receipt accumulator. Circuit 4 (M-of-N aggregation). Circuit 6 (Proof of Reserves). First institutional compliance credential issued.

**Phase 4+: Cross-Chain + Privacy Migration**
Cross-chain nullifier coordination. Bridge adapters. Aztec migration path for position commitments (Poseidon2 on-chain). ZK privacy-preserving collaborative funds.

---

## 9. Open Questions

**Q1 — Hash function migration timing:** At what N (intents per compliance proof) does the keccak256 bridge cost justify migrating on-chain commitments to Poseidon2? Preliminary analysis suggests N > 200–300 intents per proof window. Empirical Barretenberg benchmarks are needed before Phase 3.

**Q2 — Nullifier and receipt accumulators:** Two on-chain accumulators must be designed before Circuit 1 achieves full anti-fabrication properties: a per-capability nullifier accumulator and a global receipt accumulator. Without these, Circuit 1 proofs are "uncorroborated disclosure." Design must be resolved before Phase 2 production deployment.

**Q3 — Keeper economic sustainability:** What minimum keeper reward sustains a competitive market for long-horizon envelopes (365-day stop-losses)? Keeper incentive modeling is needed for Phase 2.

**Q4 — Cross-chain spend limits:** `maxSpendPerPeriod` is enforced per-chain. Cross-chain global spend limits require a nullifier coordinator on a root chain. Phase 4 design question.

---

## 10. Conclusion

Atlas addresses three gaps that every existing agent authorization standard explicitly defers: custody isolation, liveness-independent enforcement, and a privacy migration path.

The architecture rests on four clean separations — custody, identity, authorization, enforcement — that are not a feature list but a structural consequence of treating each concern as a distinct primitive. When these concerns are conflated, a failure in any dimension propagates to the others. When they are separated, the blast radius of any failure is bounded and deterministic.

The commitment model is load-bearing. Positions as `keccak256(owner, asset, amount, salt)` commitments provide UTXO-style atomicity, independent encumbrance, and a structurally direct path to Aztec private notes. This cannot be retrofitted onto an account balance model. It must be designed in from the start, which is why Phase 1 establishes it as the foundation rather than an optimization.

The ZK layer is honest about what it delivers. On a public EVM, ZK provides computation compression, proof-of-knowledge without full revelation, and portable compliance credentials. It does not provide private balances or hidden execution history. The selective disclosure proof (Circuit 1) and sub-capability chain proof (Circuit 2) deliver the highest value for the lowest complexity and are the correct first circuits to build.

The conditional settlement extensions are not a second product. They are what the protocol becomes when agent-specific assumptions are relaxed and the vault + condition tree + keeper network is recognized as general-purpose conditional settlement infrastructure. The agent use case is the correct beachhead. The settlement layer is what it grows into.

The core guarantee — no agent signature can move more value than the capability bounds, regardless of agent behavior — is not a promise about AI alignment. It is an architectural property enforced by Solidity, cryptographic signatures, and an append-only nullifier registry. It holds whether the agent is honest, compromised, jailbroken, or destroyed.

That is the correct threat model for autonomous AI agents interacting with financial protocols. It is the standard every agent infrastructure layer should be evaluated against.

---

*Atlas Protocol — Version 1.0 | February 2026*

*For implementation specification, circuit constraints, EIP-712 type hashes, gas estimates, and audit-ready technical detail, see the companion Engineering Reference (WHITEPAPER.md).*
