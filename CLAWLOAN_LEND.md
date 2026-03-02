# ClawLoan × Atlas — Use Case: Capital Provider (Lend)

**Document type:** Use case brief  
**Audience:** ClawLoan team · Institutional lenders · Potential investors  
**Demo:** `localhost:5173 → ClawLoan → Lend`

---

## The Problem: Risk Management in AI-Agent Lending

Traditional DeFi lending protocols manage risk through governance. If a pool reaches dangerous utilization levels, the response is a DAO vote, a risk parameter update, a timelock, and then execution — a process that takes 48–72 hours in the best case and requires a functioning governance quorum to initiate.

For AI-agent lending, this is too slow and too centralized. Utilization can spike from 40% to 95% in minutes when multiple agents draw against the same pool simultaneously. The lender has three bad options:

1. **Accept the governance delay** — pool is overexposed while the DAO deliberates
2. **Set permanent conservative limits** — underutilize capital, reduce yield
3. **Withdraw capital preemptively** — leave the market entirely

None of these is a satisfying answer for an institutional lender managing a lending position.

**What's missing is a lender-defined, cryptographically enforceable risk policy that executes automatically — without requiring the lender to be online, without a governance vote, and without trusting the protocol team to act.**

---

## What Atlas Adds: Pre-Committed Lender Risk Policy

Atlas gives institutional lenders a new primitive: the ability to define their risk policy in advance and have it execute permissionlessly when conditions are met.

The lender signs an Atlas Envelope that encodes:
- **Condition:** `UtilisationOracle ≥ threshold` (e.g. pool utilization reaches 44%)
- **Action:** `PoolPauseAdapter → pool.pauseBorrowing()`
- **Executor:** Any Atlas keeper — permissionless, no ops team

Once the envelope is registered, the lender's risk policy is live. If utilization breaches the threshold at 3am on a Sunday while the lender is asleep and the protocol team is offline, the keeper triggers the envelope and the pool pauses automatically. No governance. No multisig. No phone call.

The lender's key signed the policy. The protocol's job is to execute it faithfully. That's the entire trust model.

---

## Demo Flow: Six Steps

### Step 1 — Fund the Pool
The lender deposits 100,000 USDC into the `MockCapitalPool`. The deposit is recorded as lender capital (pro-rata yield share). The pool is now available for ZK-verified borrowers to draw against.

*Capital is in the pool. No risk controls are live yet — that comes next.*

### Step 2 — Define Risk Policy
Before any borrower is onboarded, the lender selects a risk profile:

| Preset | Utilization Guard | Tier 1 Limit | Tier 2 Limit | Max Duration |
|:--|:--|:--|:--|:--|
| Conservative | 70% | $5,000 | $20,000 | 14 days |
| Moderate | 80% | $10,000 | $35,000 | 30 days |
| Standard | 90% | $10,000 | $50,000 | 30 days |
| **Demo** | **44%** | **$10,000** | **$50,000** | **7 days** |

The selected policy is locked on-chain via `setTierLimit()` and `setUtilizationGuard()`. The lender sees a **Policy Card** that shows exactly what will be committed — utilization guard, credit tier limits, max loan duration — before any signature is requested.

*The policy is on-chain. Tier limits are enforced immediately for all future borrowers.*

### Step 3 — Verify Borrower Credit Tier
A borrower presents their ZK Credit Passport. The passport proves: grade 2 creditworthiness (income > $150k, credit score 780+, zero defaults) without revealing any personal information. The pool assigns Tier 2 — borrowing up to the policy-defined limit. No identity is ever exposed to the lender or the protocol.

### Step 4 — Agent Draws Loan
Bot #99 draws 45,000 USDC against its Tier 2 limit. Pool utilization rises to 45%. With the Demo preset's 44% guard, this already exceeds the threshold.

*The condition for the guard envelope is already met.*

### Step 5 — Register the Guard Envelope (3 Signatures)
The lender signs three EIP-712 messages:
1. **SpendCapability** — authorizes the PoolPauseAdapter to spend the 100 USDC sentinel position
2. **Intent** — specifies the action: sentinel USDC → PoolPauseAdapter → call `pool.pauseBorrowing()`
3. **ManageCapability** — delegates envelope registration authority to the EnvelopeRegistry

The envelope is registered. The UtilisationOracle is wired as the condition feed. Because pool utilization (45%) already exceeds the guard threshold (44%), a keeper triggers the envelope immediately. The PoolPauseAdapter fires. New borrows are paused. The sentinel USDC is returned to the vault intact (the adapter is a pure pass-through — zero cost beyond gas).

**From this moment, no new loans can be issued until the lender or governance resumes the pool.**

### Step 6 — Repayment + Yield Claim
Bot #99 repays 45,000 USDC principal + 2,250 USDC interest (5% rate). 80% of interest (1,800 USDC) is distributed to lenders via the on-chain yield accumulator (`yieldPerShareScaled`). The lender calls `claimYield()` and receives their pro-rata share directly to their wallet.

**No trust in a protocol team to calculate yield correctly. The math is on-chain arithmetic.**

---

## Live Pool Stats (During Demo)

The UI shows real-time pool metrics, refreshed every 3 seconds:

| Metric | After Step 1 | After Step 4 | After Step 5 | After Step 6 |
|:--|:--|:--|:--|:--|
| Total Capital | $100,000 | $100,000 | $100,000 | $100,000 |
| Active Loans | $0 | $45,000 | $45,000 | $0 |
| Utilization | 0% | 45% | 45% (paused) | 0% |
| Yield Earned | $0 | $0 | $0 | $1,800 |
| Pool Status | Active | Active | **Paused** | Active |

The utilization bar shows the guard threshold as a visible marker. When utilization crosses it, the bar turns amber.

---

## Without Atlas vs. With Atlas

| Risk event | Without Atlas | With Atlas |
|:--|:--|:--|
| Utilization spikes to 90% at midnight | DAO forum post; 48h vote; execution | Keeper fires in the same block the condition is met |
| Protocol team is unreachable | No mitigation path | Irrelevant — the envelope is permissionless |
| Lender's risk parameters change | Governance proposal + vote | Update policy and re-register envelope (lender's own key) |
| Lender wants proof their policy ran | Trust the protocol logs | On-chain tx hash: envelope triggered, adapter called, pool paused |
| Yield calculation | Trust the protocol math | `yieldPerShareScaled` is public arithmetic; verify locally |

---

## What Institutional Lenders Actually Need

For an institutional capital provider to deploy meaningful capital into an AI-agent lending pool, four guarantees must be met:

**1. Defined risk tolerance, not delegation of risk judgment.**  
The lender sets the utilization threshold. The protocol executes it. No one at the protocol team decides whether the threshold was "really" breached or whether to act.

**2. No single point of failure.**  
Traditional DeFi risk management relies on a team monitoring dashboards and having the authority to act. This is a point-of-failure. Atlas keepers are permissionless — any party can trigger an envelope. No one needs to be awake.

**3. Verifiable execution.**  
"The pool was paused because utilization hit 90%" is a claim. On Atlas, it's a transaction hash with a specific event log that anyone can inspect. The trigger is auditable.

**4. Capital efficiency.**  
Conservative risk management is currently achieved by setting permanent low limits. With an enforceable utilization guard, the lender can set more aggressive limits — confident that the automated backstop will engage if the pool overextends.

---

## Technical Architecture

```
Lender
  └── Policy defined: setTierLimit(2, $50k), setUtilizationGuard(4400 bps)
  └── Sentinel USDC deposited to SingletonVault
  └── Signs: SpendCapability + Intent + ManageCapability (3 EIP-712 msgs)
        └── Intent: USDC sentinel → PoolPauseAdapter → pool.pauseBorrowing()
        └── Condition: UtilisationOracle > 4399 bps

EnvelopeRegistry
  └── Envelope stored; sentinel position encumbered

UtilisationOracle (Chainlink AggregatorV3-compatible)
  └── latestRoundData() → reads pool.getUtilizationBps() → returns BPS as int256

Keeper (permissionless)
  └── Monitors: oracle answer > triggerPrice?
  └── Calls: registry.trigger(envelopeHash, conditions, ...)
  └── CapabilityKernel verifies all signatures, routes to PoolPauseAdapter
  └── PoolPauseAdapter.execute() → pool.pauseBorrowing()
  └── Sentinel USDC returned to vault intact
```

### New Contracts (all deployed, all auditable)

| Contract | Location | Purpose |
|:--|:--|:--|
| `MockCapitalPool` | `test/mocks/MockCapitalPool.sol` | Pool with tiered credit limits, yield accumulator, utilization guard |
| `UtilisationOracle` | `contracts/oracles/UtilisationOracle.sol` | Chainlink-compatible feed wrapping pool utilization |
| `PoolPauseAdapter` | `contracts/adapters/PoolPauseAdapter.sol` | Atlas adapter: calls pauseBorrowing(), returns sentinel USDC |

---

## What We're Asking ClawLoan For

**Ask (a) — Feature experimentation:**  
An interface on ClawLoan's production pool that exposes `pauseBorrowing()` callable from an Atlas adapter (not only from an admin address). Specifically: a `authorizedKeeper` mapping that the lender can register the Atlas kernel address into at pool setup time.

**Ask (b) — Primitive development:**  
Collaboration on the `UtilisationOracle` interface. Currently wraps a mock pool. A production version wraps ClawLoan's real pool contract and is listed in the Atlas oracle registry, making it available to all institutional lenders on the protocol.

**Ask (c) — Investment signal:**  
The Capital Provider scenario demonstrates what a two-sided, cryptographically governed lending market looks like. Institutional lenders set policy. The protocol enforces it. This is the product story that unlocks real institutional capital deployment — not just retail DeFi deposits.
