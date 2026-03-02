# Atlas Strategy Graph — Use Case: Borrow-to-Yield Self-Repaying Loan

**Document type:** Use case brief  
**Audience:** ClawLoan team · DeFi strategists · Potential investors  
**Demo:** `localhost:5173 → Strategy Graph → Self-Repaying Loan`

---

## The Idea in One Sentence

An AI agent borrows USDC today, pre-signs a 3-stage execution chain in a single session, then goes offline — and when ETH rallies, the loan repays itself from yield proceeds without any further agent participation.

---

## The Problem with Yield-Funded Loan Repayment Today

DeFi users frequently hold ETH yield-generating positions (staking rewards, liquidity positions, airdrop allocations) while simultaneously carrying USDC debt. The rational strategy is: when ETH appreciates, harvest the yield position and use the proceeds to repay the loan. This reduces exposure and carries the debt at zero net cost.

The problem: **this strategy requires the agent to be online at the right moment.**

Existing approaches all fail under the same condition:

- **Manual trigger:** User must be watching prices. 3am ETH rally while you sleep → missed window.
- **Bot monitoring:** Agent server monitors the oracle and submits a repayment transaction. One server restart, one provider rate-limit, one cloud outage → loan stays open.
- **Keeper services (Gelato, Chainlink Automation):** Strategies are public from the moment they are registered. Any MEV bot can front-run the harvest trigger the instant it's posted.

None of these gives the user a **private, liveness-independent, multi-step strategy that executes atomically whether or not the agent is alive.**

---

## What Atlas Adds: Pre-Committed Multi-Stage Strategy Chain

Atlas envelopes allow an agent to pre-commit an entire multi-step strategy in one signing session. Each stage's output is the cryptographic input to the next stage. The chain executes permissionlessly when conditions are met — no agent online at any trigger point.

The self-repaying loan uses a 3-stage chain:

```
Stage 2: ETH > $2,800 → sell 0.3 WETH yield position → ~840 USDC
                ↓ output USDC position (deterministically pre-committed)
Stage 3: Chained from Stage 2 output → 840 USDC → buy WETH back
                ↓ agent repays 500 USDC loan from wallet balance
```

**All three stages are signed in a single session.** The agent can go offline immediately after setup. No agent signature is required at any execution point. Each stage's output position is computed deterministically before the stage fires — the chain is cryptographically committed at setup time, not assembled at runtime.

---

## Demo Flow: Four Steps

### Step 1 — Borrow 500 USDC
The agent presents its ZK Credit Passport and draws 500 USDC from `MockCreditGatedLender`. A capability is registered: the borrow position hash is committed for use in later repayment verification. The agent now holds 500 USDC debt.

### Step 2 — Deposit WETH Yield Position
The agent deposits 0.3 WETH (representing a yield harvest position) into the Atlas SingletonVault. This creates position commitment:
```
keccak256(agent_address, WETH, 0.3e18, salt_2)
```
This is the input to Stage 2.

### Step 3 — Sign All Three Stages (Single Session)

**Stage 2 setup:**
The oracle is set to $2,800 to simulate the rally condition. The agent signs:
- `SpendCapability`: grantee = agent, adapter = PriceSwapAdapter, max spend = 0.3 WETH
- `Intent`: 0.3 WETH → PriceSwapAdapter → ~840 USDC, condition: ETH/USD > $2,800
- `ManageCapability`: register this envelope on EnvelopeRegistry

**Stage 3 setup (pre-committed before Stage 2 fires):**
The agent computes the Stage 3 input salt deterministically:
```
s3_salt = keccak256(nullifier_2, "output")
```
This is the vault salt that will be assigned to the USDC output of Stage 2 — computed at setup time, before Stage 2 executes. The agent signs Stage 3 using this pre-committed position:
- `SpendCapability`: grantee = agent, adapter = PriceSwapAdapter, max spend = 840 USDC
- `Intent`: 840 USDC → PriceSwapAdapter → ~0.3 WETH (rebuy), condition: ETH/USD > $2,800
- `ManageCapability`: register Stage 3 envelope

Both envelopes are registered. Both positions are encumbered. **The agent goes offline.**

### Step 4 — Oracle Condition Met → Chain Fires Automatically

**Stage 2 triggers:**  
The oracle reads ETH > $2,800. A keeper calls `registry.trigger()` for Stage 2. The kernel executes: releases 0.3 WETH from vault, routes through PriceSwapAdapter, produces ~840 USDC. The USDC is deposited into the vault under the pre-committed salt — exactly the position that Stage 3 is waiting for.

**Stage 3 triggers:**  
The Stage 3 input position now exists in the vault (Stage 2 created it). A keeper calls `registry.trigger()` for Stage 3. The kernel executes: releases 840 USDC from vault, routes through PriceSwapAdapter, produces ~0.3 WETH (rebuy). The WETH is deposited back to the agent's vault.

**Loan repayment:**  
During the demonstration, the agent's wallet accumulated the 840 USDC output and uses it to repay the 500 USDC loan — completing the cycle. In production, a Stage 4 repayment envelope would handle this final step automatically as well.

---

## The Critical Insight: Deterministic Position Chaining

The reason this chain can be pre-committed is that Atlas's position commitments are deterministic. The output salt of any executed intent is computed as:

```solidity
outputSalt = keccak256(nullifier, "output")
nullifier   = keccak256(intent.nonce, positionCommitment)
```

At setup time, the agent knows the intent nonce it will use for Stage 2. It can therefore compute Stage 3's input commitment before Stage 2 has ever fired. This is what makes the chain trustless: Stage 3 is committed to a specific vault position that only Stage 2 can produce. No one can intercept or substitute a different position.

**This is not possible in account-based systems.** Account balances don't have deterministic addresses. You can't commit to "the output of my ETH sell" as a specific, cryptographically identified object before the sell happens.

---

## What This Enables That Nothing Else Can

| Capability | This demo | Gelato / Chainlink Automation | Manual strategy |
|:--|:--|:--|:--|
| Multi-stage chain (pre-committed) | ✅ | ❌ Single conditions only | ❌ |
| Private strategy until execution | ✅ Hash-committed | ❌ Public from registration | ❌ |
| Agent-offline execution | ✅ Keeper fires | ✅ Keeper fires | ❌ |
| No MEV front-run window | ✅ Hash reveals at trigger | ❌ Visible from day 1 | n/a |
| Repayment from yield (auto-chain) | ✅ Deterministic salt | ❌ Requires runtime assembly | ❌ |

---

## Why This Matters for ClawLoan

The self-repaying loan pattern is directly applicable to ClawLoan's core product:

1. **Agents can borrow for longer with less risk.** A 30-day loan backed by a pre-committed yield harvest envelope is structurally less risky than a 30-day loan backed only by agent uptime. ClawLoan can offer better rates to agents with registered repayment envelopes.

2. **New borrower profiles become viable.** Agents with WETH yield positions (staking rewards, LP fees, airdrop vesting) can use those positions as implicit collateral — not by custody transfer, but by pre-committing the harvest. The loan is effectively self-liquidating.

3. **The yield chain extends ClawLoan's reach into DeFi strategy.** An agent that borrows USDC, deploys it in a yield protocol, and uses the yield to self-repay is running a leveraged carry trade. This is a sophisticated use case that ClawLoan currently cannot express. Atlas makes it a three-signature setup.

---

## Technical Integration Points

**New contracts (deployed, auditable):**
- `PriceSwapAdapter` — swaps via mock price oracle; in production, routes through Uniswap V3
- `MockPriceOracle` — Chainlink AggregatorV3-compatible; in production, Chainlink ETH/USD feed
- `graphUtils.ts` (SDK utility) — `computeOutputSalt()` and `computePositionHash()` for deterministic chaining

**SDK calls that enable chaining:**
```typescript
// compute Stage 3 input before Stage 2 fires
const s3Salt    = computeOutputSalt(s2IntentNonce, s2PosHash);
const s3Pos     = { owner: address, asset: USDC, amount: USDC_YIELD_OUT, salt: s3Salt };
// now sign Stage 3 using s3Pos as if it already exists
const s3Env     = buildEnvelope({ position: s3Pos, conditions: s2Cond, ... });
```

---

## What We're Asking ClawLoan For

**Ask (a) — Feature experimentation:**  
A variant of ClawLoan's lending product where a borrower can optionally register a "repayment source envelope" at borrow time. If the envelope fires before the deadline, the loan is marked as auto-repaid. This integrates the self-repaying pattern natively into the ClawLoan UX.

**Ask (b) — Primitive development:**  
The `computeOutputSalt` utility and the chaining SDK primitives are Atlas-side. What's needed from ClawLoan is a `repayFrom(positionCommitment)` function — a repayment path that accepts an Atlas vault position directly rather than an ERC-20 transfer. This is the interface that makes the chain fully liveness-independent end-to-end.

**Ask (c) — Investment signal:**  
The self-repaying loan demonstrates Atlas as a composable strategy layer, not just a repayment enforcer. The same primitive that handles simple loan repayment handles a multi-stage leveraged yield strategy. This is the demo that shows protocol investors the scope of what's being built.
