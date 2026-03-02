# Atlas Protocol — Extensions
## Five Primitives That Expand the Category
**Internal document — February 2026**

---

## Why This Document Exists

The core protocol (STRATEGY.md) establishes Atlas as the enforcement and execution layer for AI agent finance. The advanced primitives (STRATEGY.md §Advanced Primitives) extend that foundation with dead man's switches, M-of-N consensus, ZK compliance proofs, and composable condition trees.

This document goes one level further. The five extensions described here are not incremental improvements to existing features. Each one is a category shift — a reframe of what Atlas is and which markets it addresses. Some of them make Atlas a different kind of protocol than it currently presents itself to be. That is intentional.

These are Phase 3–5 directions. None require redesigning the core protocol. All are natural extensions of the commitment model, the condition tree, and the keeper network. They are documented here so they can be designed into Phase 1–2 architecture decisions that would otherwise foreclose them.

---

## Extension 1: Atlas Is Already an Options Protocol

### The Insight

An options contract is: the right to buy or sell an asset at a specific price, under specific conditions, that settles automatically and unconditionally when the condition is met.

That is a condition tree envelope.

The condition tree is the strike structure. The keeper network is the exercise mechanism. The vault is the settlement layer. The `minReturn` guarantee is the execution assurance. The commitment model ensures the strategy is private until settlement.

Atlas does not need to build an options protocol. It already is one. The primitives were designed for agent authorization and ended up being a complete options settlement infrastructure. This is not marketing — it is a precise architectural observation.

### The Mapping

| Options concept | Atlas primitive |
|---|---|
| Strike price | `PriceLeaf` threshold |
| Expiry | `envelope.expiry` |
| Exercise (automatic) | Keeper triggers when condition met |
| Settlement | `minReturn` floor + vault commitment |
| Put (right to sell) | Envelope: `price < strike → sell` |
| Call (right to buy) | Envelope: `price > strike → buy` |
| Collar (sell below, buy above) | Two envelopes on split positions |
| Straddle (trade on large move) | `OR(price < low, price > high)` condition tree |
| Barrier option (activates conditionally) | Conditional capability + envelope |
| Asian option (averaged price) | TWAP leaf condition |
| Binary option | Any condition tree, boolean outcome |
| Digital option | Any condition tree + fixed-size output intent |

### Why This Is Better Than Existing On-Chain Options

Existing on-chain options (Lyra, Hegic, Dopex, Opyn) require:
- A counterparty or liquidity pool to take the other side
- An oracle at settlement time (single point of manipulation risk)
- Protocol-specific logic for each options structure
- Liquidity that must be incentivized and maintained
- Fee structures that extract value from both sides

Atlas envelopes require none of this. There is no counterparty. The user pre-commits their own assets as collateral in the vault. The condition tree defines the exercise logic. The keeper network handles settlement. There is no protocol-specific options logic — just the general-purpose condition tree.

**This means Atlas can settle options on any asset with an oracle feed, in any structure expressible as a condition tree, with no liquidity pool, no counterparty risk, and no protocol-specific smart contract for each options type.** The long tail of assets that no existing options protocol supports — because there isn't enough liquidity to make a market — becomes addressable immediately.

### Synthetic Derivatives That Become Possible

**Protective put:** User deposits 1 ETH. Registers envelope: `ETH < $1,800 → sell all ETH for USDC`. This is economically equivalent to buying a put option at $1,800 strike. No premium paid upfront (the cost is the keeper reward + opportunity cost of encumbrance). No counterparty.

**Covered call:** User deposits 1 ETH. Registers envelope: `ETH > $2,800 → sell ETH for USDC`. Synthetic covered call. If ETH reaches $2,800, the position converts automatically.

**Collar:** Split position into two. Envelope 1: `ETH < $1,600 → sell`. Envelope 2: `ETH > $2,800 → sell`. Bounded exposure between $1,600 and $2,800 — the classic collar structure.

**Straddle:** Two envelopes on split positions. Envelope 1: `ETH < $1,600`. Envelope 2: `ETH > $2,800`. Profits on large moves in either direction.

**Barrier option:** Conditional capability that only activates when BTC dominance > 60%, combined with an ETH/BTC ratio envelope. Option only "exists" in a specific macro regime.

**DCA call ladder:** Five envelopes, each buying an equal USDC position at successively lower ETH prices ($2,400, $2,200, $2,000, $1,800, $1,600). Executes a cost-averaged accumulation strategy automatically.

### What This Does to the Market Opportunity

The on-chain options market in 2025 was ~$2B in open interest, concentrated on ETH and BTC, constrained to assets with deep liquidity. Atlas's addressable market is every asset with a reliable oracle feed — which is thousands of assets — with no liquidity bootstrap requirement and no counterparty model.

The correct competitor framing shifts from "we're better than session keys for AI agents" to "we're a trustless options settlement layer that happens to also be the best authorization infrastructure for AI agents." These are not competing narratives — they attract different capital and different users to the same protocol.

---

## Extension 2: Chained Envelopes — Full Autonomous Strategy Graphs

### The Problem with Terminal Envelopes

Every current envelope is terminal: it fires once, the position converts, the envelope is spent. The user's agent must be online to register the next envelope if the strategy has multiple stages.

This defeats much of the liveness-independence guarantee. A cascade strategy — sell ETH, hold USDC, deploy to Aave yield, exit yield when APY drops — requires the agent to be online at each stage transition to register the next envelope.

### The Solution: Pre-Committed Strategy Graphs

An envelope with a `nextEnvelope` field pre-commits what should happen to the output position when this envelope fires. The keeper who triggers the parent envelope also atomically registers the child envelope in the same transaction, using the output commitment as the new encumbered position.

```
Strategy graph example:

Envelope A:  [ETH position]
  condition: ETH < $2,000
  intent:    sell ETH → USDC
  next:      Envelope B (pre-committed hash)

Envelope B:  [USDC position — created when A fires]
  condition: USDC idle for 7 days (time leaf)
  intent:    deploy USDC to Aave yield
  next:      Envelope C (pre-committed hash)

Envelope C:  [Aave position — created when B fires]
  condition: OR(Aave APY < 3%, health_factor < 1.3)
  intent:    withdraw from Aave, buy back ETH
  next:      Envelope A (recycles — creates new ETH position)
```

The user pre-commits this entire graph while online. They go offline. The strategy runs itself, stage by stage, indefinitely — unless manually cancelled.

### What Strategy Graphs Enable

**Full portfolio management automation:** A complete investment policy — entry, management, exit, reentry — expressed as a directed graph of envelopes. The user's preferences are expressed once. The protocol executes them forever.

**Self-rebalancing portfolios:** Envelope A: "if ETH weight > 60%, sell ETH to USDC." Envelope B: "if ETH weight < 30%, buy ETH with USDC." Both envelopes point to each other as `next` — but `next` is only registered if the envelope fires. The strategy self-maintains.

**Yield optimization with automatic migration:** Deploy to highest-yield protocol. If yield drops below threshold, withdraw and register an envelope to redeploy to the next best option. The "next best option" is determined by an `OnChainStateLeaf` comparing APYs at trigger time.

**Recursive DCA:** Buy $500 of ETH every week (time leaf), automatically re-register the same envelope for the next week. The DCA runs until the user cancels or the capability expires.

**Crisis response chains:** "If ETH drops 20% in 24 hours (sustained condition), execute the full defensive sequence: sell alts, buy stables, deploy to safe yield, wait 30 days before redeploying." One pre-committed graph handles the entire response sequence.

### Safety Properties

**Cycle depth limit:** Strategy graphs have a maximum chain depth (configurable per graph, bounded by protocol maximum of 16 hops). This prevents infinite regress and bounds keeper gas costs.

**Cycle detection at registration:** The registry detects if a proposed graph would create an unbounded cycle and rejects it if the cycle has no exit condition.

**User cancellation at any stage:** Cancelling any envelope in the chain also cancels all pre-committed descendants. The user maintains full control — they can exit the strategy at any stage with a single cancellation transaction.

**Capital accounting:** Each stage in the chain operates on exactly the output commitment of the previous stage. No capital can be created or lost across stage transitions — the vault's solvency invariant holds at every step.

---

## Extension 3: Manipulation-Resistant Execution

### The Attack Vector

Every condition tree leaf currently reads a spot oracle price at the moment of trigger. A sufficiently funded attacker can:

1. Manipulate the oracle (briefly) within a single block to cross the trigger price
2. Front-run the trigger with the attack transaction
3. Fire the envelope
4. Profit from the resulting forced sale at an adversarial price

For small positions, this attack is unprofitable — manipulation costs exceed gains. For large positions ($1M+), it becomes economically viable. Any institutional user will ask about this before depositing.

Two independent mitigations, both necessary for large-position safety:

### Mitigation A: TWAP Leaf Conditions

Instead of `spot_price < threshold`, require `twap(window) < threshold`. A time-weighted average price requires sustained price movement, not a single-block manipulation.

```
TWAP of 15 minutes: requires manipulation to persist across ~75 blocks on Base
TWAP of 1 hour:     requires manipulation to persist across ~300 blocks
TWAP of 24 hours:   flash manipulation is entirely infeasible
```

The TWAP window creates a cost-of-attack floor. A 15-minute TWAP window means an attacker must maintain oracle manipulation for 15 minutes — at which point natural arbitrage forces have corrected the price, making manipulation self-defeating.

For large positions (> $100k): enforce minimum TWAP window of 15 minutes at the SDK level as a default constraint. Users can override this for smaller positions where responsiveness is more valuable than manipulation resistance.

### Mitigation B: N-Block Confirmation

A two-phase trigger mechanism. When a keeper first observes the condition becoming true, they submit a `conditionEntered` transaction (not the trigger — just a record). The trigger transaction cannot be submitted until N blocks have passed since `conditionEntered`.

N-block confirmation is additive with TWAP leaves: a strategy can require both a TWAP condition AND 10 consecutive blocks of confirmation. This makes single-block oracle manipulation entirely ineffective and requires sustained (multi-minute, multi-block) market movement before execution.

The keeper who submits `conditionEntered` earns a small monitoring fee (a fixed amount from the keeper reward pool). The keeper who submits the actual trigger after N blocks earns the main reward. This splits the keeper incentive into two roles — monitoring and execution — which can be fulfilled by different keepers and increases decentralization of the keeper network.

### Economic Analysis

| Attack scenario | Single-condition spot | TWAP 15min | TWAP 15min + 10 blocks |
|---|---|---|---|
| Flash manipulation (1 block) | Vulnerable | Safe | Safe |
| Sustained manipulation (< 5min) | Vulnerable | Safe | Safe |
| Sustained manipulation (15min) | Vulnerable | Vulnerable | Safe |
| Genuine market movement | Executes correctly | Slight delay | Slight delay |
| Large whale price impact | Partially vulnerable | Safe | Safe |

The cost in responsiveness: TWAP and N-block confirmation add latency. For stop-loss protection, this is the correct tradeoff — a 15-minute window is acceptable for exits that are triggered by genuine market regime changes, not flash events. For time-sensitive DCA, use spot leaves. The user configures the tradeoff per envelope.

---

## Extension 4: Strategy NFT Marketplace

### The Economic Primitive

A condition tree + intent sequence is completely deterministic. Given the tree and any historical oracle data, you can compute exactly when it would have triggered, what would have executed, and what the outcome would have been. This is not true of any other financial strategy format — a Python trading bot depends on the execution environment; a TradingView alert depends on platform uptime; a smart contract strategy is protocol-specific.

A condition tree is portable, backtestable, auditable, and chain-agnostic. It is the first financial strategy format that is truly transferable.

This creates a new market: strategies as assets.

### How the Marketplace Works

**Strategy creation:** An alpha researcher designs a condition tree strategy. They test it against historical data using the SDK simulation layer. They mint it as an ERC-1155 token with the condition tree hash as the token URI. They set a license fee: N basis points of execution value, or a flat fee per application.

**Strategy application:** Another user browses the marketplace. They see the strategy's: condition tree structure (revealed post-mint), historical backtest results, live execution statistics (how many envelopes have fired, fill rates, outcomes), creator reputation (on-chain track record). They pay the license fee to "apply" the strategy — the SDK instantiates the condition tree for their own position with their own agent key and their own vault commitment. The strategy creator earns the fee.

**Revenue sharing:** Every time an envelope fires using a licensed strategy, a fraction of the keeper reward is routed to the strategy creator. The protocol takes a cut of licensing fees (10%). This creates a three-way incentive: users want better strategies, creators want more executions, the protocol wants both.

**Strategy reputation:** The marketplace displays for each strategy: total envelopes created, total triggers, fill rate within target time, average realized slippage vs. intent floor, creator's compliance proof. These are verifiable on-chain statistics — not claims, not backtests, but actual execution history. This is the trust layer that makes the marketplace credible.

### What This Changes About the Protocol

Without the marketplace: Atlas is infrastructure. Developers integrate it. Users configure it manually. Growth is developer-dependent.

With the marketplace: Atlas is a platform. Strategy creators have economic incentive to design and publicize their best work. Users can adopt sophisticated strategies without understanding the underlying primitives. Growth compounds through the strategy layer — better strategies attract more users, more users generate more execution data, more data validates more strategies.

The data network effect moat becomes a marketplace flywheel: execution data → strategy validation → marketplace credibility → more users → more execution data.

### Strategy Categories That Emerge

**Risk management:** Stop-loss strategies at various sophistication levels. Volatility-aware exits. Cross-asset correlation monitors. Protocol health exits.

**Yield optimization:** Deploy to highest available yield. Migrate on yield drop. Compound automatically. Rebalance across yield sources.

**DCA and accumulation:** Value-averaged DCA. Price-ladder accumulation. Dip-buying strategies with confirmation requirements.

**Relative value:** ETH/BTC rotation strategies. DeFi sector rotation. Stablecoin yield arbitrage.

**Macro regime strategies:** Bull/bear market positioning based on on-chain indicators. Risk-on/risk-off based on BTC dominance. Volatility-targeting strategies.

Each category generates specialists who compete on quality. The protocol earns on every execution regardless of which strategy wins. This is the App Store model applied to DeFi strategy.

---

## Extension 5: Sustained Conditions — From Events to Regimes

### Why Spot Conditions Are Insufficient for Strategy

Most DeFi price action is noise. An asset can touch $1,800 briefly in a single block and recover immediately. A spot price condition envelope would fire on that touch, executing a sell at exactly the worst moment in a brief dip. This is the fundamental problem with event-based automation: markets have noise, and noise is indistinguishable from signal at a single point in time.

Professional trading systems solve this with regime detection: not "is the condition true right now" but "has the condition been true continuously for long enough to represent a structural state change, not transient noise."

### The Sustained Condition Primitive

A `SustainedLeaf` wraps any other leaf type and requires the inner condition to have been continuously true for a minimum duration before the envelope can fire.

```
SustainedLeaf:
  inner:               any leaf condition
  minimumDurationSecs: minimum continuous duration
```

"ETH has been below $1,800 for 2 continuous hours" is structurally different from "ETH briefly touched $1,800." The first indicates a regime. The second is noise. Only the first should trigger a protective sell.

### Strategy Patterns Unlocked

**Trend confirmation:** "Buy only if ETH has been trending above its 24h TWAP for 6 consecutive hours." Prevents buying the brief recovery spike in a continued downtrend.

**Protocol stress monitoring:** "Exit Aave yield if utilization has been above 90% for more than 30 minutes." The protocol is under genuine stress, not a transient borrow spike that will self-correct.

**Drawdown confirmation:** "Exit if portfolio value has been below high-water mark - 20% for more than 24 hours." Distinguishes a structural drawdown from an intraday dip.

**Opportunity validation:** "Deploy to yield only after APY has been above 12% for 3 consecutive days." Confirms the rate is sustainable before deploying capital.

**Volatility regime entry:** "Activate the high-volatility strategy only after realized vol has been above 80% for 4 continuous hours." Prevents false regime entry on a single volatility spike.

### Two-Phase Keeper Economics

Sustained conditions require two keeper interactions:

**Phase 1 — Monitoring transaction:** Keeper observes the inner condition becoming true and submits `conditionEntered(envelopeHash, timestamp)`. This is stored in the registry and earns a small monitoring fee.

**Phase 2 — Trigger transaction:** After `minimumDurationSecs` has elapsed, any keeper can submit the trigger. If the inner condition became false at any point during the window, the `conditionEntered` is reset — the keeper must start over with a new Phase 1.

This splits keeper work into two economically incentivized roles. Phase 1 keepers earn small fees for monitoring; Phase 2 keepers earn the main reward. Both roles can be run by different operators, increasing keeper decentralization.

**Interruption handling:** If the condition becomes false during the minimum duration window (noise), the `conditionEntered` timestamp is cleared. The Phase 1 monitoring fee is still paid — the keeper correctly identified the condition entering, which is valuable information. The strategy simply requires a new, uninterrupted duration.

---

## How All Five Compose

These extensions are not independent features — they form a coherent system when combined.

**The professional DeFi strategy stack:**

```
User describes strategy in natural language
  → LLM compiles to condition tree (Boolean conditions with TWAP leaves)
    → Strategy NFT minted (licensed to user)
      → Condition tree committed as envelope hash
        → Envelope chain pre-committed (full strategy graph)
          → Sustained condition monitoring begins
            → Keeper network enforces
              → Execution settles with minReturn guarantee
                → Next envelope in chain auto-registered
```

Every layer is handled by Atlas. The user's role is to describe what they want and approve the strategy. The protocol handles everything else.

**The synthetic options use case:**

A structured product desk (DeFi-native or institutional) designs a collar strategy as a condition tree. They mint it as a Strategy NFT with TWAP leaves (manipulation resistance) and sustained conditions (regime confirmation). Users apply the strategy to their ETH positions. The desk earns licensing fees. The protocol earns on execution. Users get institutional-grade options logic without an options protocol.

**The institutional use case:**

A hedge fund pre-commits a complete portfolio management policy as a strategy graph. Each node in the graph uses sustained conditions to prevent noise-triggered transitions. The entire policy is ZK-attested (compliance proof). The fund's risk committee approves the policy using M-of-N consensus. The strategy runs permissionlessly for the fund's target holding period. The compliance team can audit every execution against the pre-committed policy hash.

---

## Roadmap Integration

| Extension | Prerequisite | Phase | Complexity |
|---|---|---|---|
| Manipulation resistance (TWAP + N-block) | Phase 2 envelopes | Phase 2.5 | Low — additive leaf type + two-phase trigger |
| Sustained conditions | Phase 2 envelopes | Phase 3 | Medium — two-phase trigger, interruption handling |
| Strategy NFT marketplace | Condition trees + execution data | Phase 3 | Medium — ERC-1155 + fee routing |
| Chained envelopes | Phase 2 envelopes | Phase 3 | Medium — `nextEnvelope` field + recursive registration |
| Synthetic options narrative | All condition tree features | Phase 3+ | Zero — narrative reframe, no new code |

**Manipulation resistance belongs in Phase 2.** It is not optional for large-position safety and should be available at envelope launch. TWAP leaves and N-block confirmation are additive to the existing condition structure.

**Everything else is Phase 3.** The strategy NFT marketplace, chained envelopes, and sustained conditions all require the Phase 2 envelope system to be live and generating execution data before they are worth building.

**The synthetic options narrative requires nothing new.** It is a reframing of what already exists. This can be communicated as soon as the condition tree is live.

---

## Revenue Implications

Each extension adds a distinct revenue stream:

| Extension | Revenue mechanism |
|---|---|
| Manipulation resistance | None (safety feature — zero-fee) |
| Sustained conditions | Monitoring fee split (small, but keeper-incentivizing) |
| Strategy NFT marketplace | 10% of licensing fees + execution fees on licensed strategies |
| Chained envelopes | Per-hop registration fee (small, paid to registering keeper) |
| Synthetic options narrative | No new revenue — but expands TAM dramatically |

The strategy NFT marketplace is the most significant. It creates recurring revenue from strategy licensing that is entirely independent of DeFi volume, entirely independent of TVL, and grows with the quality of the strategy creator ecosystem. A successful strategy with 1,000 active subscribers, executing 2 envelopes per month each at $10,000 average size, at 2 bps license fee = $400/month for the creator, $40/month to the protocol per strategy. Scale to 100 strategies and the licensing revenue is meaningful, non-cyclical, and compounding.

---

## The Category Reframe

The current Atlas narrative: "authorization and enforcement layer for AI agent finance."

After these extensions: "the permissionless settlement infrastructure for any pre-committed autonomous financial strategy — from simple stop-losses to complex multi-stage synthetic options strategies, expressed in natural language, compiled by AI, kept private until execution, and enforced by a permissionless keeper network."

These are not competing narratives. The first is the Phase 1–2 story. The second is the Phase 3–5 story. Building Phase 1–2 correctly — with the commitment model, the vault, and the condition tree foundation — is what makes Phase 3–5 possible. This is why the architecture decisions in Phase 1 matter so much: they either foreclose or enable everything in this document.
