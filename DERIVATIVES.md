# Atlas as the Universal Derivatives Settlement Layer
## From Options to Every Financial Contract That Depends on Conditions
**Internal document — February 2026**

---

## The Generalization

`OPTIONS_EXPLAINER.md` established that condition tree envelopes map precisely onto options payoff structures. The two-party vault commitment mechanism produces trustless options with hard price guarantees. Both results follow from two primitives: the vault commitment and the condition tree.

The same two primitives, combined differently, produce the complete landscape of financial derivatives — and several categories of financial contract that have never been expressible on-chain at all.

This document maps that landscape.

---

## The Primitive Combination That Enables Everything

Every derivative contract reduces to the same structure:

1. **Two (or more) parties commit assets to a shared execution context.** Neither can withdraw unilaterally. Both are locked in.
2. **A condition tree defines when and how the committed assets are redistributed.** The condition can be a price, a timestamp, a protocol state, a cross-asset ratio, a volatility measure, or any boolean combination.
3. **The keeper network enforces settlement.** Execution is automatic, permissionless, and liveness-independent.

Step 1 is the vault commitment. Step 2 is the condition tree. Step 3 is the keeper network. Together they form a general-purpose bilateral settlement infrastructure. Every derivative is a configuration of these three components.

---

## Perpetual Futures with Automated Funding Payments

### What perpetuals are
A perpetual futures contract is a bilateral bet on asset price with no expiry. The long profits when price rises; the short profits when price falls. A funding rate mechanism periodically transfers payments between the long and the short to keep the perpetual price tethered to spot.

### Why they don't exist trustlessly on-chain today
Every existing perpetual protocol — GMX, dYdX, Hyperliquid — uses a centralized or semi-centralized price oracle, a liquidation engine, and a protocol-owned liquidity pool that absorbs imbalanced open interest. The oracle, the liquidation engine, and the pool are each trusted components that can fail, be manipulated, or extract value.

### How Atlas does it

**Party A (long):** Commits 1 ETH to the vault.
**Party B (short):** Commits 1,800 USDC to the vault.

**Funding rate envelopes** — registered as a chain of time-leaf envelopes, one per funding interval (e.g., every 8 hours):
```
condition:  timestamp = next funding interval
intent:     read current funding rate from oracle
            if perpetual price > spot: transfer funding from long to short
            if perpetual price < spot: transfer funding from short to long
next:       register next funding envelope (8 hours later)
```

**Settlement envelope:**
```
condition:  either party signals exit OR health factor < threshold
intent:     calculate PnL from entry price vs. current oracle price
            deliver net proceeds to each party
```

The protocol is the liquidation engine — the health factor condition fires automatically when the losing party's committed collateral is insufficient to cover PnL. There is no trusted liquidation bot. There is no pool absorbing open interest. Two parties, fully collateralized, settled by condition.

**What this enables:** Perpetual exposure on any asset with an oracle feed. No protocol pool required. No centralized oracle administrator. The first genuinely trustless perpetual infrastructure.

---

## Interest Rate Swaps

### What they are
The largest derivatives market in traditional finance: ~$500 trillion notional outstanding. Party A pays a fixed rate; Party B pays a floating rate tied to a benchmark. Periodically the two payments net against each other — the party paying more transfers the difference to the other.

### Why they don't exist trustlessly on-chain
On-chain lending protocols (Aave, Compound, Morpho) produce floating rate exposure naturally — borrow rates change continuously. But there is no mechanism to lock in a fixed rate against a floating rate counterparty without a trusted intermediary managing the ongoing settlement.

### How Atlas does it

**Party A (fixed rate payer):** Commits 10,000 USDC to the vault as fixed-rate leg collateral.
**Party B (floating rate payer):** Commits 10,000 USDC to the vault as floating-rate leg collateral.

**Settlement envelope chain** — fires every 30 days for 12 months:
```
condition:  timestamp = settlement date
intent:     read current Aave USDC borrow rate from on-chain state leaf
            calculate fixed payment = principal × fixed_rate / 12
            calculate floating payment = principal × aave_rate / 12
            transfer net difference from higher-paying party to lower-paying party
next:       register next settlement envelope (30 days later)
```

**Final settlement:** After 12 months, committed collateral is released to each party.

**What this enables:** Any institution, protocol, or individual with floating-rate exposure (e.g., a Aave borrower) can lock in a fixed rate against any counterparty willing to take the other side. No bank intermediary. No swap dealer. No ISDA master agreement. The entire $500 trillion interest rate swap market's settlement function, executed by the vault.

---

## Protocol Insurance and Credit Default Protection

### What CDS are
A credit default swap pays out if a specified entity defaults or a specified event occurs. Party A pays a periodic premium; Party B posts collateral and pays out if the credit event occurs.

### The DeFi version: protocol hack insurance
The largest uninsured risk in DeFi is protocol exploits. Hundreds of millions of dollars have been lost to smart contract hacks with zero recovery mechanism. Existing on-chain insurance (Nexus Mutual, InsurAce) uses governance-based claims processes — slow, subjective, and gameable.

### How Atlas does it

**Protection buyer:** Commits their Aave deposit receipt (or a USDC premium payment) to the vault.
**Protection writer:** Commits 50,000 USDC collateral to the vault. Receives the periodic premium.

**The trigger condition:**
```
condition:  OnChainStateLeaf reading Aave total deposits
            fires if: Aave_deposits < (Aave_deposits_at_inception × 0.5)
            — i.e., if Aave loses more than 50% of deposits in a short window
```

**Settlement:**
```
if condition fires:
  deliver 50,000 USDC to protection buyer
  writer absorbs the loss

if policy expires without firing:
  return writer's collateral
  writer keeps all premium payments
```

**What makes this different from existing on-chain insurance:**
- No claims process. No governance vote on whether the hack "counts." The on-chain state leaf is the arbiter — if the protocol's deposit balance drops catastrophically, the payout is automatic and immediate.
- No trust in the insurance protocol. The writer's collateral is in the vault before the policy exists. The payout cannot be delayed, denied, or gated behind a governance vote.
- Parametric, not indemnity. The payout triggers on the observable on-chain event, not on the subjective assessment of loss. Fast, clean, unchallengeable.

**Extensions:** Cross-protocol insurance (protect Aave AND Compound position with a single policy), protocol depeg insurance (USDC depeg oracle), bridge hack insurance (bridge balance oracle).

---

## Trustless Employment and Vesting

### The problem
Compensation agreements between employers and employees — or protocols and contributors — require trust in the paying party. Vesting schedules are administered by centralized contracts whose administrators can be changed. Salary agreements have no enforcement mechanism beyond legal recourse.

### How Atlas does it

**The employer** commits the full 12-month salary (e.g., 120,000 USDC) to the vault at the start of employment. The entire annual compensation is locked and irrevocable.

**A chain of time-leaf envelopes** delivers 10,000 USDC per month:
```
Envelope 1:  condition: timestamp = February 28
             intent:    deliver 10,000 USDC to employee_address
             next:      Envelope 2

Envelope 2:  condition: timestamp = March 31
             intent:    deliver 10,000 USDC to employee_address
             next:      Envelope 3

... (12 envelopes total)
```

**What the employee knows before starting work:** The full 120,000 USDC exists in the vault. It is irrevocably committed to the delivery schedule. The employer cannot "forget" to pay, run out of funds, or restructure the agreement. Every payment fires automatically on the committed date regardless of whether the employer remains solvent, attentive, or cooperative.

**For token vesting:** Four-year vesting with a one-year cliff becomes a condition tree:
```
condition: timestamp > cliff_date AND (timestamp - cliff_date) / total_period
intent:    deliver pro-rata tokens to beneficiary_address
```

The entire vesting schedule is committed at grant time. The beneficiary can verify the full token commitment exists before relying on the grant.

**What this changes:** Trustless employment is a mass-market use case with zero DeFi-specific user acquisition cost. Every freelancer, contractor, grantee, and protocol contributor with a compensation agreement is a potential user. The protocol earns a fee on every delivery envelope. The employer's reputational benefit is that they can prove, verifiably and publicly, that they have fully funded every commitment.

---

## Outcome-Based Grants and Retroactive Public Goods Funding

### The problem
DAO grants and public goods funding suffer from two failure modes: the committee allocates capital but the grantee doesn't deliver (waste), or the grantee delivers but the committee doesn't pay (injustice). Both require trust in a human decision-making layer.

### How Atlas does it

**The grant committee** commits the grant amount to the vault at the time of award. The USDC is irrevocable — the committee cannot claw it back.

**The release condition** is an on-chain state leaf:
```
condition:  OnChainStateLeaf reading protocol metric
            e.g., protocol_TVL > 10_000_000 USDC
                  OR num_transactions > 1_000_000
                  OR grantee_contract deployed and verified
expiry:     12 months — if condition not met, return to committee
```

**If condition is met:** vault delivers grant to grantee automatically.
**If expiry passes without condition:** vault returns to committee automatically.

**What this changes:** The grantee knows at award time that the money exists and will deliver automatically if they succeed. No committee approval needed at delivery time. No relationship maintenance. No political risk. The protocol (outcome oracle) is the judge, not humans.

**For retroactive public goods funding:** The condition is an oracle that measures real-world impact — GitHub commits merged, users onboarded, protocol TVL achieved. The payout is retroactive: work first, verify impact on-chain, receive payment automatically.

---

## Sovereign and DAO Treasury Management with Constitutional Rules

### The problem
Protocol treasuries are managed by multisig or governance — both of which are either too centralized (multisig) or too slow (governance) for operational financial management. There are no enforceable constitutional rules on treasury behavior — the rules exist in documentation but are enforced by social consensus alone.

### How Atlas does it

A DAO issues a treasury management capability with hard constraints encoded at the protocol level:

```
Capability constraints:
  maxSpendPerTransaction:     1% of treasury value
  maxSpendPer24Hours:         3% of treasury value
  minReturnBps:               9900 (max 1% slippage)
  allowedAdapters:            [Aave, Uniswap V3, Curve]
  requiresConsensus:          3 of 5 treasury agents
  emergencyExitAlways:        true (unilateral exit to stable always permitted)
```

Every treasury action must satisfy these constraints. The kernel enforces them. No governance vote can override them without revoking and reissuing the capability. The constraints are the constitutional rules of the treasury, and they are enforced by code.

**An additional envelope layer:**

A rebalancing envelope fires when portfolio weights deviate beyond thresholds:
```
condition:  ETH_weight > 65% OR ETH_weight < 35%
intent:     rebalance to 50% ETH / 30% stables / 20% DeFi
```

A circuit breaker envelope fires on drawdown:
```
condition:  portfolio_value < (inception_value × 0.7)
intent:     convert all non-stable positions to USDC
            suspend all non-emergency capabilities
```

**What this changes:** The DAO's financial behavior is provably rule-bound. Any stakeholder can verify the capability constraints. Any auditor can verify compliance from the on-chain execution receipts. Any investor or partner can assess treasury risk from first-principles rather than trust.

The protocol earns fees on every treasury execution. The DAO earns a reputational benefit: provably safe, provably compliant, provably non-discretionary treasury management.

---

## Protocol Revenue Distribution

### The problem
Protocol revenue distribution to token holders requires a trusted administrator to collect fees, calculate shares, and distribute. The administrator can make errors, delay distributions, or introduce discretion into what should be a mechanical process.

### How Atlas does it

**The protocol** commits all fee revenue to a vault distribution envelope chain.

**A time-leaf envelope** fires at the end of every epoch (e.g., weekly):
```
condition:  timestamp = end of epoch
intent:     read total fees collected this epoch from OnChainStateLeaf
            calculate per-token share
            distribute to all registered token holders proportionally
next:       register next distribution envelope
```

Token holders register once to receive distributions. Every subsequent distribution fires automatically. The distribution calculation is on-chain and auditable. There is no administrator with discretion over timing or amount.

**Extensions:** Fee-share NFTs that represent the right to receive protocol revenue for a specific period. The NFT is an ERC-1155 token; the distribution envelope delivers to the current holder of the NFT. Protocol revenue share becomes a tradeable, liquid asset.

---

## Cross-Chain Atomic Settlement

### The problem
Cross-chain swaps require either a bridge (trusted intermediary, single point of failure) or an atomic swap protocol (complex, illiquid, requires both chains to be online simultaneously). Neither scales well for bilateral financial agreements across chains.

### How Atlas does it

**Party A on Base:** Commits 1 ETH to an Atlas vault, locked pending the cross-chain proof.
**Party B on Arbitrum:** Commits 1,800 USDC to an Atlas vault on Arbitrum (or a future Atlas Arbitrum deployment).

**The condition** on Base reads a cross-chain oracle (LayerZero, Chainlink CCIP) that verifies the Arbitrum vault commitment exists:
```
condition:  CrossChainStateLeaf confirms Party B's vault commitment on Arbitrum
            AND timestamp < expiry
intent:     deliver 1 ETH to Party B's Base address
            (simultaneously, Arbitrum envelope delivers 1,800 USDC to Party A's Arbitrum address)
```

**What this enables:** Bilateral financial agreements across chains — forwards, options, swaps — where both parties can trust that the other side has committed before their own side executes. No bridge. No third-party relay. The cross-chain oracle is the only trusted component, and dual-oracle design (LayerZero + CCIP) makes even that robust.

---

## Volatility Products

### What they are
Volatility swaps and variance swaps pay out based on realized volatility, not directional price movement. Party A pays a fixed volatility strike; Party B pays realized volatility. If realized volatility exceeds the strike, Party B pays Party A the difference. Used by institutions to hedge or speculate on volatility regime changes.

### How Atlas does it

The volatility leaf condition already exists in the condition tree spec. A volatility swap extends it:

**Party A (volatility buyer):** Commits 5,000 USDC to the vault.
**Party B (volatility seller):** Commits 5,000 USDC to the vault.

**Settlement envelope:**
```
condition:  timestamp = settlement date
intent:     read 30-day realized volatility from VolatilityLeaf oracle
            calculate: payout = notional × (realized_vol - strike_vol)
            deliver net payout to appropriate party
```

**What this enables:** The first trustless on-chain volatility product. Institutions can hedge portfolio volatility (not just directional risk) without a broker. Protocols can hedge governance volatility (token price swings that affect treasury). Any two parties with opposing views on whether markets will be calm or turbulent can express and settle that view trustlessly.

---

## Prediction Markets Without a Protocol

### What they are
Bilateral bets on observable outcomes — sports results, election outcomes, economic data releases, or any event captured by an oracle.

### How Atlas does it

**Party A:** Commits 1,000 USDC (betting YES).
**Party B:** Commits 1,000 USDC (betting NO).

**Settlement envelope:**
```
condition:  OnChainStateLeaf reads outcome oracle at resolution time
            if oracle returns TRUE: deliver 2,000 USDC to Party A
            if oracle returns FALSE: deliver 2,000 USDC to Party B
expiry:     if oracle fails to resolve: return 1,000 USDC to each party
```

**What this enables:** Any two parties can create a trustless prediction market with no protocol overhead, no liquidity pool, no fee structure beyond the keeper reward. The oracle is the only infrastructure required. This extends naturally: sports books, political prediction markets, economic data bets, protocol milestone bets ("will Uniswap V4 reach $1B TVL by Q4?") — all settable on Atlas.

---

## Assurance Contracts (Collective Action Without a Platform)

### What they are
A funding mechanism where each contributor's payment only executes if a group threshold is reached by a deadline. If the threshold is not met, every commitment is automatically returned. Known in mechanism design as the "dominant assurance contract" — the Nash equilibrium is to contribute, because the only risk is your money sitting in a vault for a few weeks.

### Why they don't exist trustlessly today
Kickstarter, Indiegogo, and DAO grant platforms all require trusting the platform to hold funds, apply the threshold logic correctly, and process refunds honestly. The platform charges 5–8% and is a point of failure.

### How Atlas does it
```
N parties each commit X USDC to vault commitments

Success envelope:
  condition:  count(commitments) >= threshold AND timestamp < deadline
  intent:     deliver all committed USDC to builder_address

Refund envelopes (one per committer):
  condition:  timestamp >= deadline AND count(commitments) < threshold
  intent:     return X USDC to committer_address
```

Each committer can verify on-chain that the threshold logic is correct before committing. Once committed, their money cannot be redirected. The builder cannot receive funds unless the threshold is met. Refunds are automatic. No platform. No fees beyond the keeper reward.

**What this changes:** Public goods funding, open-source development, research grants, DAO proposals — any collective action problem with a funding threshold. The commitment is the coordination mechanism: once you can see 80 of 100 commitments in the vault, contributing your share is rational. The vault makes the coordination credible.

---

## Commitment Savings Devices

### The behavioral economics insight
Pre-commitment dramatically improves savings outcomes. People who cannot easily access savings save more. The problem: every existing savings lock (bank CDs, locked savings accounts) is reversible with enough effort or penalty negotiation. The commitment has no genuine teeth.

### How Atlas does it
```
User commits 10,000 USDC to vault

Standard release envelope:
  condition:  timestamp = 12 months from now
  intent:     return 10,000 USDC to user_address

Early withdrawal envelope:
  condition:  user requests early release (signed message)
  intent:     deliver 9,000 USDC to user_address
              deliver 1,000 USDC to charity_address (or burn)
```

The penalty is cryptographically enforced. The user cannot negotiate with the vault. The lock is genuinely irreversible without paying the penalty. The user can set the penalty amount themselves at commitment time — the higher they set it, the stronger the commitment device they are creating for themselves.

**Extensions:** Savings goals (release only when balance reaches target), group savings (commitment releases when all group members hit their targets), employer match (employer commits matching funds contingent on employee saving commitment). The first genuinely enforceable commitment savings infrastructure.

---

## Trustless Bug Bounties

### The problem
Security researchers routinely find critical vulnerabilities and choose not to disclose them because the paying organization might dispute, delay, or underpay. The bounty commitment is not credible before the work is done.

### How Atlas does it
```
Protocol commits 500,000 USDC to vault

Payout envelope:
  condition:  OnChainStateLeaf: exploit_verifier_contract.verify(submission) == true
  intent:     deliver 500,000 USDC to submission.submitter_address

Return envelope:
  condition:  timestamp > 2 years AND no valid submission
  intent:     return 500,000 USDC to protocol_treasury
```

The exploit verifier contract is a deployed, audited smart contract that validates proof-of-concept submissions against specified criteria. If the submission is valid, the payout is automatic and immediate. The 500,000 USDC is visible in the vault before the researcher begins their work. The commitment is credible before a single line of audit code is written.

**What this changes:** The economics of security research shift fundamentally. Researchers can verify the bounty exists, verify the verifier logic, and invest accordingly. Protocols get better security because researchers engage with confidence. The bug bounty becomes as trustless as the protocol it protects.

---

## Streaming Payments with Condition Gates

### The problem
Superfluid-style streaming pays continuously as time passes. But many service relationships are conditional on the service actually being performed — "pay me while the server is running" not "pay me while time passes." Time-based streaming cannot express this.

### How Atlas does it
```
Condition:  OnChainStateLeaf: api_oracle.status(endpoint) == 200
            AND timestamp within active_period
Intent:     stream 0.1 USDC per minute to service_provider_address
            pause if condition fails for > 5 consecutive minutes
            resume automatically when condition returns true
```

An oracle pings the service endpoint periodically. Payment flows while the service is up. Payment pauses automatically when it is down. No human intervention, no dispute, no invoice.

**Extensions:**
- Pay contributors while commits are being merged (GitHub oracle)
- Pay validators while blocks are being produced (on-chain state leaf)
- Pay oracles while data is being reported (oracle activity leaf)
- Pay LPs while positions are being maintained (position health oracle)
- Pay auditors per line of code reviewed (verifier contract)

Any ongoing service relationship where payment should be conditional on continuous performance becomes expressible as a condition-gated stream.

---

## Self-Funding Autonomous Strategies

### The insight
Every envelope requires a keeper reward to execute. Long-running strategies — DCA, yield optimization, LP management — require an ongoing budget. Currently this must be topped up manually, creating a human dependency.

### How Atlas does it
```
Strategy earns yield from an Aave position (e.g., 5% APY on $100k)
A distribution envelope routes 10% of yield to a keeper_rewards_vault
Each strategy envelope's keeper reward draws from that vault
```

The strategy earns approximately $5,000/year. $500 goes to keeper rewards. The strategy executes roughly 500 transactions per year ($1 each). The strategy funds its own execution from its own returns. Once deployed, no human needs to interact with it.

**What this enables:** Strategies that are genuinely autonomous — not "automated software running on a server someone maintains," but autonomous in the strict sense: the strategy has the economic resources to persist and execute indefinitely without external input. It runs as long as the underlying position generates enough yield to fund execution. Deploy once. Walk away.

---

## Conditional Property Transfer

### The insight
Real estate transactions require an escrow agent to hold funds while title, inspection, and financing conditions are verified. The escrow agent charges fees, can make errors, and is a trusted intermediary for a mechanical process.

### How Atlas does it
```
Buyer commits 500,000 USDC to vault
Seller commits tokenized deed to vault

Completion envelope:
  condition:  AND(
                title_oracle confirms clean title,
                inspection_oracle returns PASS,
                timestamp < closing_date
              )
  intent:     deliver 500,000 USDC to seller_address
              deliver tokenized deed to buyer_address

Failure envelope:
  condition:  timestamp >= closing_date AND completion not triggered
  intent:     return 500,000 USDC to buyer_address
              return tokenized deed to seller_address
```

The escrow agent is replaced by a condition tree. The oracles provide objective, verifiable data — not a human judgment call. If conditions are met, settlement is atomic and immediate. If the deal falls through, both parties are made whole automatically.

**Extensions:** Any tokenized real-world asset — commercial real estate, vehicles, IP licenses, domain names, art — can be transferred conditionally using the same primitive. The escrow industry processes trillions of dollars per year enforcing a three-component structure.

---

## The Meta-Primitive: Programmable Credible Commitment

This is the deepest thing the envelope unlocks.

In economics and game theory, **credible commitment** is one of the most powerful strategic tools available. When a party can credibly commit to future behavior — verifiably and irreversibly — it changes the behavior of every other party who interacts with them.

Classic credible commitment problems:
- A central bank commits to an inflation target — but could always abandon it
- A founder commits to a vesting schedule — but could always restructure it
- A DAO commits to fee distribution rules — but could always vote to change them
- A protocol commits to a buyback floor — but could always cancel it under pressure

Every existing commitment mechanism has failure modes: legal contracts can be disputed, institutional reputation can degrade, social norms can shift. None is genuinely irreversible.

**The vault commitment + condition tree is the first mechanism that makes commitment cryptographically irreversible.** Once committed, the assets are locked. Once the condition tree is defined, the execution logic cannot be changed. The committing party cannot renegotiate, buy time, or apply pressure.

This means any party using Atlas can manufacture credibility that was previously impossible:
- A protocol credibly commits to fee distribution rules that no governance vote can override
- A founder credibly commits to a vesting schedule that cannot be restructured regardless of leverage
- A DAO credibly commits to grant delivery that cannot be clawed back after work is done
- A treasury credibly commits to buyback floors that execute automatically regardless of market conditions

**The value of a credible commitment is not the commitment itself — it is the behavioral change it produces in every counterparty.** A protocol that cannot change its fee structure changes how LPs price their liquidity. A founder with a locked vesting schedule changes how investors assess alignment. A DAO that cannot claw back grants changes how contributors engage.

Atlas does not just settle financial contracts. It manufactures credibility. And credibility, in every domain of human coordination, is one of the scarcest and most valuable resources there is.

---

## The Landscape

Every contract in this document shares the same three-component structure: vault commitment, condition tree, keeper settlement. The difference between an options contract, a forward contract, an interest rate swap, a CDS, and a prediction market is only which conditions and which asset redistribution logic is specified.

| Contract type | Condition | Settlement logic | New infrastructure needed |
|---|---|---|---|
| Put option | Price < strike at expiry | Deliver strike USDC to buyer | None |
| Forward contract | Timestamp = settlement date | Atomic asset swap | None |
| Interest rate swap | Timestamp = each settlement date | Net floating vs. fixed | On-chain rate oracle |
| CDS / protocol insurance | Protocol state anomaly | Deliver collateral to buyer | On-chain state oracle |
| Perpetual future | Funding interval + health factor | Funding transfers + PnL settlement | Funding rate oracle |
| Volatility swap | Timestamp = settlement date | Net realized vs. strike vol | Volatility oracle |
| Employment / vesting | Timestamp = payment date | Deliver salary / tokens | None |
| Outcome-based grant | On-chain metric threshold | Deliver grant or return to committee | Metric oracle |
| Prediction market | Outcome oracle resolution | Winner-take-all delivery | Outcome oracle |
| Revenue distribution | Timestamp = epoch end | Pro-rata delivery to holders | Fee accumulation oracle |
| Cross-chain settlement | Cross-chain state confirmation | Atomic bilateral delivery | Cross-chain oracle |

The infrastructure requirements in the rightmost column reduce to: oracles. Every oracle that Atlas integrates unlocks a new class of financial contract that can be settled trustlessly through the vault.

---

## The 10-Year Framing

In traditional finance, derivatives settlement requires:
- Central counterparties (CCPs) — to enforce contracts and manage default
- Clearing houses — to net obligations and manage margin
- Settlement banks — to actually move the money
- Legal contracts (ISDA agreements) — to define what happens in edge cases
- Regulators — to monitor systemic risk

This infrastructure costs the global financial system hundreds of billions of dollars per year in fees and capital requirements. It also introduces systemic risk — the CCPs and clearing houses are themselves concentration points that can fail.

Atlas replaces all of it with:
- Vault commitments — no counterparty default
- Condition trees — no legal ambiguity about what fires when
- Keeper network — no settlement bank
- On-chain execution receipts — no regulator needed for auditability
- Protocol-level anomaly detection — no systemic risk concentration

This is not a feature comparison. It is a restatement of what the derivatives settlement infrastructure exists to do, expressed in Atlas primitives. The protocol does not need to compete with any of these institutions. It makes them irrelevant for any bilateral contract whose trigger condition is observable on-chain.

The oracle is the remaining bottleneck. As oracle coverage expands to cover real-world events — financial data, physical world conditions, regulatory filings, election outcomes — the set of contracts expressible through Atlas expands correspondingly. Every new reliable oracle feed is a new category of trustless contract settlement.

---

---

## Strategic Question: Stateless Agents and Broad Coordination — Focus on Both?

This is the most important question raised by this document. The answer requires being precise about what is shared and what is distinct.

---

### The Architecture Has Two Distinct Layers

**Layer 1: Core Settlement Infrastructure**
- Vault (irrevocable commitment)
- Condition tree (trigger logic)
- Keeper network (permissionless execution)
- Adapters (execution against DeFi protocols)

This layer is what enables every contract in this document. It makes no assumption about AI agents. It applies equally to bilateral options, employment contracts, assurance contracts, and bug bounties. It is general-purpose conditional settlement infrastructure.

**Layer 2: Agent Authorization**
- Capability tokens (scoped, bounded authority)
- CapabilityKernel (constraint enforcement)
- Sub-capabilities (delegation chains)
- ZK compliance proofs (portable trust credentials)
- Agent key management and rotation

This layer sits on top of Layer 1 and is specific to the AI agent use case. It answers: "how do we let an AI agent act on behalf of a user within hard boundaries?" It requires Layer 1 to function but Layer 1 does not require it.

---

### What Stateless Agents Enable Across Both

The stateless agent model — agents as signing keys + capability tokens, no on-chain presence between actions — applies everywhere a non-human actor needs to manage or interact with committed positions.

| Broad coordination use case | Where agents are relevant |
|---|---|
| Options / bilateral contracts | An agent manages the portfolio that includes options positions; capability limits what it can do with them |
| Employment / vesting | An agent manages the recipient's portfolio; capability prevents it from extracting the vested tokens inappropriately |
| Protocol insurance | An AI agent managing a DeFi portfolio automatically purchases insurance coverage as part of risk management |
| Treasury management | An AI agent executes rebalancing and yield optimization within capability constraints |
| Interest rate swaps | An AI treasury agent manages the swap leg as part of overall interest rate risk management |
| Assurance contracts | An AI agent can participate as a contributor, verifier, or campaign manager with capability-constrained authority |
| Bug bounties | An AI agent running automated security analysis submits findings with capability-constrained authority |
| Prediction markets | An AI agent manages a prediction market portfolio within constrained position limits |

The stateless agent architecture does not conflict with any use case in this document. In every case, a human or institution might want an AI agent to manage their side of a bilateral contract — and that agent needs to be capability-constrained, auditable, and revocable. Layer 2 serves that need on top of Layer 1.

---

### Should We Focus on Both?

**The honest answer: build one, get both.**

The AI agent use case is the V1 product. It is specific, timely, and fundable. The narrative is clear: AI agents are taking autonomous financial actions and there is no infrastructure for doing this safely. Atlas is that infrastructure. This is the wedge that justifies the engineering investment in Layer 1 and Layer 2.

The broad coordination use cases are not a second product. They are what Layer 1 becomes when you remove the agent-specific assumptions and let anyone use the vault + condition tree + keeper as a general settlement layer. You build Layer 1 for agents and discover it serves everyone.

**The risk of pursuing both explicitly from day one:**
Trying to sell "AI agent authorization AND derivatives settlement AND employment contracts AND public goods funding" to investors and early users creates positioning confusion. You are everything to everyone, which means you have no clear wedge, no clear early adopter, and no clear narrative momentum.

**The right sequencing:**

- **Phase 1 (now):** Atlas is the authorization and execution layer for AI agents. This is the entire public narrative. Every engineering decision is justified by this use case. This is what you raise on.

- **Phase 2 (growth):** The same infrastructure, already deployed and audited for agent use, is extended to two-party vault commitments and bilateral settlement. The narrative expands: "we built the authorization layer for AI agents, and it turns out the same primitives are the correct foundation for trustless bilateral financial contracts." The agent user base becomes the proof of infrastructure maturity.

- **Phase 3 (platform):** Atlas is the general-purpose credible commitment layer. Not just for agents, not just for derivatives — for any conditional commitment between any parties. The developer ecosystem builds on Layer 1 primitives. The protocol earns a fee on every settlement regardless of what type of contract it is.

**The key insight for the pitch:** The agent use case is not a narrow niche that competes with the broader vision. It is the correct beachhead for building the infrastructure that eventually serves the broader vision. Every investor who asks "but isn't this just AI agents?" gets the answer: "yes, for now — and the same infrastructure, already built and audited, becomes the trustless settlement layer for every conditional financial contract that has ever required a trusted institution to enforce it."

That is not a hedge. That is a roadmap.

---

*This document is a companion to OPTIONS_EXPLAINER.md, EXTENSIONS.md, and CAPABILITIES.md. Priority specifications for the interest rate swap oracle, protocol insurance state leaf, and assurance contract threshold logic should be added to EXTENSIONS_SPEC.md in Phase 2.*
