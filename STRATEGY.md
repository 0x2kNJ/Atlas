# Product Strategy
## Stateless Agent Protocol
**Internal document — February 2026**

---

## The Invariant

> **No agent signature can move more value than the capability bounds, regardless of whether the agent key is compromised, jailbroken, manipulated, or acting maliciously.**

This is the protocol's core guarantee. Everything in this document is downstream of it.

---

## Positioning: Delegation is the Consent Rail. Atlas is the Enforcement Rail.

The ecosystem is converging on fine-grained delegation as the default way a user grants authority to an agent. MetaMask, Coinbase, and the ERC-7710/7715 working group are standardizing permission UX — requesting, reviewing, revoking — and shipping libraries developers can adopt with minimal friction.

We agree with that direction. We build on top of it.

Delegation answers: **"Is this agent allowed to do X?"**
Atlas answers: **"Can X happen reliably, safely, and with correct outcomes — even when the agent is offline, the network is adversarial, and MEV is trying to extract value?"**

These are different questions. Wallet delegation solves the consent problem. It does not solve the enforcement problem. An agent that holds a valid MetaMask delegation and goes offline at 3am cannot execute a stop-loss. A delegation caveat that specifies "max $1,000/day" does not guarantee the swap executes at a fair price, that the oracle isn't stale, or that a keeper will show up.

**What wallet delegation is the right tool for:**
- User consent and comprehension: familiar, wallet-native permission screens
- Standardized authority objects: portable, inspectable grants with revocation semantics
- Broad ecosystem interoperability: works across apps and frameworks by default

**What Atlas adds that delegation cannot provide:**
1. **Liveness-independent enforcement** — pre-committed conditional execution that fires permissionlessly via keepers even when the agent is offline, compromised, or destroyed
2. **Execution guarantees under adversarial conditions** — MEV protection, oracle staleness rules, and limit-price semantics on every execution
3. **Coherent multi-agent authority chains** — delegation that composes across orchestrator → specialist → execution agent with verifiable constraint inheritance
4. **Commitment-based custody** — positions as discrete encumberable objects, not account balances; the primitive that makes liveness-independent enforcement architecturally possible

**The correct stack:**
```
Wallet delegation   → consent + permission UX
Atlas               → enforcement + execution guarantees + reliability
Existing venues     → liquidity (DEXes, aggregators, perps)
```

Atlas is not trying to replace wallet delegation. It is trying to make delegation useful for agentic finance. Wallets win when users can safely adopt automation. We make that safety guarantee real.

---

## The Core Mental Model

```
User
 ├── signs Capability (off-chain, zero gas)
 │     └── scope: vault.spend
 │     └── constraints: max 1000 USDC/day | only Uniswap adapter | minReturn 98%
 │
 └── deposits → SingletonVault
       └── positionHash = keccak256(owner, asset, amount, salt)
             (no per-user contract — just a commitment in a shared registry)

Agent Key (hot key, LLM, server)
 └── generates + signs Intent (off-chain, zero gas)
       └── adapter: Uniswap | minReturn: 0.38 ETH | deadline: now+5min

Solver
 └── submits Intent + Capability → CapabilityKernel
       └── verify: issuer sig ✓ | grantee sig ✓ | scope ✓ | constraints ✓
       └── verify: nullifier not spent ✓ | position exists ✓ | not encumbered ✓
       └── release assets → adapter executes → output committed to vault

Parallel path (Envelopes, liveness-independent):
Agent → pre-signs Envelope: "if ETH < $1800, execute this sell"
  └── position encumbered in vault (cannot be spent by other intents)
Keeper → observes oracle → triggers → same execution pipeline
  └── fires even if agent is offline / compromised / destroyed

Extended paths (Advanced Primitives):
Dead Man's Switch → fires when agent goes SILENT (reverse liveness)
  └── "if agent hasn't heartbeated in 72h → emergency sell all positions"
M-of-N Consensus → fires only when M of N risk agents co-sign the intent
  └── "require 3-of-5 independent agents to approve $500k rebalancing"
Condition Tree → fires on boolean combinations of oracle conditions
  └── "sell if (ETH < $1800 AND vol > 80%) OR (ETH < $1500)"
Conditional Capability → agent is only authorized within a specific regime
  └── "this agent's $10k limit only activates during high-volatility periods"
```

This is the protocol. Four paths, one kernel, one vault, zero per-user contracts.

---

## The Thesis

AI agents will be the primary interface to DeFi within three years. Not as a feature — as the default.

When that happens, the infrastructure question that matters is: *what does agent authorization and custody look like?*

The current answer is wrong. AI agents today operate through EOA keys (worst case), session keys on smart accounts (slightly better), or hardcoded ERC-20 approvals (marginally acceptable). All of these treat the agent as an account, or treat the account as the agent. The two things are being conflated.

An AI agent is not an account. It is a policy engine with a signing key. It should hold no custody, carry no persistent identity, and have authority scoped to exactly what the user intended — cryptographically enforced on-chain, not just instructed in a system prompt.

The agent-as-account model fails on four dimensions simultaneously:

- **Compromise:** Hot keys on servers get stolen. Session key compromise drains everything within scope before revocation is possible.
- **Liveness:** Agents go offline. Stop-losses don't fire at 3am if the server is down.
- **Delegation:** Orchestrator agents sub-delegating to specialist agents need structured authority chains, not multiple accounts.
- **Privacy:** Institutional users need positions that are not publicly visible to counterparties.

ERC-4337 solves general-purpose smart accounts. It is not designed for constrained delegation or liveness-independent enforcement. We are not replacing it — we are building the tighter primitive it doesn't provide: scoped, bounded, revocable agent authorization with autonomous enforcement.

---

## Why Now: Evidence, Not Vibes

The AI agent wallet category is real and growing fast, but the authorization infrastructure is actively broken. Specific observable signals:

**Adoption trendline:**
- Eliza (ai16z) launched late 2024. Within 60 days it was the most forked AI agent repository in crypto. Hundreds of plugins, thousands of deployed instances — nearly all using EOA keys or `type(uint256).max` ERC-20 approvals.
- Coinbase AgentKit launched December 2024. Provides an opinionated framework for on-chain AI agents. Ships with session keys and standard ERC-4337 accounts. The team acknowledges the authorization model is the unsolved problem.
- MetaMask Smart Accounts Kit (formerly Delegation Toolkit): active development through 2025, deployed on Arbitrum and other chains, with ERC-7710 delegations and ERC-7715 permission requests. Solves the smart account delegation problem. Does not solve commitment-based custody, liveness enforcement, or multi-agent hierarchies.

**Standard war timeline:**
- ERC-8001 (Agent Coordination): published August 2025. Explicitly defers authorization, enforcement, and privacy.
- ERC-8004 (Trustless Agent Identity): published August 2025, co-authored by MetaMask, Ethereum Foundation, Google, Coinbase. Solves discovery and reputation. Does not standardize what agents are authorized to do.
- The authorization/intent/enforcement layer — Layer 3 in the standards stack — has no ERC proposal. This is the gap.

**Known failure modes in production:**
- Multiple documented cases of session key exploits in DeFi bot infrastructure (2024–2025): compromised keys draining everything within session scope before revocation.
- EOA-based trading bots routinely drained via allowance exploitation — `approve(router, type(uint256).max)` with no spend limits.
- Keeper failures during the August 2024 crypto volatility event: automated liquidation systems offline or under-incentivized during peak market stress, positions not liquidated as expected.

**The window:** 12–18 months before MetaMask's distribution and Coinbase's developer mindshare locks in "good enough" account-based solutions. After that, switching costs make architectural correction extremely expensive for the ecosystem.

**The Coinbase scenario (most dangerous near-term threat):**
Coinbase has AgentKit (developer framework), CDP Wallet (custody and key management), Base (L2 with AI agent developer concentration), and distribution to millions of Coinbase Wallet users. The question is not whether Coinbase will add enforcement to AgentKit — it is when, and whether Atlas is already embedded in enough framework integrations before they do.

Coinbase doesn't need to be architecturally correct. They need "good enough" at 100x the developer reach. Their likely path is: session keys today → limited conditional execution ("if balance > X, rebalance") → basic keeper infrastructure built into AgentKit. This is slower than it sounds — session key infrastructure took Coinbase 6 months to stabilize. Commitment-based custody and MEV-protected envelope execution are months of additional work.

**Why the window holds even if Coinbase ships fast:**
1. By the time Coinbase ships enforcement, Atlas should have 3+ framework integrations and $1M+ TVL. Switching requires integrators to rebuild agent logic, which they won't do for a marginal improvement.
2. Coinbase's enforcement will be CDP/Base-specific. Atlas's interoperability (7579 module, 7710 bridge, multi-chain nullifier) means the authorization standard is chain-agnostic. Integrators building cross-chain agents need Atlas.
3. Coinbase won't build the data network effect the right way. Their incentive is to keep execution data proprietary. Atlas's commitment to publishing execution quality metrics and open keeper infrastructure is the counter.

The risk that actually matters: Coinbase buys or partners with a team building the correct architecture. Watch for this. If it happens before Atlas has significant framework lock-in, the window closes fast.

---

## The Customer

Three customers. This is the order we win them.

### Customer 1: AI Agent Framework Developers

**Who:** Engineers building Eliza plugins, Coinbase AgentKit integrations, AutoGPT tool chains, enterprise AI workflow automation, bespoke trading bots.

**What they have:** EOA keys with `approve(max)`, session keys on 4337 accounts, or tool-calling APIs with hardcoded approval grants.

**What they hate:** One bad inference, one prompt injection, one compromised server → full fund loss within the session scope. They know this is wrong. They have no better option that ships in a day.

**What we give them:** An SDK where `createCapability()` takes 5 minutes and produces a cryptographically bounded authorization. The agent key can be hot. The constraints are cold, on-chain, and cannot be reasoned around.

**Why first:** They are the distribution channel. One framework integration reaches all their users. One security incident prevented becomes the case study that generates the next ten integrations.

### Customer 2: Autonomous DeFi Users

**Who:** Power users running AI-managed portfolios — rebalancing, yield optimization, automated stop-losses — who won't give an agent full wallet access.

**What we give them:** Deposit once, set constraints, the agent operates within those bounds. Stop-losses fire permissionlessly via envelopes even when the agent is offline. Authority revoked in one transaction.

**Why second:** They validate TVL and generate concrete metrics. But they need the agent ecosystem to exist first.

### Customer 3: Institutional AI Trading Infrastructure

**Who:** Crypto hedge funds, prop desks, protocol treasuries with automated execution systems.

**What they need:** Private positions, structured delegation chains (analyst AI → risk AI → execution AI), audit trails for compliance, enforceable positions independent of system availability.

**What we give them in Phase 3:** Private vaults via Aztec, delegation chain verification (A→B→C with constraint subset enforcement), receipt hashes as compliance records.

**Why third:** Long sales cycles, high compliance bar, highest willingness to pay, strongest validation signal.

---

## The Product

Three layers. All three must exist. Removing any one breaks the others.

**Layer 1: Authorization (Capability Tokens)**
Off-chain EIP-712 signed structs. Scope, constraints, expiry, nonce. Zero on-chain setup. One transaction to revoke. The agent has no on-chain existence until it executes.

**Layer 2: Custody (Singleton Vault + Commitments)**
A single shared vault. Positions are `keccak256(owner, asset, amount, salt)` commitments — not `balances[user]`. No deployed contracts per user. Positions are discrete objects that can be individually encumbered, released, or migrated to Aztec private notes.

**Layer 3: Enforcement (Envelopes)**
Pre-committed conditional execution. Agent pre-authorizes "if ETH < $1800, execute this sell" while online. Envelope fires permissionlessly via any keeper when the oracle condition is met — even if the agent is offline, compromised, or destroyed. This is the primitive that doesn't exist anywhere else.

**Layer 4: Observability (Monitoring + Receipts)**
Agents fail in ways that are invisible until they've done damage. The protocol surfaces failure before it compounds:
- **Constraint trigger alerts** — every intent blocked by a capability constraint emits a typed event. The SDK surfaces this to the user in real time: "this intent was blocked because your $1,000 daily limit was reached ($847 spent so far today)."
- **Anomaly detection** — intent frequency, size, and adapter distribution are compared against the agent's historical baseline. Outliers (50 intents in one hour from an agent that normally submits 3/day) generate an alert before the period limit is reached.
- **Audit log receipts** — every executed intent emits a receipt hash: `keccak256(nullifier, positionIn, positionOut, adapter, amountIn, amountOut, timestamp)`. Receipts are human-readable in the SDK (`sdk.getReceipt(txHash)`) and include: what was authorized (capability constraints), what was executed (intent parameters), and what was produced (output position). This is the compliance record for Customer 3 — the authorized vs. executed delta is always auditable.
- **Envelope status feed** — active, triggered, cancelled, and expired envelopes are queryable. Keepers can monitor coverage; users can see when their stop-losses fire.

**Layer 5: Constraint UX (Safe Defaults + Simulation)**
Users cannot reason about raw parameters. "Max spend per period" and "min return floors" are the right primitives — until a user sets `minReturn: 0` or a period limit that permits catastrophic one-shot drain.
- **Safe presets** — the SDK ships opinionated presets: Conservative (50% of position/day, 98% minReturn, Uniswap only), Standard (20% of position/day, 97% minReturn, Uniswap + Aave), Aggressive (50% of position/day, 95% minReturn, all adapters). Users can override any field.
- **Backsimulation** — before finalizing a capability, the SDK shows: "given these constraints, here is what would have executed over the last 90 days in market conditions similar to today." This makes "max $1,000/day" legible.
- **Explainability** — every constraint check in the kernel maps to a human-readable error. `PERIOD_LIMIT_EXCEEDED` becomes "blocked: you've spent $847 of your $1,000 daily limit; resets in 4h 12m." This surfaces through the SDK and is loggable to any monitoring system.

---

## State Inventory

"Stateless" is precise: agent identity and authorization objects carry zero on-chain footprint. The system keeps only the minimum state required for replay prevention, custody tracking, and conditional enforcement.

**On-chain state — what exists:**

| Contract | State key | Purpose | Growth |
|---|---|---|---|
| CapabilityKernel | `spentNullifiers[hash]` | Replay prevention | Append-only; 1 entry per executed intent |
| CapabilityKernel | `revokedNonces[issuer][nonce]` | Capability revocation | User-controlled; sparse |
| CapabilityKernel | `periodSpending[capHash][period]` | Spend limit enforcement | Indexed by period; naturally expires |
| CapabilityKernel | `adapterRegistry[address]` | Adapter allowlist | Governance-controlled; small set |
| SingletonVault | `positions[hash]` | Active commitment set | Grows on deposit, shrinks on withdrawal |
| SingletonVault | `encumbered[hash]` | Envelope locks | Subset of positions; transient |
| EnvelopeRegistry | `envelopes[hash]` | Active conditional orders | Grows on register, shrinks on trigger/cancel |

**Off-chain state — what lives outside the chain:**

| Object | Lives where | Who controls it |
|---|---|---|
| Capability tokens | User's signing environment | User (issues), Agent (holds) |
| Agent policies & LLM configs | Agent infrastructure | Agent operator |
| Intent generation logic | Agent process | Agent operator |
| Position preimages (salt) | User's key management | User |

**What is not stored anywhere:**

- No per-user account or contract
- No per-agent contract or registry entry
- No on-chain capability registry (capabilities never touch chain independently)
- No persistent agent identity (zero chain footprint between executions)

An agent that has never executed: zero on-chain state. A user who deposits and withdraws without using an agent: zero residual state. State scales with active economic activity, not user count.

---

## Threat Model

Nine attacks. Each gets a precise mitigation. Protocol people will ask all of these.

### 1. Prompt Injection → Malicious Trade

**Attack:** Adversarial input manipulates the LLM into generating an intent to drain the user's position.

**What stops it:** Capability constraints are enforced on-chain by the CapabilityKernel, not by the LLM. The LLM cannot generate an intent that exceeds `maxSpendPerPeriod`, uses a non-allowlisted adapter, or produces output below `minReturn`. Even a fully compromised LLM that generates the worst possible intent will have it rejected at the kernel verification step. The constraint is the safety layer; the LLM is irrelevant to the security boundary.

**Beyond injection: treating LLM failure as a measurable risk class**

Prompt injection is one failure mode. LLMs are stochastic systems with a broader failure taxonomy that the protocol treats explicitly:

- **Adversarial steerability** — an LLM agent can be steered through accumulated context manipulation (not a single injection) toward decisions that are individually within-constraint but collectively harmful (e.g., repeated small sells that total the period limit, each one "valid")
- **Distribution shift** — an agent's behavior may drift from its intended policy as its model updates, fine-tunes, or context window changes
- **Jailbreak under new model versions** — a constraint-respecting policy can regress to constraint-violating behavior after a model update

**Protocol-level responses:**
- Constraints bound the blast radius of any individual intent regardless of how the LLM was steered. Behavioral drift cannot exceed the period limit; accumulated manipulation is rate-limited by design.
- The SDK ships a policy simulation harness: given a capability's constraints, the harness generates adversarial intent sequences and verifies the kernel rejects them. This runs as a pre-deployment test, not a runtime check.
- Anomaly detection (see Monitoring section) flags intent frequency outliers — a compromised agent generating 50 intents in an hour is detectable before the period limit is reached.

We are the first protocol that explicitly models LLM failure modes as a protocol-level risk class, not just an application-layer concern. The constraints are the floor. The harness and monitoring are the ceiling.

---

### 2. Hot Key Compromise

**Attack:** Attacker steals the agent's private key and submits malicious intents.

**What stops it:** The capability token scopes what any key can do, regardless of who holds it. `maxSpendPerPeriod` caps the maximum loss to one period's allowance (e.g., $1,000/day). User revokes the capability in one transaction (`revokeCapability(nonce)`). All subsequent intents from the compromised key fail immediately at step 6 of kernel verification. Total maximum loss: assets within the current period's spent limit minus what the attacker can drain before revocation. This is bounded, not unbounded.

---

### 3. Keeper Bribery / Non-Execution

**Attack:** A keeper is bribed to suppress a specific envelope trigger, preventing a user's stop-loss from firing.

**What stops it:** Keepers are permissionless — any address can trigger any matured envelope. No keeper has exclusive rights to any envelope. If one keeper is bribed or goes offline, any other keeper can trigger and claim the reward. The reward (keeperRewardBps + minKeeperRewardWei) creates positive economic incentive for any honest party to trigger. We publish a reference keeper client that anyone can run. In practice, a bribed keeper creates an arbitrage opportunity for every other keeper.

---

### 4. Oracle Manipulation and Failure Modes

Oracle risk has two categories: active manipulation and passive failure. Both require explicit handling.

**Active manipulation — premature or suppressed triggers**

Flash loan manipulation requires moving a Chainlink aggregated price across multiple independent sources simultaneously, which is economically infeasible for large-cap assets. On-chain oracle reads at trigger time mean the keeper cannot lie — the price is read directly from the oracle contract at the exact block. `minReturn` on every envelope intent provides a hard floor independent of the oracle price: even if an oracle is manipulated to trigger an envelope early, the execution cannot produce less than `minReturn`. Oracle manipulation can cause an early trigger; it cannot cause a bad fill.

**Passive failure modes — the production reality**

Oracle feeds fail in ways that aren't manipulation:

| Failure mode | Behavior | Mitigation |
|---|---|---|
| Stale round (no update in > 1h) | `MAX_ORACLE_AGE = 3600` rejects — envelope execution pauses, not fails | Direct vault withdrawal always available |
| Chain halt (L2 sequencer down) | Sequencer uptime feed (Chainlink) checked before any envelope trigger | Envelope execution blocked during halt; position inaccessible for trigger but withdrawable |
| Depeg (e.g., USDC loses peg) | Trigger price denominated in depegged asset may fire at wrong economic value | Per-envelope oracle config must specify quote asset carefully; SDK warns on stablecoin-denominated triggers |
| Feed outage (Pyth fallback also unavailable) | Fail-closed: envelope does not trigger | Keeper can cancel expired envelopes; user can withdraw directly |

**Dual-oracle design (Phase 2):** Primary feed is Chainlink. If Chainlink round age > `MAX_ORACLE_AGE`, fallback to Pyth Network. If Pyth is also stale, envelope execution fails closed. Both feeds going stale simultaneously is the residual risk — acceptable for the positions sizes this protocol targets in Phase 1.

**Oracle governance:**
- Oracle address per envelope is set at registration time and is immutable for that envelope. Keepers cannot substitute a different feed.
- Protocol-level allowed oracle set is maintained by the multisig. Adding a new oracle requires a 48-hour timelock. Removing an oracle is immediate (emergency) or 48-hour (routine).
- Users who want to use an oracle outside the allowed set cannot — this prevents custom malicious feed injection.

---

### 5. MEV Sandwich on Triggered Envelopes

**Attack:** Sandwich bot sees a keeper's trigger transaction in the mempool, frontruns the swap to extract value.

**What stops it — Phase 2 (at launch):** Keeper clients submit trigger transactions exclusively via Flashbots Protect bundles. The trigger and the resulting execution are atomic in a single private bundle. No frontrunning window exists. `intent.minReturn` provides a hard floor on output regardless of routing — the worst the user gets is minReturn exactly, never less.

**What stops it — Phase 3 (open keeper market):** `adapterData` inside envelopes is threshold-encrypted to a 2/3 set of registered keepers. No single keeper knows the full execution parameters until the threshold decryption at trigger time, which is atomic with execution. The parameters are cryptographically hidden until execution is irreversible.

**Anti-sandwich baseline (always present):** Every intent requires `minReturn` set by the agent at envelope creation time. This is the non-negotiable floor. Sandwiching can only extract value above the floor, and the floor can be set to the TWAP-derived fair price at envelope creation time.

---

### 6. Solver Censorship / Degradation

**Attack:** Solver refuses to process intents from specific users or during specific market conditions.

**What stops it:** `intent.submitter` allows users to designate a specific solver or `address(0)` (permissionless). In Phase 1, a censored user can override to permissionless fill after a 24-hour window (documented in protocol terms). In Phase 3, the open solver market means any address can execute any permissionless intent — censorship by one solver creates fee revenue for every other solver. This is the economically stable outcome.

---

### 7. Adapter Exploit

**Attack:** A malicious or buggy adapter drains assets during execution.

**What stops it:** Adapters are separate contracts with no persistent storage. The kernel releases assets to itself (not the adapter), approves the adapter for exactly `amountIn`, calls `adapter.execute()`, then immediately clears the approval. An adapter can only touch assets it receives in that exact transaction — it cannot reach back into the vault. The adapter registry has a 48-hour timelock for new additions, giving users time to exit before a potentially malicious adapter becomes active. Audited adapters are the only approved adapters in the registry.

---

### 8. Replay / Signature Malleability / Cross-Chain Replay

**Attack variants:** Resubmit a spent intent; manipulate a valid signature; use a Base-signed intent on Arbitrum.

**What stops replay:** Nullifier = `keccak256(intent.nonce, intent.positionCommitment)` stored permanently after execution. Once a position commitment is spent, it no longer exists in the vault — both the nullifier and the commitment must not exist.

**What stops signature malleability:** EIP-712 structured typing prevents raw hash signing. ECDSA's `recover()` as implemented in OpenZeppelin's library normalizes `v` values and rejects malleable signatures.

**What stops cross-chain replay:** EIP-712 domain includes `chainId`. A capability or intent signed on Base (chainId 8453) produces a different digest than the same struct on Arbitrum (chainId 42161). Submitting to the wrong chain fails at signature recovery step 1.

---

### 9. Governance / Upgrade Key Compromise

**Attack:** Admin multisig is compromised; attacker tries to steal user funds via protocol changes.

**What stops it:** Admin scope is deliberately narrow. Admin can: pause contracts, add adapters (48h timelock), remove adapters, update protocol fees. Admin cannot: read or move user funds, alter existing position commitments, bypass the emergency withdrawal path, force-execute intents. The vault's `emergencyWithdraw` is callable by position owners regardless of admin state — not even a paused vault can prevent fund recovery. Multisig is 3-of-5 from day one; pausing requires 2-of-5; adapter additions require 3-of-5 plus the timelock.

### 10. Delegation Chain Safety: Confused Deputy Attacks

**The problem:** Multi-agent systems introduce a class of vulnerability that single-agent systems don't have. When an Orchestrator agent sub-delegates to a Risk agent, which sub-delegates to an Execution agent, the question is: what authority does each agent actually have, and what happens when the chain is broken?

Without explicit rules, delegation chains become footguns:
- An intermediary agent could grant authority it doesn't possess (authority amplification)
- A compromised intermediary could widen constraints on the sub-capability it issues
- Revocation of a parent capability might not propagate to active child capabilities
- Two independent sub-capabilities from the same parent could authorize conflicting operations

**Protocol rules for delegation chains:**

**Rule 1: Sub-capabilities cannot exceed parent constraints.** When agent A issues a sub-capability to agent B, the CapabilityKernel verifies that B's constraints are a strict subset of A's capability. `maxSpendPerPeriod(B) ≤ maxSpendPerPeriod(A)`. `allowedAdapters(B) ⊆ allowedAdapters(A)`. A sub-capability that attempts to widen any constraint is rejected at verification, not at execution.

**Rule 2: Authority chains are linear, not additive.** Agent C executing under a chain A→B→C cannot aggregate authority from multiple branches. The execution uses the most restrictive constraints across the chain. There is no OR semantics — a chain is as constrained as its tightest link.

**Rule 3: Revocation propagates immediately.** When the root issuer (the user) revokes a capability nonce, every sub-capability that references that nonce — directly or transitively — is invalidated. Sub-capabilities store the root capability hash in their lineage field. The kernel checks the full lineage on every execution.

**Rule 4: Sub-capability issuance requires `envelope.manage` or `vault.spend` scope, not both.** An agent authorized only to spend positions cannot create envelopes. An agent authorized only to manage envelopes cannot submit intents. Scope conflation is not possible.

**What this means for Demo 3:** The Analyst → Risk → Execution chain is secure because each agent's sub-capability must pass kernel constraint verification against its parent. The Execution agent cannot do anything the Risk agent's capability doesn't permit. The Risk agent cannot do anything the Analyst's capability doesn't permit. The user's capability is the root. Compromise of any intermediate agent is bounded by that agent's constraints, not the root capability.

---

## Exit Guarantees

The singleton vault is the first credibility question from protocol engineers and institutional users. The answer must be stated as invariants, not assurances.

**Invariant 1: Unilateral exit is always possible.**
A user who holds their position preimage (owner, asset, amount, salt) can call `vault.withdraw()` directly at any time when the vault is not paused, with no dependency on the kernel, solvers, or keepers. No permission from any third party is required.

**Invariant 2: Emergency exit works even when the vault is paused.**
`vault.emergencyWithdraw()` is callable only when paused and only by the position owner. It ignores encumbrance (envelope locks). User funds cannot be made inaccessible by any admin action. The admin can pause normal operations; the admin cannot prevent fund recovery.

**Invariant 3: Vault solvency is structurally guaranteed.**
The vault maintains exactly one ERC-20 balance per token equal to the sum of all active position amounts for that token. This is a structural property of the deposit/release/commit pattern — no position can be spent without simultaneously creating a new position of equal or lesser value. No external party can create positions without transferring the exact underlying tokens. The commitment model makes undercollateralization architecturally impossible without an explicit bug.

**Invariant 4: Censorship resistance has a time bound.**
A solver censoring a specific user cannot prevent that user from executing indefinitely. In Phase 1, a 24-hour censorship window allows override to permissionless fill. In Phase 3, any address can fill any permissionless intent. In all phases, the user can always withdraw directly from the vault — delegation is optional, custody is not.

**The only off-chain dependency for fund recovery:** The position preimage (the salt chosen at deposit time). Users must retain this. Loss of the salt means loss of the ability to prove ownership of the commitment. This is documented clearly in the SDK and UI.

---

## Execution Guarantees Under Adversarial Conditions

The following five guarantees are commitments, not design goals. They apply at launch within the scope of Phase 1 and Phase 2 respectively. Skeptics should evaluate each one directly.

**Guarantee 1: Every execution has limit-price semantics.**
Every intent — whether submitted directly by an agent or triggered by a keeper from an envelope — carries a `minReturn` field that is enforced on-chain by the IntentExecutor before the output position is committed. There is no execution path that can produce less than `minReturn`. The executor reverts if the condition is not met. This is not a slippage setting; it is a hard on-chain invariant.

**Guarantee 2: MEV-protected execution path is supported from envelope launch (Phase 2).**
Keeper clients submit trigger transactions via Flashbots Protect bundles. The trigger and the resulting execution are atomic in a single private bundle. No frontrunning window exists. Keepers who submit via public mempool are disadvantaged by MEV extraction from their own trigger fees — market pressure enforces private submission. In Phase 3, `adapterData` inside envelopes is threshold-encrypted to a 2/3 keeper quorum, making frontrunning structurally impossible.

**Guarantee 3: Oracle staleness is enforced; fail-closed behavior is documented.**
`MAX_ORACLE_AGE = 3600`. An oracle round older than 1 hour blocks envelope execution. This is not configurable by keepers or users — it is a protocol-level check. When the oracle is stale, the envelope does not trigger; it does not execute with bad data. The user's position remains encumbered but withdrawable directly. The dual-oracle fallback (Pyth) is active in Phase 2.

**Guarantee 4: Unilateral exit always exists.**
A user who holds their position preimage can call `vault.withdraw()` directly at any time the vault is not paused, with no dependency on any third party. `vault.emergencyWithdraw()` is callable when the vault is paused, ignores encumbrance, and cannot be blocked by any admin action. The only dependency for fund recovery is the position salt — documented clearly in the SDK. Admin cannot make user funds inaccessible.

**Guarantee 5: Keeper incentives are economically sustainable by design.**
`keeperRewardBps` and `minKeeperRewardWei` are enforced at envelope registration — an envelope that cannot profitably incentivize a keeper on Base (where trigger gas is $0.05–0.20) is rejected at creation, not at trigger time. A keeper that triggers an envelope earns the reward regardless of which keeper triggers it. There is no exclusive keeper assignment. "Liveness-independent" does not mean "best-effort" — it means the economic structure makes triggering profitable for any keeper who shows up.

---

## Interoperability: We Upgrade Everyone

The correct competitive posture is not "MetaMask is wrong." It is: "We provide the authorization primitive that every existing system is missing. Here is how each one can adopt it without migrating custody."

### Mode 1: ERC-7579 Module — Zero Custody Migration

Smart account users (Biconomy, Alchemy, Safe) get the capability delegation model without moving assets. We publish a 7579 executor module:

```
ERC-7579 Smart Account
  └── CapabilityExecutorModule (executor module)
        └── verifies capability + intent signatures
        └── routes execution → CapabilityKernel
```

What this gives them: capability scoping, constraint enforcement, revocable delegation. What they don't get: commitment-based custody, envelope enforcement (requires the vault for encumbrance). This is the on-ramp. Users who need envelopes migrate assets to the vault. The module generates 7579 distribution with no friction.

### Mode 2: ERC-7710/7715 Bridge — MetaMask Users

We publish a caveat enforcer that MetaMask DeleGator accounts can use as a routing mechanism into CapabilityKernel. MetaMask users keep their delegation UX; we provide the execution backend with our constraint model. This is a one-way bridge: MetaMask delegation architecture → our execution layer.

### Mode 3: ERC-8004 Composition — Agent Identity Layer

Our capability token optionally includes an ERC-8004 agent ID in metadata. ERC-8004's discovery and reputation layer becomes more valuable when paired with a verifiable authorization layer. The composability framing with the EF/MetaMask/Google/Coinbase coalition turns a potential competitor relationship into a potential co-authorship relationship.

### The Two Modes of Adoption

```
Mode A: Module Mode (lowest friction, no custody migration)
  Smart account → CapabilityExecutorModule → CapabilityKernel
  Gains: authorization model, constraint enforcement
  Missing: commitment custody, envelopes

Mode B: Vault Mode (full protocol, maximum guarantees)
  User → SingletonVault → CapabilityKernel + EnvelopeRegistry
  Gains: everything — authorization, commitment custody, liveness enforcement, Aztec path
```

Mode A generates distribution. Mode B is the product. Users migrate from A to B when they need envelopes.

---

## MEV Strategy

### Regular Intents

Phase 1: `intent.submitter` locks execution to the protocol's designated solver. Solver routes all transactions through Flashbots Protect. No frontrunning possible for named-submitter intents.

Phase 3 (open solver market): Competitive execution with private RPC. Intents submitted with `submitter = address(0)` accept public mempool risk but benefit from competitive solver pricing. Protocol recommends named submitters for positions > $10,000.

### Envelope MEV — Three-Phase Defense

Envelope triggers have distinct MEV exposure: when a keeper submits a trigger, the intent parameters are revealed before execution completes.

**Phase 2 (ships with envelopes):** Keeper clients submit trigger transactions via Flashbots Protect bundles. Trigger + execution are in a single atomic private bundle. Keepers who use public mempool are disadvantaged by MEV extraction from their own trigger fees — market pressure enforces private submission. `minReturn` on every intent provides a hard output floor regardless of sandwich depth.

**Phase 3 (open keeper market):** `adapterData` inside envelopes is threshold-encrypted to a 2/3 quorum of registered keepers. No single keeper can decrypt the full execution parameters until the threshold decryption, which is atomic with execution. Frontrunning is structurally impossible because the parameters are unknown until the execution is already committed.

**Phase 4 (Aztec):** Intent is a private note. Execution is a private transaction. MEV eliminated by ZK.

**Anti-sandwich baseline (always active):** `minReturn` is set at envelope creation time, ideally derived from a TWAP at that moment. A sandwich bot can only extract slippage above the floor — and the floor is set by the user, not the attacker.

### Keeper Incentive Design

Keepers must profit on every trigger. The incentive structure is:

- `keeperRewardBps`: percentage of gross output (max 5%)
- `minKeeperRewardWei`: absolute floor in output token units (minimum $5 equivalent at deployment)
- Gas is the keeper's cost. On Base, trigger gas is approximately $0.05–0.20. `minKeeperRewardWei` must exceed this by a meaningful margin.
- Protocol-level `protocolMinKeeperRewardWei` enforced at envelope registration — envelopes with inadequate keeper rewards are rejected at creation, not at trigger time.

Anti-spam: envelopes require the vault to encumber the underlying position. Creating a spam envelope that can never be profitable requires locking real capital. The spam attack is economically self-defeating.

---

## Standards Positioning

Four distinct layers are being standardized. We are authors of one layer, consumers of three.

```
Layer 1: Identity / Discovery
  Who is this agent? What does it claim to do? What is its reputation?
  Standards: ERC-8004, ERC-8126, ERC-7857
  Our role: CONSUMER — reference agent IDs in capability metadata.

Layer 2: Multi-Agent Coordination
  How do multiple agents agree on a shared action?
  Standards: ERC-8001
  Our role: COMPATIBLE — our intent is the output of a coordination round.

Layer 3: Authorization / Intent / Enforcement   ← WE PROPOSE THIS
  What is this agent authorized to do?
  What exactly should it execute?
  What happens if conditions trigger without the agent online?
  Standards: NONE. This layer is unstandardized.
  Our role: AUTHOR of the capability token + intent + envelope formats.

Layer 4: Execution / Settlement
  How do intents execute on-chain?
  Standards: ERC-7521, ERC-7683
  Our role: COMPATIBLE — our adapters produce ERC-7683-compatible fills.
```

The standardization pitch to ERC-8004 authors: "You standardized agent identity. We're standardizing what agents are authorized to do. These questions are different. The combination of ERC-8004 discovery + our authorization standard creates a complete agent trust model. Neither is useful alone."

### Capability Tokens as the Ecosystem Trust Layer

ERC-8004 builds agent trust from historical reputation: tasks completed, feedback received. This is backward-looking and gameable — establish track record on small tasks, exploit large ones.

Capability tokens build trust from what users have actually authorized, not what agents claim about themselves. If capability hashes are indexed (not the preimage — the hash only), Atlas becomes a discoverable trust signal: "N users have issued capabilities to this agent key, M are still active, with these constraint profiles." This is forward-looking, cryptographically enforced, and cannot be faked.

The strategic move: Atlas becomes the place where agent trust is established empirically. An agent that has been granted and executed within capabilities across 1,000 users, with zero constraint violations, has a trust signal more meaningful than any self-reported registry entry. The data network effect (execution history) feeds the trust layer. The trust layer feeds capability issuance (users grant capabilities based on the agent's track record). This compounds.

**The ERC-8004 integration reframe:** Rather than "we consume ERC-8004 agent IDs as metadata," the correct framing is: "ERC-8004 IDs are the lookup key; Atlas capability history is the trust record. Neither is useful alone. Together they form the complete agent trust primitive the ecosystem needs." This positions Atlas as essential to any serious agent identity system, not optional.

What this unlocks strategically: any framework, wallet, or protocol that cares about agent trust needs Atlas data. That's a pull mechanism for adoption that doesn't require cold outreach — it's a natural dependency.

### How Standards Actually Win

We will not file an ERC proposal before having production adoption. The correct sequence:

1. **Ship reference implementation + test vectors.** Anyone can verify conformance to the capability token format before the ERC exists.
2. **Publish a conformance test suite.** Given a capability + intent + signatures, the suite verifies the implementation is correct. Wallets and frameworks can self-certify.
3. **Wait for three independent implementations.** Our protocol, the 7579 module, and one third-party integrator.
4. **Then propose the ERC.** With three implementations and a test suite, the proposal is a documentation exercise, not an advocacy campaign.

ERC-20 succeeded because six functions were already implemented everywhere before the EIP was filed. That is the model.

---

## Go-to-Market

### Phase 1: Earn Framework Developers (Months 1–4)

The SDK is the product. The contracts are the backend.

Three SDK calls, 20 minutes to hello-world:

```typescript
const cap  = await sdk.createCapability({ grantee: agent.address, scope: "vault.spend", ... });
const intent = await sdk.createIntent({ positionCommitment, adapter, minReturn, ... });
const receipt = await sdk.submitIntent({ intent, cap, capSig, intentSig });
```

Deploy on Base. One chain, one permissioned solver (us), one audit underway. Make it boring and reliable.

Target integrations in order: Eliza (ai16z), Coinbase AgentKit, one bespoke trading team. The trading team generates real TVL and the case study that drives the next ten integrations.

**Phase 1 end-state:** 3 framework integrations, $1M TVL, audit completed.

---

## ClawLoan Integration: The Beachhead Application

ClawLoan is the clearest single demonstration of why Atlas exists. It provides uncollateralized credit to AI agents — a product category that is impossible to build safely without liveness-independent enforcement. The integration demonstrates Atlas across four use cases that together form a complete picture of what a cryptographically governed lending market looks like.

### The Four Priority Use Cases (Demo-Ready)

**1. AI Agent Credit — Borrow** (`CLAWLOAN_BORROW.md`)  
An AI agent borrows 500 USDC, pre-commits repayment via an Atlas Envelope in a single signing session, and goes offline. A keeper fires the repayment at deadline without any agent participation. ZK credit proofs upgrade the agent's tier after each successful cycle.  
*Proves:* Liveness-independent enforcement at the loan level. The lender's guarantee is cryptographic, not operational.

**2. Capital Provider — Lend** (`CLAWLOAN_LEND.md`)  
An institutional lender deposits 100,000 USDC, defines a precise risk policy (utilization guard, tier limits), and registers an Atlas Envelope that automatically pauses borrowing when utilization exceeds the threshold. No governance vote, no ops team, no single point of failure.  
*Proves:* Lender-side risk management is expressible as a pre-committed cryptographic policy. This is the primitive that enables institutional capital deployment into AI-agent lending pools.

**3. Borrow-to-Yield Self-Repaying Loan** (`SELF_REPAYING_LOAN.md`)  
An agent borrows USDC, pre-signs a 3-stage chain (ETH rally → harvest yield position → repay loan → rebuy WETH) in one session. When ETH hits the trigger price, the entire chain executes permissionlessly. The loan repays itself from yield proceeds without any agent involvement.  
*Proves:* Multi-stage strategy chaining using deterministic position salts. The same primitive that handles loan repayment handles a complete yield-funded carry trade.

**4. Bi-Directional Collateral Rotation** (`COLLATERAL_ROTATION.md`)  
An agent pre-commits a two-stage cycle: de-risk WETH → USDC when ETH drops, re-risk USDC → WETH when ETH recovers. Both stages are signed before the agent goes offline. The full rotation executes permissionlessly, with the strategy kept private as a hash commitment until each stage fires.  
*Proves:* Pre-committed multi-stage strategies with private conditions. The architecture that makes complex conditional automation safe — invisible to MEV until execution, liveness-independent throughout.

### What These Four Together Demonstrate

Taken as a sequence, the four use cases tell a single coherent story:

1. **The borrow use case** shows Atlas solving the liveness problem for individual loan repayment.
2. **The lend use case** shows Atlas solving the risk management problem for institutional capital providers.
3. **The self-repaying loan** shows Atlas extending into composable strategy: the same protocol that enforces a deadline also orchestrates a multi-stage yield harvest.
4. **The collateral rotation** shows Atlas as a general strategy primitive: not just loan enforcement, but autonomous bi-directional position management.

Together they demonstrate a two-sided market (borrowers + lenders) with composable strategy on top. This is the product.

### The Three Asks to ClawLoan

**Ask (a) — Feature experimentation:**  
Two interface changes in ClawLoan's pool contracts: (1) `repay()` callable from the Atlas kernel address (not only from the borrowing agent), enabling keeper-triggered repayment; (2) a `authorizedKeeper` mapping for `pauseBorrowing()`, allowing lenders to register the Atlas kernel as an approved pause executor.

**Ask (b) — Primitive development:**  
Three joint primitives: the `CreditVerifier` interface (ZK proof schema alignment between ClawLoan's credit scoring system and Atlas's circuit); the `UtilisationOracle` production interface (wrapping ClawLoan's real pool contract for use in the Atlas oracle registry); and a `repayFrom(positionCommitment)` hook enabling vault-to-loan repayment without an ERC-20 transfer step.

**Ask (c) — Investment signal:**  
The four use cases together constitute the strongest single demonstration of Atlas's value proposition. They show: a problem (liveness-dependent lending), the architectural fix (pre-committed enforcement), the extensions (risk policy, strategy composition), and the direction of growth (composable strategy graphs over a two-sided lending market).

---

### Phase 1 Demos — Built and Running (localhost)

Three scenarios are live on the local demo stack. Each proves something no existing system can prove.

**Demo 1 — AI Agent Credit (Clawloan)**
An AI agent borrows $500 unsecured from Clawloan, deposits $1,000 earnings, pre-authorizes repayment via an envelope, and goes offline. A keeper triggers the repayment permissionlessly at the loan deadline. The agent is not online for any part of execution. Credit tier upgrades via ZK compliance proof after each successful cycle.
*What this proves: liveness-independent enforcement, bounded key-compromise exposure, ZK credit loop.*

**Demo 2 — Dead Man's Switch**
A DAO treasury agent manages $2,000 USDC. It pre-commits: "if I stop checking in for 24 hours, transfer everything to the DAO multisig." The beneficiary is encoded in the EIP-712 intent hash at creation — it cannot be redirected by any attacker or keeper. Agent checks in periodically; if it goes dark, any keeper fires the switch.
*What this proves: reverse liveness enforcement (fires when agent stops), immutable beneficiary commitment, estate planning without trusted intermediaries.*

**Demo 3 — Sub-agent Fleet**
An orchestrator controls a $3,000 USDC budget across two sub-agents (Alpha: yield-farming, Beta: arbitrage), each with a $1,500 cap enforced by `MockSubAgentHub`. Each agent independently runs the full credit cycle. Orchestrator dashboard shows fleet P&L in real time.
*What this proves: hierarchical agent architecture with budget isolation, independent credit histories, application-layer constraint inheritance (Phase 1 of on-chain `parentCapabilityHash` enforcement).*

### Phase 2: Expand the Demo Surface (Months 4–10)

These are the demos that get written about. Each one proves something that no existing system can prove.

**Demo 4 — Price-triggered stop-loss / protective put:**
Agent deposits synthetic ETH. Registers envelope: "if ETH/USD < $1,800, sell all ETH for USDC." Oracle is pushed below $1,800 by the demo. A keeper triggers. ETH position converts to USDC automatically while the agent is offline. Shows Atlas as a trustless options settlement layer — no counterparty, no liquidity pool, no protocol-specific contract.
*What this proves: price-oracle-conditional execution, options thesis from EXTENSIONS.md, real use case for retail and institutions.*

**Demo 5 — Compromised key, constraint clamps (interactive):**
Publish an agent key on the test deployment. Let the audience attempt to drain it. Show every oversized intent rejected by the kernel in real time. The attacker holds the full key; they can drain at most one period's limit before revocation fires.
*What this proves: the invariant holds under full key compromise — the most important safety property.*

**Demo 6 — Cascading liquidation (multi-envelope staging):**
Three envelopes on the same position: sell 25% at $2,000, 25% at $1,800, 50% at $1,500. Each fires independently. Shows how sophisticated de-risking logic — usually implemented by custom contracts — is expressible as condition trees in the Atlas model.
*What this proves: multi-envelope strategy, staged de-risking, the "ETH < $2,000 AND vol > 80%" condition tree.*

Open the keeper network in this phase. Publish the keeper client. Incentivize first 10 keeper operators.

### Phase 3: Open Solver Market + Standardization (Months 10–18)

Open solver market. Publish the 7579 executor module and 7710 caveat enforcer bridge. Ship the conformance test suite. Wait for three independent implementations. Then file the ERC.

---

## Moats

Built in a specific order. Getting this wrong means building something copyable.

**Moat 1: SDK adoption (Months 1–6)**
Frameworks build around `createCapability()` and `createIntent()`. Switching means rebuilding agent logic, not swapping a library. First and most important moat.

**Moat 2: Envelope system + condition trees (Months 4–18)**
Envelopes require commitment-based positions for encumbrance. Account-based protocols cannot add this cleanly — the account model doesn't support discrete position locks. Any competitor implementing this from scratch needs a vault redesign, 6+ months, and a new audit.

The condition tree extension deepens this moat significantly. Every competitor that stores conditions publicly cannot add strategy privacy without redesigning custody. The commitment model (hash-then-reveal) is architecturally prerequisite. Competitors face a binary choice: stay with public conditions (their strategies are MEV-visible from day 1) or redesign custody entirely (18+ months, new audit, user migration). This is not a feature gap that a point release closes. It is an architectural gap that requires starting over.

**Moat 3: Audited adapter ecosystem (Months 6–18)**
Each adapter is weeks of work plus security review. The registry's track record of zero exploits is a trust signal that cannot be purchased — only earned.

**Moat 4: Aztec migration path (Months 18+)**
We are the only protocol with a direct path from public commitments to Aztec private notes using the same data model. Every competitor must redesign custody to add privacy. If Aztec delays, TEE-based privacy (Phala, Marlin) is the interim path using the same commitment model — competitors who redesign around account balances cannot take this shortcut.

**Moat 5: Data network effect (continuous, compounding)**
The protocol observes every intent, every rejected intent, every envelope trigger, every anomaly, every oracle staleness event. No other system has this dataset because no other system sits at the intersection of authorization, custody, and enforcement simultaneously.

This data powers:
- **Better constraint presets over time** — the "Conservative / Standard / Aggressive" presets improve as the protocol learns what constraint profiles correlate with safe outcomes vs. near-misses
- **Increasingly accurate anomaly detection** — agent behavior baselines are learned from real execution history; a new competitor starting from zero cannot replicate 12 months of behavioral signal
- **Agent safety oracle** (Phase 3+) — external protocols can query "has this agent key been associated with constraint violations, anomalous behavior, or revocation events" without revealing individual users. This is a new product built on protocol-native data.
- **Execution quality benchmarks** — slippage, MEV extraction, and oracle deviation data per adapter, per market condition. Solvers compete on metrics the protocol defines and owns.

Every transaction makes the dataset better. Competitors who don't sit at this execution layer cannot buy this signal — they'd have to bootstrap from scratch. This is the moat that compounds the longest.

**Moat 6: Protocol substrate for DeFi enforcement (Months 12+)**
Atlas envelopes are a general conditional execution primitive, not just a user-facing stop-loss product. External DeFi protocols have enforcement problems they currently solve by running their own keeper networks from scratch:

- **Aave** needs conditional liquidations when health factors breach thresholds
- **Uniswap** wants limit order execution without running its own keeper system
- **MakerDAO** needs CDP automation and stability fee collection
- **Lending protocols** need collateral top-ups and borrow limit enforcement

If Atlas becomes the shared envelope substrate that external protocols register conditional logic against, every integration adds to the keeper's economic incentive pool. More keeper rewards → more keeper operators → better reliability → more external protocol integrations → more keeper rewards. This is a flywheel that makes the keeper network more reliable than any single protocol could bootstrap alone.

The pitch to Aave: "Stop running your own keeper infrastructure. Register your liquidation conditions as Atlas envelopes. You get our keeper network; we get your trigger volume; keepers get more revenue. Everyone wins."

**What is not a moat:** The smart contract code. Open source, copyable in 2 months by a good team. The moat is adoption, execution history, and the keeper network's compound economics.

---

## Success Metrics: Operational Reality

These are the numbers we are accountable to, not the ones we aspire to.

**Developer experience:**
- Time-to-hello-world: < 20 minutes (npm install + 3 SDK calls)
- Time-to-production-integration: < 1 day (including key management, vault deposit, constraint configuration)
- SDK crash rate: < 0.1% of well-formed inputs

**Safety efficacy:**
- Intents rejected by capability constraints: tracked and published weekly (proves the system is working, not that it's failing)
- Estimated value protected: $ amount of intents blocked by period limits or adapter restrictions
- False positive rate: intents rejected that should have succeeded (target < 0.5%)

**Envelope reliability SLA:**
- p95 trigger latency post-condition: < 5 minutes
- Trigger success rate: > 99.5% (given oracle availability and sufficient keeper incentive)
- Keeper coverage: minimum 3 independent keeper operators monitoring all envelopes before open launch

**Execution quality:**
- Median slippage vs. Uniswap direct quote: < 30 bps
- Worst-case slippage at p99: < 100 bps
- Solver fee effective rate: < 0.15% all-in (protocol fee + solver fee)

**Revocation UX:**
- Revocation finality: 1 transaction (< 2 seconds on Base)
- Time from revocation to solver rejection of compromised-key intents: < 5 seconds (solver monitors revocation events)
- Emergency withdrawal latency from vault pause to user fund recovery: < 60 seconds (one transaction)

---

## The Roadmap as a Series of Bets

### Bet 1: Capability delegation beats session keys (Months 1–4)
**Success:** 3 integrations, at least 1 documented constraint-blocked incident.
**Fail signal:** Developers find capability model too complex; prefer session keys despite risks.
**Fallback:** Ship a "simplified mode" with one constraint type; expand later.

### Bet 2: Liveness-independent enforcement is a real user need (Months 4–10)
**Success:** 100+ active envelopes, at least 1 triggered correctly in a live volatile market event.
**Fail signal:** Users don't use envelopes; keeper adoption too low for reliable coverage.
**Fallback:** Manual keeper triggers; reframe envelopes as "backup execution" rather than primary.

### Bet 3: Solver market bootstraps (Months 10–18)
**Success:** 3+ independent solvers, competitive pricing, no single-solver dependency.
**Fail signal:** No third-party solvers 12 months in.
**Fallback:** White-label solver infrastructure to third parties; solver-as-a-service model.

### Bet 4: Aztec reaches production (Months 18–24)
**Success:** Proof latency < 1 second, fees < $0.50, mainnet stable.
**Fail signal:** Aztec delays again; proof costs prohibitive.
**Fallback:** TEE-based privacy (Phala, Marlin) as interim solution. Full Aztec deferred.

### Bet 5: Advanced primitives unlock institutional adoption (Months 18–30)
Dead man's switches, M-of-N consensus intents, and ZK compliance proofs are the three features that convert institutional interest into institutional commitment. The thesis: by the time a crypto hedge fund has seen Atlas's Phase 1–2 track record, they need exactly these primitives to justify deploying $10M+ of automated strategy capital. If we have them and competitors don't, the sales cycle for Customer 3 shortens from 18 months to 3.
**Success:** 2+ institutional integrations requiring M-of-N consensus or ZK compliance proofs.
**Fail signal:** Institutions adopt Atlas for Phase 1–2 features only; advanced primitives go unused.
**Fallback:** Simplify — M-of-N as a 2-of-2 "dual agent confirmation" feature; ZK compliance as an optional SDK module rather than a protocol-level primitive.

---

## Revenue

Revenue must not compromise protocol adoption. Sequenced accordingly.

**Phase 1 (0–12 months): Execution fee, 0.05% of gross output.**
Proves economic value creation. Not the business model — the data point.

**Phase 2 (6–18 months): Solver fee share, 10% of solver revenue.**
Protocol takes 10% of whatever solvers earn. Revenue grows with solver success, not extracted from users. Aligns incentives correctly.

**Phase 2.5 (8–18 months): Envelope protection fee, 2–5 bps of encumbered position size at registration.**
A stop-loss that fires correctly and protects $50,000 from a 40% drop created $20,000 of user value. The execution fee captured $25. This is a structural misalignment: the protocol's most valuable guarantee (liveness-independent enforcement) is priced at zero, while the least differentiating service (execution routing) earns a fee.

The envelope protection fee corrects this. At envelope registration, the protocol earns 2–5 bps of the encumbered position value. A $50,000 stop-loss envelope costs $10–25 to register. This is:
- Aligned: protocol revenue is proportional to value protected, not just executed
- Recurring: users re-register envelopes as market conditions change
- Anti-spam: makes spam envelope registration costly (complements the encumbrance requirement)
- TVL-correlated independently of execution frequency: dormant envelopes still generate revenue

At $10M TVL in active envelopes (conservative for Phase 2), 3 bps protection fee = $30,000 revenue per re-registration cycle. This scales without requiring high execution volume.

**Phase 3 (12–24 months): Enterprise private vault licensing, $50k–$200k/year.**
Private vaults, audit trails, custom SLA, dedicated infrastructure. First revenue stream uncorrelated with DeFi volume.

**Phase 4 (18–36 months): Protocol substrate fee, per envelope trigger from external DeFi integrations.**
External protocols (Aave, Uniswap limit orders, MakerDAO automation) pay a fee per keeper trigger executed through the Atlas envelope system. Structurally similar to a SaaS API call fee — low per-unit, high volume at scale. This revenue stream is entirely uncorrelated to Atlas's own TVL.

**Phase 5 (24+ months): Cross-chain coordination fee.**
Per-confirmation fee on the global nullifier coordinator when multi-chain executes. Structurally similar to bridge fees.

**Non-negotiable:** Zero fee on capability creation, envelope registration, or revocation. The authorization layer is free. Revenue comes from execution.

---

## The 10-Year Picture

In 10 years, AI agent transaction volume exceeds human-initiated transaction volume on-chain. Humans set preferences. Agents execute. The capability token is as fundamental as the ERC-20 approval is today — except it is structured, bounded, auditable, and revocable in ways that approvals never were.

The envelope system — extended to boolean condition trees — generalizes from stop-losses to the complete space of expressible pre-committed strategies. Not just "sell when price drops" but: volatility-aware de-risking, cross-asset relative value rotations, protocol health monitoring exits, time-gated DCA, correlation-break detection, and any strategy an LLM agent can express as a condition tree. All firing permissionlessly. All private until the moment of execution. An LLM agent describes a strategy in natural language; the SDK compiles it to a condition tree; the vault commits to the hash; the keeper network executes it. The full loop from "user intent" to "on-chain execution" requires no human online at execution time and no centralized service that can be shut down.

The private vault becomes the default for any position that should not be publicly visible: hedge funds, protocol treasuries, high-frequency systems, personal privacy. The same commitment model that runs today on public EVM runs on Aztec with private notes and ZK proofs. No redesign.

The protocol is the operating system layer for AI agent finance. Not because of lock-in — because we built the right primitive at the right time and the ecosystem compounded on top of it.

**The substrate expansion:** In year 3–5, Atlas stops being only a user-facing protocol. Every DeFi protocol with conditional execution logic — liquidations, limit orders, auto-compounders, stability mechanisms — runs on the Atlas envelope substrate instead of maintaining their own keeper infrastructure. The Atlas keeper network, made economically dense by compound trigger volume from dozens of protocols, achieves reliability levels that no single protocol could bootstrap. The protocol earns a fee on every envelope trigger regardless of which application registered it. This is the Stripe model: infrastructure so reliable that building your own version is economically irrational.

In year 5–10, the capability token format becomes the standard for any bounded authorization — not just DeFi agents, but enterprise AI systems, DAO governance execution, insurance settlement automation, and any system where "prove what you were authorized to do" has compliance value. The ERC we author in year 1 is the authorization primitive for a much larger category than DeFi.

This is an infrastructure play. The analog is not a better DEX. The immediate analog is TCP/IP for agent authorization. The long-horizon analog is the protocol layer beneath any system that needs provable, bounded, time-scoped authority.

---

## Advanced Primitives: What Makes This the Reference Design

The five primitives below are not on the immediate roadmap. They are on the roadmap because they are the correct answer to questions that sophisticated agents and institutions will inevitably ask. Each one extends the existing architecture without redesigning it. Each one doesn't exist anywhere in the ecosystem today.

---

### Primitive 1: Dead Man's Switch Envelopes

**The idea:** Every existing envelope fires when a condition *becomes* true. A dead man's switch fires when a condition *stops being maintained*.

"If this agent has not submitted a valid intent in 72 hours, trigger an emergency sell of all positions."
"If my recovery address hasn't received a heartbeat transaction in 30 days, transfer my vault commitment to it."
"If the primary keeper stops updating this feed within 6 hours, cancel all pending envelopes and return positions to direct user control."

**Why it matters:** The current model assumes the agent goes offline during an event. Dead man's switches handle the case where the agent goes offline for an unknown reason — and nothing has happened yet, which is exactly when the safety net should trigger. This enables:
- On-chain estate planning without trusted intermediaries
- Mandatory agent liveness monitoring with automatic fallback
- Organizational continuity (if the protocol's keeper goes offline for too long, trigger a sovereign exit)
- Emergency position recovery with no human intermediary required

**How it works technically:** An inverse envelope has a `heartbeatInterval` and a `lastHeartbeat` field. The agent (or any authorized address) sends a keepalive transaction to the registry at regular intervals. Any keeper can trigger the dead man's envelope by proving `block.timestamp - lastHeartbeat > heartbeatInterval`. The same execution pipeline fires. The design requires a single additional registry state field — it is a minimal extension of the existing envelope primitive.

**What it enables that nothing else can:** A fully autonomous position management system where the protocol itself guarantees recovery even if every piece of infrastructure — the agent, the operator, the keeper, the protocol team — goes offline simultaneously. This is the self-sovereign finance primitive.

---

### Primitive 2: M-of-N Multi-Agent Consensus for Execution

**The idea:** An intent that requires M valid capability signatures from an approved set of N agent keys before the kernel will execute it. Not multi-sig for custody — multi-sig for *decisions*.

A $500,000 rebalancing intent that requires 3 of 5 independent risk-evaluation agents to sign off. Each agent has its own capability with its own constraint profile. No single agent — compromised, hallucinating, or adversarially steered — can unilaterally execute.

**Why it matters:** This is the architecture that institutional AI trading desks actually need. A human risk committee is replaced by an AI risk committee where no single agent has unilateral authority. The trust model changes from "trust this one agent" to "trust that at least M of N independent agents reached the same conclusion."

The adversarial resilience is multiplicative: to force a bad execution, an attacker must compromise or manipulate M independent AI systems simultaneously. Each system has its own model, its own context, its own signing key. Correlated failure across M systems is orders of magnitude harder than compromising one.

**How it works technically:** The `Intent` struct gains a `consensusPolicy` field: `{requiredSigners: M, approvedSignerSet: bytes32 (merkle root of approved agent keys)}`. The kernel accumulates signatures in an off-chain bundle. When M valid signatures from the approved set are present, execution proceeds. Each signer's capability is verified independently — the most restrictive constraints across all signing capabilities apply. The on-chain verification is a set of M ECDSA recoveries plus a merkle inclusion proof per signer.

**What this unlocks:** A new class of AI agent system — distributed AI risk committees — that have never been buildable because the execution layer has always required a single authorizing key. This is a primitive that hedge funds, DAOs, and protocol treasuries will pay for.

---

### Primitive 3: Conditional Capability Activation

**The idea:** A capability that is only active when an external condition holds. Not "agent on" or "agent off" — "agent authorized within a specific regime."

"This agent's $10,000/day limit activates only during high-volatility periods (implied vol > threshold)."
"This emergency sell capability only becomes executable after the primary agent has been silent for 48 hours."
"This sub-capability upgrades from $500/day to $5,000/day after the agent has executed 100 constraint-compliant trades."

**Why it matters:** Real automated systems are not binary. They have operating regimes. A yield optimizer should behave differently in a risk-off environment than a trending market. An emergency bot should not be executable until an emergency is actually happening. Conditional activation makes the capability itself regime-aware — the authorization is as smart as the constraints it enforces.

**How it works technically:** The `Capability` struct gains an optional `activationCondition` field, identical in structure to an envelope's `Conditions`. At kernel execution time, if the capability has an activation condition, the kernel performs the same oracle check it would for an envelope trigger. If the condition is not met, the capability is treated as if it were expired — not revoked, but inactive until conditions change. No new state required in the kernel — the oracle check path is already implemented for envelopes.

**The compounding effect:** Combined with dead man's switches and M-of-N consensus, conditional capability activation enables a full "agent operating policy" expressed as a single authorized object: "Agent is allowed to trade up to $1k/day during normal conditions; up to $10k/day with 3-of-5 risk agent consensus during high-volatility; emergency sell triggers automatically if the agent is silent for 48 hours." This is an autonomous finance policy, not just a permission.

---

### Primitive 4: Composable Boolean Envelope Conditions — The Category Shift

**The insight that changes everything: the commitment model is what makes this safe.**

Every existing conditional execution system stores conditions publicly at registration time. Aave's liquidation parameters are on-chain. Uniswap limit orders reveal the price target when posted. Chainlink Automation stores the check function publicly. This means any registered strategy is immediately visible to MEV bots, competitors, and front-runners from the moment it is created.

Atlas stores a hash. The condition tree is committed as `conditionsHash = keccak256(merkle_root(condition_tree))`. The actual conditions — the strategy logic — are known only to the agent and encrypted inside the commitment. At trigger time, the keeper reveals only the minimal satisfying path through the tree. The revelation is atomic with execution. There is no window between "conditions known" and "trade executed."

**This is the architectural property that makes complex condition trees safe. You cannot build this on account-based systems. The commitment model has to be foundational from the start.**

---

**What this does to the product category:**

Single-condition envelopes: Atlas is a stop-loss protocol. The market for this is meaningful but narrow — power users who want automated risk management.

Boolean condition trees: Atlas is a permissionless strategy execution engine. The market is every autonomous DeFi agent, every institutional trading system, every protocol that wants conditional automation without running its own keeper infrastructure.

The shift is not marginal. It is the difference between "we do stop-losses" and "we are the execution layer for any pre-committed autonomous strategy that any system — human-configured or LLM-generated — can express."

---

**The full condition taxonomy — what leaf nodes can express:**

```
PriceCondition     → oracle.price() compared to threshold (existing)
TimeCondition      → block.timestamp compared to threshold
VolatilityCondition → realized vol oracle compared to threshold
VolumeCondition    → 24h on-chain volume compared to threshold
CrossAssetCondition → ratio of two oracle prices (ETH/BTC) compared to threshold
PortfolioCondition  → sum of user's vault position values compared to threshold
OnChainStateCondition → any contract view function return value compared to threshold
```

The last one is the most powerful. `OnChainStateCondition` takes a target contract, a view function selector, and a comparison. "Trigger when Aave's ETH utilization rate > 90%." "Trigger when Uniswap V3 ETH/USDC pool fee tier 0.05% has less than $5M TVL." "Trigger when Compound V3 USDC APY < 3%." Any on-chain readable state becomes a trigger condition. An LLM agent that can read chain state can generate condition trees that respond to any observable market event.

---

**Strategy patterns the condition tree enables:**

**Pattern 1: Volatility-aware stop-loss**
```
OR(
  AND(price < $1800, realizedVol_24h > 80%),   // panic regime: tight stop
  price < $1500                                  // floor: unconditional
)
```
Don't trigger on normal volatility-driven dips. Only trigger if the combination of price AND elevated vol suggests a regime change. This eliminates false stop-out in choppy markets while still providing a hard floor.

**Pattern 2: Cascading liquidation (staged de-risking)**
Three separate envelopes, each encumbering 25% of the position:
```
Envelope 1: price < $2000 → sell 25%
Envelope 2: price < $1800 → sell 25%
Envelope 3: price < $1500 → sell remaining 50%
```
Each envelope fires independently when its condition is met. Total position de-risking happens in stages, not all at once. This is how sophisticated risk managers actually operate — no existing automated system implements this natively.

**Pattern 3: Cross-asset momentum**
```
AND(
  ETH_price / BTC_price < 0.025,    // ETH underperforming BTC
  BTC_price > $60000                 // BTC still strong (not systemic crash)
)
```
Rotate ETH → BTC only when ETH is specifically underperforming in a BTC bull market — not during general market drawdowns. This is relative-value logic that no simple price trigger can express.

**Pattern 4: Protocol health monitoring**
```
OR(
  AND(Aave_ETH_utilization > 95%, Aave_ETH_APY > 15%),  // borrow rate spike
  Compound_USDC_TVL < $100M                               // protocol TVL collapse
)
```
Exit a yield position when the underlying protocol shows signs of stress. Currently impossible to automate without a centralized monitoring service. With `OnChainStateCondition`, this fires permissionlessly from on-chain state alone.

**Pattern 5: Time-gated DCA (Dollar Cost Averaging)**
```
AND(
  block.timestamp mod 604800 < 3600,  // within first hour of each week
  ETH_price < 7-day TWAP              // only buy when below weekly average
)
```
Weekly DCA that only executes when price is below the 7-day average — not a fixed-date buy, but a value-conscious DCA. The time condition and price condition combine in a single envelope.

**Pattern 6: Correlation break detection**
```
AND(
  BTC_price > $60000,          // BTC still elevated
  ETH_price < $2000,            // ETH has decoupled downward
  realized_correlation_30d < 0.5  // correlation oracle confirms decoupling
)
```
Detect when ETH breaks from BTC correlation during a BTC bull run — a historically reliable signal for ETH underperformance. No existing stop-loss system can express multi-asset correlation logic.

---

**How an LLM agent generates condition trees:**

The SDK provides `sdk.buildConditionTree(description: string)`. An LLM agent receives natural language strategy instructions from a user and outputs a `ConditionTree` object that the SDK validates, serializes, and registers as an envelope.

```typescript
// User: "Sell my ETH if it drops below $1800 during high volatility,
//        or if it drops below $1500 regardless"
const tree = await sdk.buildConditionTree(`
  sell ETH if
    (ETH/USD < 1800 AND realized_vol_24h > 80%)
    OR (ETH/USD < 1500)
`);

const envelope = await sdk.createEnvelope({
  positionCommitment: ethPosition.hash,
  conditionTree: tree,      // committed as conditionsHash = keccak256(tree.root)
  triggerIntent: sellIntent,
  expiry: Date.now() / 1000 + 90 * 86400,
  keeperRewardBps: 50,
});
```

The LLM does not need to know the smart contract implementation. It outputs natural language conditions; the SDK validates them against the oracle registry (only whitelisted oracles can be referenced in leaf conditions); the resulting tree is committed as a hash. The agent's strategy is private until execution.

**This is the correct interface for AI agents to express strategy.** Not "sign this specific swap intent" but "pre-commit to this strategy, and the protocol will execute it correctly regardless of whether I'm online."

---

**The strategy as a portable, auditable object:**

A condition tree + intent sequence is a completely deterministic strategy specification. Given the tree and the on-chain state at any historical timestamp, you can verify exactly when the strategy would have triggered and what it would have executed.

This makes strategies:
- **Backtestable**: the SDK simulation layer (`sdk.simulate(conditionTree, historyDays: 180)`) runs the tree against historical oracle data and shows: when would this have triggered, what would the outcome have been
- **Auditable**: the conditions hash, once revealed post-execution, is a cryptographic proof of exactly what logic was running — not what the agent claims was running
- **Composable**: an output commitment from Strategy A (position in USDC after ETH sell) can be the input commitment for Strategy B (USDC yield position with its own exit conditions)
- **Transferable**: the condition tree is an off-chain object that can be shared, duplicated, or licensed to another user who applies it to their own positions with their own agent key

The strategy layer is the product that retail and institutional users will interact with. The commitment model is the infrastructure that makes it trustworthy. Nobody else can provide both.

---

**Why no existing system can build this:**

| System | Stores conditions | Reveals conditions | Safe complex trees |
|---|---|---|---|
| Chainlink Automation | Publicly on registration | Always public | Possible but strategy is public from day 1 |
| Gelato Network | Publicly on registration | Always public | Possible but strategy is public |
| Uniswap limit orders | Publicly on registration | Always public | Single price condition only |
| Aave liquidations | Hardcoded in protocol | N/A | Protocol-defined only, not user-customizable |
| **Atlas** | **Hash-committed** | **Minimal path revealed at trigger** | **Full boolean tree, strategy private until execution** |

The competition can add more condition types. They cannot add privacy without redesigning custody from scratch. The commitment model is the prerequisite, and it is architecturally incompatible with account-based systems where balances are public by definition.

**This is the moat: not the condition types themselves, but the architecture that makes complex private conditions safe. That architecture requires the commitment model. The commitment model requires redesigning custody. Nobody will redesign custody to add this feature — they would have to ship a new protocol.**

---

### Primitive 5: ZK Proof of Constraint Compliance

**The idea:** An agent with N executed intents can generate a ZK proof that all intents were within its capability constraints, without revealing any individual trade.

The proof attests: "I have executed N intents. All were within constraint bounds. My constraint violation rate is 0%. No individual trade details are revealed."

**Why it matters:** This is the trust primitive that institutional adoption requires — and that no existing system can provide. An institution evaluating whether to grant a $1M/day capability wants proof of the agent's compliance history. Today the options are: (a) reveal every trade (unacceptable for a competitive trading operation) or (b) trust the agent operator's word (unacceptable for any serious risk management framework).

A ZK compliance proof is a portable trust credential. It proves trustworthiness without enabling surveillance. It travels with the agent key across protocols. It can be required as a precondition for high-limit capability grants. An insurance or bonding market can price agent risk against it. This is the "agent credit score" that preserves privacy.

**How it works technically:** The circuit takes as private inputs: the set of intent preimages and their corresponding execution receipts. It takes as public inputs: the capability constraints hash, the number of intents N, and a nullifier set root. It proves: for all N intents, `amountIn ≤ maxSpendPerPeriod`, `amountOut/amountIn ≥ minReturnBps`, `adapter ∈ allowedAdapters`. The proof is constant-size regardless of N. The nullifier set root is verifiable against on-chain state — the prover cannot cherry-pick a favorable subset.

**The ecosystem effect:** Once this credential exists, it becomes the standard way agents establish reputation without sacrificing privacy. Every protocol that grants agent capabilities will ask for it. Atlas, as the system that generates the underlying execution receipts, becomes the trust anchor for the entire agent economy.

---

### Primitive 6 (Phase 4+): Intent Pipelines

A signed sequence of conditional intents that execute as a chain: "sell ETH → hold USDC in vault → rebuy when ETH recovers 10% → repeat for 90 days." Each step's output commitment is the next step's authorized input. The full strategy is a single signed authorization object. Multi-step strategies become liveness-independent — no agent needs to be online for step 2 because step 1's output already pre-authorized it.

### Primitive 7 (Phase 4+): Protocol-Native Circuit Breakers

If an agent triggers N anomaly events within a time window — unusual frequency, unusual size, unusual slippage pattern — the capability auto-suspends for a configurable cool-down period. Not "each intent is bounded" but "behavioral patterns that exceed historical norms are flagged and paused before the period limit is reached." Pattern-level risk management as a protocol guarantee, not just an application-layer monitoring feature.

---

## What We Explicitly Do Not Do

**We do not build a consumer app.** The agent, the chat interface, the portfolio dashboard — someone else's product. We build what they run on. Consumer competition means losing to better-funded teams with better distribution.

**We do not compete with DEXes.** We are an authorization and enforcement layer. Adapters route through DEXes. We do not internalize execution.

**We do not build a general smart account.** ERC-4337 exists. The moment we add gas abstraction, social recovery, and arbitrary module execution, we're competing with MetaMask on their turf. We stay in the agent authorization lane.

**We do not move slowly.** The contracts are done. Phase 1 is an SDK and developer relations problem. Speed matters more than polish. Ship, break, fix.

---

## The Single Slide

The AI agent economy needs an authorization and enforcement layer. Every current solution conflates the agent with the account — the wrong primitive for the wrong threat model. We build the correct primitives: stateless agents with cryptographic capability delegation, commitment-based custody, and liveness-independent enforcement. The invariant: no agent signature can move more value than the capability bounds, even under full key compromise. We have 12–18 months to become the standard before distribution locks in the wrong answer. Phase 1: SDK + 3 framework integrations + $1M TVL. Phase 2: envelopes + the three demos that prove what no existing system can prove. Everything else follows.
