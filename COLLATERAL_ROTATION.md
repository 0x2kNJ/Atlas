# Atlas Strategy Graph — Use Case: Bi-Directional Collateral Rotation

**Document type:** Use case brief  
**Audience:** ClawLoan team · DeFi strategists · Potential investors  
**Demo:** `localhost:5173 → Strategy Graph → Collateral Rotation`

---

## The Idea in One Sentence

An agent holds 1 WETH, pre-commits a two-stage protection cycle — de-risk to USDC when ETH drops, re-risk back to WETH when it recovers — then goes offline while the full cycle executes permissionlessly.

---

## The Problem with Automated Position Management Today

Sophisticated DeFi users and AI agents want to manage directional exposure without constant attention. The pattern is simple:

1. When ETH looks weak, rotate to stablecoins  
2. When ETH looks strong again, rotate back

The problem is **every current approach breaks under the exact conditions it's needed most:**

- **Manual rotation:** The market moves while you're asleep, offline, or distracted
- **Simple stop-loss orders:** Fire and forget — position stays in USDC forever, agent misses the recovery
- **Bot-based monitoring:** One server failure at the wrong moment, strategy fails. And the bot's strategy is visible on-chain from registration, leaking information to MEV operators
- **Two separate bots:** Requires both to be running; second bot can be manipulated independently; no cryptographic link between de-risk and re-risk stages

None of these provides a **pre-committed, private, bi-directional cycle** that executes as a single atomic strategy regardless of agent liveness.

---

## What Atlas Adds: Pre-Committed Two-Stage Cycle

Atlas enables the agent to pre-sign both stages of the rotation in a single session and commit them as a linked pair of envelopes. The output of Stage 1 is the cryptographically pre-determined input of Stage 2. The chain is private until execution and fully permissionless once registered.

```
Initial state: 1 WETH in vault

Stage 1: ETH/USD < $1,800 (de-risk)
  → WETH → PriceSwapAdapter → ~1,800 USDC
  → USDC deposited to vault (deterministic salt, pre-computed)

Stage 2: ETH/USD > $1,800 (re-risk)
  → 1,800 USDC → PriceSwapAdapter → ~1 WETH (at recovery price)
  → WETH deposited to vault

Agent is offline for both triggers. Net result: same WETH exposure, 
with downside protected during the drawdown window.
```

Both stages are signed in a single session before the agent goes offline. Each stage reveals only its own parameters at trigger time — the overall strategy is a committed hash until execution.

---

## Demo Flow: Four Steps

### Step 1 — Deposit WETH
The agent deposits 1 WETH into the Atlas SingletonVault. This creates:
```
positionCommitment = keccak256(agent_address, WETH, 1e18, salt_1)
```

### Step 2 — Pre-Compute Stage 2 Input
Before signing anything, the agent computes the USDC position that Stage 1 will produce:
```typescript
const s2Salt  = computeOutputSalt(s1IntentNonce, s1PosHash);
const s2Pos   = { owner: address, asset: USDC, amount: USDC_MID, salt: s2Salt };
```

This USDC position does not exist yet. But its commitment is deterministically knowable from Stage 1's nonce and position hash. The agent can sign Stage 2 now, committing to a position that only Stage 1 can create.

**This is the cryptographic link that makes the cycle atomic.** No one can substitute a different USDC amount or redirect the Stage 1 output — the commitment is specific.

### Step 3 — Sign Both Stages (Single Session)

**Stage 1 (de-risk):**
- Oracle set to $1,700 (below $1,800 trigger for demo purposes)
- Signs: SpendCapability (WETH) + Intent (WETH → USDC, condition: ETH < $1,800) + ManageCapability
- Envelope registered, WETH position encumbered

**Stage 2 (re-risk, pre-committed to Stage 1's output):**
- Oracle set back to a recovery price above $1,800
- Signs: SpendCapability (pre-committed USDC position) + Intent (USDC → WETH, condition: ETH > $1,800) + ManageCapability
- Envelope registered

**The agent goes offline. Both envelopes are live.**

### Step 4 — Keeper Triggers the Full Cycle

**Stage 1 fires:**  
ETH price is below $1,800. Keeper calls `trigger()` for Stage 1. Kernel verifies signatures, releases WETH from vault, routes through PriceSwapAdapter, deposits ~1,800 USDC to vault under the pre-computed salt. Stage 1 envelope is consumed.

**Stage 2 fires:**  
The USDC position (created by Stage 1) now exists in the vault under exactly the salt Stage 2 was committed to. Keeper calls `trigger()` for Stage 2. Kernel verifies signatures, releases USDC from vault, routes through PriceSwapAdapter, deposits ~1 WETH back to vault.

Cycle complete. The agent's WETH exposure is restored. The full rotation — de-risk and re-risk — happened without a single agent signature at trigger time.

---

## Why Pre-Committed Chaining Changes the Security Model

Consider what happens if only Stage 1 was registered (simple stop-loss):

1. Agent deposits WETH, registers "sell below $1,800" envelope
2. ETH drops, Stage 1 fires, USDC lands in vault
3. ETH recovers
4. **Agent must now be online to register Stage 2 and rebuy**

If the agent is offline during the recovery window, the de-risking worked but the re-risking didn't. The agent is permanently holding USDC instead of WETH through the recovery. The strategy is incomplete.

With the pre-committed cycle, Stage 2 is registered before Stage 1 fires. The agent has cryptographically committed to the rebuy at setup time. If the recovery happens while the agent is offline, the keeper fires Stage 2 automatically. The full cycle is liveness-independent.

**This is a qualitatively different product than a stop-loss.** A stop-loss exits. A rotation cycle protects and restores.

---

## Risk Properties

**No liquidation risk.**  
This is not a leveraged position. The agent holds WETH and pre-commits to a conditional swap cycle. There is no debt, no LTV ratio, no health factor, no liquidation cascade. The worst outcome is the swap executes at a price worse than expected — bounded by `minReturn` on each intent.

**MEV protection.**  
Both envelopes are stored as hash commitments. The strategy — the trigger prices, the swap amounts — is unknown to MEV operators until the moment of execution. The keeper reveals only the active stage's parameters at trigger time. A sandwich bot cannot front-run a strategy that is invisible until it executes.

**Isolated exposure.**  
Each stage operates on a specific, encumbered vault position. The agent's other positions are unaffected. A bug in Stage 2 cannot drain Stage 1's assets.

**No counterparty.**  
There is no option writer, no clearinghouse, no liquidity pool counterparty. The rotation is executed through a DEX adapter. The only parties involved are the vault (holding positions), the oracle (providing price signals), and the keeper (triggering execution).

---

## Connection to ClawLoan

The collateral rotation pattern connects to ClawLoan in two concrete ways:

**1. Automatic collateral protection for ClawLoan positions.**  
An agent that holds WETH as implicit backing for a ClawLoan borrow can pre-register a rotation cycle as a risk management layer. If ETH drops sharply, the de-risk stage converts WETH to USDC before the position deteriorates. The lender's exposure is protected by the agent's own pre-committed strategy — not by the protocol demanding collateral.

**2. The re-risk stage can be linked to loan repayment.**  
A 3-stage variant: de-risk to USDC, repay loan from USDC, then re-risk remaining proceeds back to WETH. This is a single pre-committed strategy that automatically unwinds a leveraged position on a price dip. The agent sets this up once and goes offline. The entire lifecycle — protection, repayment, restoration — executes without the agent being reachable.

---

## What This Enables That Nothing Else Can

| Property | This demo | Uniswap limit orders | Gelato stop-loss | Manual |
|:--|:--|:--|:--|:--|
| Bi-directional pre-committed cycle | ✅ | ❌ One-way only | ❌ One-way only | ❌ Requires intervention |
| Private strategy until trigger | ✅ Hash-committed | ❌ Public from posting | ❌ Public from posting | n/a |
| Agent-offline for full cycle | ✅ | ✅ (partial) | ✅ (partial) | ❌ |
| Cryptographic link between stages | ✅ Deterministic salt | ❌ No linkage | ❌ No linkage | ❌ |
| No MEV front-run window | ✅ | ❌ | ❌ | n/a |
| No liquidation risk | ✅ | ✅ | ✅ | ✅ |

---

## What We're Asking ClawLoan For

**Ask (a) — Feature experimentation:**  
A ClawLoan variant where a borrower can associate their borrow position with a pre-committed rotation envelope. When the de-risk stage fires, the resulting USDC output can be partially routed to repay the loan before the remainder is subject to re-risking. This requires a `repayFromEnvelope(envelopeHash, borrowId)` hook in the ClawLoan contract.

**Ask (b) — Primitive development:**  
The `computeOutputSalt` utility is Atlas-side and already deployed. What's needed from ClawLoan is confirmation on their oracle interface — whether Chainlink ETH/USD feeds are acceptable as trigger oracles, or whether ClawLoan operates its own price feed. This determines which oracle we wire to the rotation triggers.

**Ask (c) — Investment signal:**  
Collateral rotation demonstrates that Atlas is not a repayment enforcer — it's a strategy layer. The same infrastructure that handles "repay on deadline" handles "de-risk on price drop, re-risk on recovery, repay from proceeds." This is the framing that makes Atlas interesting to investors beyond the lending use case: it's a composable autonomous strategy primitive.

---

## Summary

The collateral rotation use case demonstrates three things in sequence:

1. **Pre-commitment works for multi-stage strategies.** The agent doesn't need to be online for Stage 2 because Stage 2 was committed before Stage 1 fired.

2. **The commitment model enables privacy.** The MEV-relevant information (trigger prices, amounts) is hidden as a hash commitment until the keeper reveals it at execution time. This is not possible on account-based systems.

3. **The strategy layer is composable with lending.** A rotation cycle that includes a repayment step is the natural risk management layer for any AI agent carrying ClawLoan debt. The Borrow use case and the Collateral Rotation use case combine into a single pre-committed strategy object.

This is the direction the product grows: not individual primitives, but composable strategy graphs that an agent pre-commits to in one session and executes liveness-independently across multiple conditions and time horizons.
