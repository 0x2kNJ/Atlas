# Atlas Protocol — Complete Capabilities Inventory
## Every Primitive, Extension, and Emergent Possibility
**Internal document — February 2026**

---

## How to Read This Document

This is the master inventory of what Atlas can do — and what it enables by extension. It is organized into four tiers:

- **Tier 1: Core Protocol** — The base primitives in SPEC.md. Required for V1.
- **Tier 2: Advanced Primitives** — Documented in STRATEGY.md §Advanced Primitives. Target Phase 2–3.
- **Tier 3: Extensions** — Documented in EXTENSIONS.md. Category-shifting. Phase 3–5.
- **Tier 4: Emergent Capabilities** — New. Not yet in any document. Identified February 2026.

Every capability in Tiers 1–3 is already fully specified. Tier 4 items are described here for the first time and represent the next specification effort.

---

## Tier 1: Core Protocol Primitives

### 1.1 Stateless Agent Authorization
Agents are signing keys, not on-chain accounts. No deployment cost, no on-chain presence between actions. Agents hold capability tokens — EIP-712 signed structs — that define exactly what they can do, for how long, and under what constraints.

**Why it matters:** Removes friction from AI agent deployment. Any agent key can be granted, revoked, and rotated without touching the chain. Authorization is protocol-native from day one.

### 1.2 Singleton Vault with Commitment-Based Custody
Positions are `keccak256(owner, asset, amount, salt)` commitments, not balances. No `balances[user]` mapping. Assets are provably encumbered to specific commitments. Multiple independent positions from a single vault with no cross-contamination.

**Why it matters:** Each position is a discrete, auditable, encumberable object. The commitment model is the foundation for privacy (Aztec), proof of reserves, and estate transfer. It cannot be retrofitted — it must be designed in from the start.

### 1.3 Scoped Capability Tokens
Capabilities define: allowed adapters, max spend per period, min return floor, expiry, nonce (replay prevention). The kernel enforces every constraint on every execution. A capability is not a suggestion — it is a hard execution boundary.

**Why it matters:** The constraint model is what transforms AI agents from liability into fiduciary. Users can grant broad authority with narrow risk surface. Auditors can inspect the constraint model without understanding the strategy.

### 1.4 Envelopes (Pre-Committed Conditional Execution)
An envelope commits to: a position, a condition (condition tree), and an intent. It can be triggered permissionlessly by any keeper when the condition is true. The owner does not need to be online. The agent does not need to be online. Execution is liveness-independent.

**Why it matters:** This is what distinguishes Atlas from every delegation-only protocol. The owner's intent persists on-chain and executes regardless of whether any authorized party remains active.

### 1.5 Condition Trees (Composable Boolean Logic)
Conditions can be combined: `AND(price_leaf, time_leaf)`, `OR(volatility_leaf, onchain_leaf)`. Any number of leaves, any nesting depth. Committed as a hash and revealed only at execution time — the strategy is private until it fires.

**Why it matters:** Every meaningful automated strategy requires compound conditions. Simple price triggers are stop-losses. Compound conditions are actual risk management. The tree structure is what makes condition logic Turing-incomplete-but-sufficient for finance.

### 1.6 Sub-Capabilities (Delegation Chains)
An agent can re-delegate a subset of its authority to a downstream agent. The sub-capability's constraints must be equal to or tighter than the parent's. Revocation propagates through the entire lineage. Depth is bounded to prevent amplification.

**Why it matters:** Enables orchestrator → specialist → execution agent architectures without expanding risk surface. Each delegation step can only narrow authority, never expand it.

### 1.7 MEV Protection
All execution is routed through Flashbots Protect bundles by default. The `adapterData` field (swap calldata) is threshold-encrypted and only revealed to the winning builder. The `minReturn` floor rejects any execution path that extracts more than the specified slippage.

**Why it matters:** MEV extraction is the silent cost that makes most on-chain execution economically uncompetitive. Atlas makes MEV resistance a protocol-level guarantee, not an optional feature.

### 1.8 Dual-Oracle Design
Every condition evaluation uses both Chainlink and Pyth. A stale round on either feed does not trigger — it delays. Chain halt, depeg, feed outage, and manipulation are each handled as distinct failure modes with specified protocol responses.

**Why it matters:** Single-oracle protocols fail silently. Atlas fails loudly and safely. The failure mode taxonomy is documented, specified, and auditable.

---

## Tier 2: Advanced Primitives

### 2.1 Dead Man's Switch Envelopes
An envelope that fires when a condition *stops* being maintained. Example: "If I haven't sent a heartbeat transaction in 30 days, transfer my positions to this recovery address." Inverse of standard envelopes — they enforce liveness through absence detection.

**Why it matters:** The first on-chain liveness enforcement mechanism that requires no third party. Solves the "what happens to my automated strategies if I become incapacitated" problem for every user, at the protocol level.

### 2.2 M-of-N Multi-Agent Consensus
An intent that requires signatures from M of N pre-authorized agent keys before the kernel executes it. The M and N values are defined at capability issuance and cannot be changed without re-issuance.

**Why it matters:** Eliminates single-agent-as-single-point-of-failure. For any high-value operation, require 3-of-5 independent agents to agree. One compromised model cannot unilaterally act. Used in institutional deployment, DAO treasury management, and shared-custody funds.

### 2.3 Conditional Capability Activation
A capability that becomes active only when an oracle condition holds. Example: "This agent can execute with up to $100k limits only when portfolio drawdown is below 10%." The capability itself is condition-gated.

**Why it matters:** Adds a layer of protocol-level risk management that operates independently of the agent. Even if the agent ignores the drawdown, the capability will not activate. The constraint is enforced at the kernel level, not the AI level.

### 2.4 ZK Proof of Constraint Compliance
An agent generates a zero-knowledge proof that all of its historical executions satisfied the granted capability constraints, without revealing any trade details (asset, amount, counterparty, timing).

**Why it matters:** Portable, verifiable trust credential. An agent that has never violated a constraint can prove it to any new principal without revealing trading history. This is the mechanism that makes Atlas execution history a compounding asset rather than a compliance liability.

### 2.5 Protocol-Native Circuit Breakers
Automatic tightening or suspension of capabilities when execution anomalies are detected. Anomaly detection reads: velocity anomalies, slippage pattern changes, constraint near-misses. Defined thresholds in the capability trigger automatic limit reductions or full suspension.

**Why it matters:** The protocol can detect when an agent is behaving abnormally before the user does. Self-correcting authorization infrastructure. The first line of defense against AI behavioral drift at scale.

### 2.6 Intent Pipelines (Chained Envelopes)
Each envelope can specify the hash of the next envelope to register upon successful execution. A 3-stage strategy: "sell ETH when price drops → deploy USDC to Aave → withdraw from Aave when yield drops → rebuy ETH" is a closed loop of four envelopes, each pre-committed and each triggering the next.

**Why it matters:** Autonomous strategies that run indefinitely without human intervention. The complete strategy graph is committed at deployment — every stage is pre-authorized, pre-constrained, and auditable from day one.

---

## Tier 3: Extensions (Category-Shifting)

### 3.1 Atlas as an Options Settlement Layer
A condition tree envelope with a price leaf *is* an options contract. The put option is an envelope: "if ETH < $1,800, sell." The call is the inverse. A collar is two envelopes. An Asian option is a TWAP leaf. Atlas does not need to build an options protocol — it already is one.

**The expansion:** Any asset with an oracle feed can have options-like instruments created without counterparties, without liquidity, without an options exchange. A synthetic option for any asset, accessible to any wallet, with no infrastructure beyond Atlas.

### 3.2 Manipulation-Resistant Execution (TWAP + N-Block)
Two hardening mechanisms:

**TWAP Leaves:** The condition evaluates against the 30-minute time-weighted average price, not the spot price. A single-block oracle manipulation cannot trigger an envelope. The attack cost is proportional to the TWAP window × required deviation.

**N-Block Confirmation:** The condition must be true for N consecutive blocks before execution. A condition that flips true then false is not a stable condition — it's noise. Only stable conditions fire.

**Why it matters:** Stop-loss hunting and flash manipulation become economically non-viable against Atlas positions. The position is protected not by obscurity but by time.

### 3.3 Strategy NFTs (Transferable Strategy Templates)
A strategy — its condition tree root, intent template, and constraint profile — is minted as an ERC-1155 token. The NFT holder earns a protocol-defined royalty on every execution that uses their strategy template. On-chain execution statistics create a live, unforgeable reputation score.

**Why it matters:** Strategies become assets. Top quantitative strategies can be licensed rather than sold. Creators monetize indefinitely. Users get access to battle-tested, transparently-tracked strategies. The protocol earns a fee on every execution. This is the DeFi strategy marketplace with provable track records.

### 3.4 Sustained Conditions (Regime Detection)
A condition that must be true for a minimum continuous duration before it triggers. "Trigger only if ETH has been below $1,800 for at least 4 hours" — not just at a single block. The `SustainedLeaf` wraps any inner condition with a minimum duration requirement.

**Why it matters:** Single-block conditions are vulnerable to noise and manipulation. Sustained conditions filter noise and detect regimes. "The market has been bearish for 4 hours" is a different, richer condition than "the market was bearish one second ago."

### 3.5 Conditional LP Management
Provide Uniswap V3 concentrated liquidity within a price range. A condition tree envelope fires when the price exits the range and withdraws the position. A second envelope fires when the price re-enters and redeploys. The entire LP management lifecycle is expressed as a strategy graph.

**Why it matters:** Concentrated liquidity management is currently the highest-complexity, highest-value problem in DeFi for retail users. Protocols like Gamma charge management fees and still get it wrong. Atlas does it trustlessly, with the user's exact range preferences, and with zero management fees beyond keeper incentives.

---

## Tier 4: Emergent Capabilities (New — Not Yet Specified)

These are identified for the first time in this document. They represent the next phase of specification work.

---

### 4.1 Agent Swarms with Emergent Consensus

**The idea:** Not 3-of-5 named agents (M-of-N). Instead, deploy 100 lightweight, independent agents — each running a different model, different data feed, or different prompting strategy. A transaction executes only when 60 of the 100 agree it is correct. The agreement threshold is configured in the capability.

**The mechanism:** The kernel accepts a threshold signature scheme: execute if signatures from at least T of the registered swarm keys are present. Swarm keys are registered as a merkle set; proofs of membership are submitted alongside signatures, keeping calldata manageable.

**Why it is different from M-of-N:** M-of-N assumes named, trust-weighted agents. A swarm assumes statistical independence: each agent is a noisy sensor, but the ensemble is accurate. One compromised agent has near-zero impact. Coordinated manipulation of 60 of 100 independent agents is computationally and economically prohibitive.

**The target use case:** High-value executions — treasury management, liquidation decisions, large position entries — where the cost of a wrong decision is high enough to justify the overhead of broad consensus. The swarm is the AI equivalent of institutional investment committee approval.

**Protocol requirement:** Swarm registration at capability issuance. Threshold defined at issuance. Individual swarm keys are capability-constrained separately. A swarm agent without the required number of co-signatures cannot execute alone regardless of its individual capability.

---

### 4.2 Real-Time Proof of Reserves for AI-Managed Funds

**The idea:** Every position is a vault commitment with a known keccak256 hash. The total position set for any fund is publicly readable. A proof of reserves is a merkle proof over all vault commitments: the total assets under management are verifiably on-chain and unencumbered to any conflicting commitment.

**The mechanism:** Atlas publishes a signed merkle root of all active vault commitments at a defined interval (e.g., every 12 seconds — every block on Base). Any observer can verify any position exists and is not double-committed. The proof is trustless and requires no auditor.

**Why it is important now:** Post-FTX, institutional capital requires proof of reserves as a precondition for deploying into any AI-managed fund structure. Every existing solution requires a third-party auditor, off-chain attestation, and a reporting delay. Atlas provides it as a free side effect of its architecture — the commitment model generates PoR automatically.

**The expansion:** This positions Atlas as the infrastructure layer for any compliant AI-managed fund. "Your fund is Atlas-native" becomes a compliance credential. The PoR is not a product — it is a byproduct of correctness. That is the strongest kind of moat.

**Protocol requirement:** A PoR aggregator contract that reads all registered vault commitments and emits a merkle root per block. Off-chain indexer provides the inclusion proof API. No changes to core vault logic required.

---

### 4.3 Agent as a Service Marketplace (AaaS)

**The idea:** Agent operators deploy public, persistent agents and publish a profile: strategy description, required capability template (what minimum authority the agent needs to function), fee model (% of returns, flat fee per execution, or hybrid), and a ZK compliance proof (historical constraint compliance without revealing trades).

Users browse agents like apps. Granting capability is a single signature. Fee routing is embedded in the capability. The ZK proof provides verifiable track record. Trust, authorization, and settlement are all Atlas primitives.

**The mechanism:**
- Operator registers an agent profile in an on-chain registry (name, description, capability template, fee model, ZK proof hash).
- User selects an agent, reviews the capability template, signs a capability granting the agent the requested authority with the fee routing embedded.
- The agent executes on the user's behalf; every execution routes the fee directly to the operator address embedded in the intent.
- The operator's ZK proof is updated on each execution cycle, providing a rolling track record.

**Why it is important:** The App Store captured value not by building apps but by owning the distribution and trust layer between developers and users. Atlas can own the same position for AI agent strategies. The operator ecosystem is the growth mechanism. Atlas's infrastructure is the platform. Once a user has Atlas as their trust layer, switching to any other execution provider requires replacing the entire trust model.

**Revenue implication:** Platform fee on every AaaS execution, in addition to per-execution fees. Operator staking (Tier 4.6) further aligns incentives.

**Protocol requirement:** An `AgentRegistry` contract. A standardized `CapabilityTemplate` format that operators publish. A fee routing field in the `Intent` struct. ZK proof update mechanism for rolling compliance credentials.

---

### 4.4 Reputation Staking with Automatic Slashing

**The idea:** At capability issuance, the operator (or the agent itself) puts up a staked bond in ETH. The stake is locked in a vault commitment. Anomaly events — detected by the protocol-native circuit breaker — accumulate a score. If the score exceeds a threshold defined in the capability, a pre-committed slash envelope fires automatically, burning a portion of the bond and emitting an `AgentSlashed` event.

**The mechanism:**
- Operator stakes ETH at capability issuance. The stake amount is a function of the total capability value limit (e.g., 1% of `maxTotalValue`).
- The anomaly detection oracle tracks: constraint near-misses, velocity spikes, unusual counterparty patterns, slippage pattern deviation.
- A `SlashConditionEnvelope` is registered at capability issuance with a condition: `anomalyScore > threshold`.
- When the condition fires, the slash executes automatically from the bond vault.

**Why it is important:** Reputation staking creates skin-in-the-game for every AI operator. If your agent behaves badly, your bond is at risk. This is not a governance mechanism — it is a market mechanism. Bad operators are selected against. Good operators build bond over time, increasing their credibility.

**The expansion:** Users can filter agents by stake amount and slash history. A never-slashed agent with a large stake is a trust signal. This is the Web3-native equivalent of a professional license bond — but it's enforced by code, not regulators.

**Protocol requirement:** Anomaly oracle contract. `SlashConditionEnvelope` type at issuance. Bond vault with slash mechanism. `AgentSlashed` event for indexers. Stake accumulation over time for long-running operators.

---

### 4.5 Trustless Bilateral Escrow

**The idea:** "Release $50,000 USDC to address X if condition Y is met by date D. Otherwise return to me." This is a bilateral contract with no third party, no legal infrastructure, and no escrow agent.

**The mechanism:** A condition tree with two paths:
```
OR(
  AND(condition_Y, timestamp <= D),   → release to X
  AND(NOT(condition_Y), timestamp > D) → return to sender
)
```
The position is encumbered at deposit. Neither path can be blocked by either party. Execution is keeper-triggered when the appropriate condition fires.

**Why it is important:** An enormous fraction of all commercial relationships involve conditional payment — freelancer work, grants with milestones, conditional acquisitions, performance bonuses, contractor payments. All of these are currently either handled by legal contracts (expensive, slow, jurisdiction-dependent) or trust (high risk). Atlas replaces both with a provable commitment.

**The expansion:** Cross-border freelancer payments. DAO grants with provable milestone conditions (oracle reads a specific on-chain event as the milestone). Conditional token unlocks for team vesting without a centralized vesting contract administrator. Private M&A escrow on-chain.

**Protocol requirement:** No new core protocol changes. The condition tree already supports this. What is needed is SDK tooling to make bilateral escrow a first-class workflow: `sdk.escrow.create(amount, asset, recipient, condition, deadline)`.

---

### 4.6 Agent Tournaments and AI Natural Selection

**The idea:** Deploy N strategy configurations simultaneously on paper-trading (or small-capital) vault commitments. A performance oracle tracks each strategy's risk-adjusted returns. After a fixed evaluation period, a time leaf + performance condition envelope automatically promotes the winning strategy to manage the full portfolio by granting it an expanded capability. Losing strategies' capabilities expire.

**The mechanism:**
- At tournament start, N capabilities are issued with equal, small limits.
- A `PerformanceLeaf` oracle reads each strategy's tracked returns from an on-chain performance registry.
- An `ExpandCapabilityEnvelope` is pre-committed per strategy: fires if `strategy.rank == 1` at the evaluation date.
- A `RevokeCapabilityEnvelope` is pre-committed per strategy: fires if `strategy.rank > 1` at evaluation date.
- Promotion and demotion happen automatically at the evaluation timestamp.

**Why it is important:** Capital allocation to AI strategies currently requires human judgment about which model to trust. Agent tournaments make the selection mechanism objective, transparent, and on-chain. The track record is produced under live conditions, not backtests. The promotion mechanism is automatic and cannot be gamed by the operator.

**The expansion:** Strategy tournaments become a product: users deposit capital, select a tournament pool (e.g., "Base ETH strategies, 90-day evaluation"), and let the protocol select the best strategy autonomously. This is an autonomous fund-of-funds infrastructure. The fund manager is the tournament mechanism itself.

**Protocol requirement:** `PerformanceOracle` contract tracking per-vault returns. `TournamentRegistry` managing tournament lifecycles. Performance condition leaf type. SDK tournament setup interface.

---

### 4.7 Privacy-Preserving Collaborative Funds

**The idea:** Multiple users contribute positions to a shared pool strategy. No participant can see how much anyone else contributed. A ZK proof attests to the total pool value without revealing individual contributions. A capability-authorized agent manages the pool strategy. Returns are distributed using a ZK-computed proportional split that reveals nothing about individual positions.

**The mechanism:**
- Each participant makes a vault commitment with a private salt.
- A `PoolRegistrationProof` ZK proof allows the participant to register their commitment in the pool without revealing amount.
- The pool capability authorizes the agent to manage the aggregated position.
- At withdrawal, a `ProportionalShareProof` ZK proof allows each participant to claim their share without revealing pool composition.

**Why it is important:** The next step beyond individual AI agent authorization is AI-managed collective funds. The privacy requirement is not optional — participants in any investment vehicle have a reasonable expectation that their contribution size is private. Without ZK, on-chain collective funds reveal everyone's position to competitors and regulators simultaneously.

**The expansion:** Trustless investment clubs. Dark pool strategies with shared execution. Protocol treasury management where the contributor breakdown is private but the total is public. Privacy-preserving fund-of-funds.

**Protocol requirement:** Privacy path is a Phase 3+ item requiring Aztec integration or equivalent ZK stack. However, the vault commitment model already accommodates ZK proofs architecturally — this is not a redesign, it is an extension of the existing privacy path noted in SPEC.md.

---

## Capability Interaction Matrix

How these capabilities combine:

| Capability | Pairs with | Emergent behavior |
|---|---|---|
| Swarm Consensus (4.1) | Intent Pipelines (2.6) | Entire strategy graph requires swarm approval at each stage |
| Proof of Reserves (4.2) | Strategy NFTs (3.3) | Real-time PoR for any strategy NFT-managed fund |
| AaaS Marketplace (4.3) | ZK Compliance (2.4) | Verifiable track record on every listed agent |
| Reputation Staking (4.4) | Circuit Breakers (2.5) | Automatic slash when circuit breaker fires |
| Bilateral Escrow (4.5) | Sustained Conditions (3.4) | Escrow releases only after sustained condition proves milestone is real |
| Agent Tournaments (4.6) | ZK Compliance (2.4) | Tournament results carry compliance proofs for the winning strategy |
| Collaborative Funds (4.7) | M-of-N Consensus (2.2) | Fund management decisions require consensus from all major contributors |

---

## Specification Priorities for Tier 4

Items are ordered by: (impact × feasibility) / dependency depth.

| Priority | Capability | Core change needed | Phase target |
|---|---|---|---|
| 1 | Bilateral Escrow (4.5) | SDK only | Phase 2 |
| 2 | Proof of Reserves (4.2) | Aggregator contract + indexer | Phase 2 |
| 3 | AaaS Marketplace (4.3) | AgentRegistry + fee routing | Phase 3 |
| 4 | Reputation Staking (4.4) | Anomaly oracle + slash envelope | Phase 3 |
| 5 | Agent Tournaments (4.6) | PerformanceOracle + TournamentRegistry | Phase 3 |
| 6 | Swarm Consensus (4.1) | Merkle swarm key scheme | Phase 3 |
| 7 | Collaborative Funds (4.7) | ZK stack (Aztec) | Phase 4+ |

---

## What This Inventory Proves

The Atlas protocol is not one product. It is a commitment infrastructure that generates a different kind of value at each layer:

- **For individual users:** Automated, constraint-bounded agent execution with liveness guarantees.
- **For operators:** A marketplace to distribute strategies and monetize track records.
- **For institutions:** Real-time proof of reserves, M-of-N consensus, ZK compliance credentials, slashable bonds.
- **For DeFi protocols:** An enforcement substrate for any conditional action — LP management, escrow, forward contracts, options settlement.
- **For the AI agent ecosystem:** The trust layer that transforms AI agents from operational liabilities into auditable, bounded, and verifiable fiduciaries.

The capabilities in this document are not features. They are consequences of the architecture. The architecture was designed for one use case (AI agent authorization). It turns out to be the correct foundation for a much larger set of problems.

---

*This document should be updated as Tier 4 capabilities are moved into formal specification. Target: Tier 4.1 through 4.5 specifications complete by Phase 2 kickoff.*
