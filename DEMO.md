# Atlas Protocol — Demo Script
**For investors, developers, and technical reviewers**
*Internal document — February 2026*

---

## Setup Checklist (5 minutes)

```bash
# 1. Start Anvil
anvil --block-time 1 --chain-id 31337

# 2. Deploy all contracts
forge script script/DeployClawloanDemo.s.sol \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

# 3. Build SDK, start UI
cd sdk && npm run build && cd ../ui && npm run dev
```

Open `http://localhost:5173`. Connect MetaMask (localhost:8545, chain ID 31337). The UI auto-airdrops 10 ETH for gas.

---

## The Core Claim

> **No agent signature can move more value than the capability bounds, even under full key compromise.**

This is not a design goal or a promise in a whitepaper. Every scenario below demonstrates it on-chain. The invariant holds whether the agent is online, offline, compromised, or never comes back.

---

## Scenario 1 — AI Agent Credit (`?scenario=clawloan`)

**Talking points:** liveness-independent enforcement, credit reputation, lender protection.

**Time:** ~4 minutes end-to-end.

### Walk-through

**Step 0 — Get test USDC**
Mint $1,000 USDC to your wallet. The pool also needs liquidity — the script pre-seeds it.

**Step 1 — Borrow $500 from Clawloan**
The agent borrows $500 USDC, unsecured. No collateral. Credit comes from the agent's on-chain ZK proof track record.

*Talking point:* "The borrowing isn't the interesting part. What's interesting is what happens to the repayment obligation."

**Step 2 — Deposit $1,000 earnings**
The agent completes an off-chain task, earns $1,000 USDC, and deposits it into the Atlas `SingletonVault`. The vault records `keccak256(owner, USDC, 1000, salt)` — not a balance. A hash. The agent's position is a discrete, encumberable object.

*Talking point:* "No per-user contract. No balance mapping. A hash in a shared vault. This is what makes liveness-independent enforcement architecturally possible — you can lock a commitment. You can't lock an account balance."

**Step 3 — Register the repayment envelope**
The agent signs three EIP-712 messages offline:
- `Capability` — "I authorize someone to spend from my vault position, up to $600 USDC"
- `Intent` — "spend via `ClawloanRepayAdapter`, repay loan #1, minimum $400 surplus returned to me"
- `manage Capability` — "I authorize the registry to execute this specific envelope"

Then calls `EnvelopeRegistry.register()`. The position is now **encumbered** — the agent cannot withdraw or double-spend it.

*Talking point:* "The agent has committed, on-chain, to exactly what will happen. It doesn't matter what the agent does next. It can be killed, compromised, or go dark. The execution is already authorized."

**Step 4 — Agent goes offline → Keeper triggers**
Click "Trigger as Keeper" (or open `?role=keeper` in a second browser tab to see the keeper's perspective).

The UI warps Anvil's clock past the loan deadline, then any address calls `trigger()`. The registry reads the oracle, verifies the condition, calls the kernel with the revealed preimages. Kernel verifies all signatures, releases the position, calls `ClawloanRepayAdapter`:
- $500 debt repaid to pool
- $500 surplus committed as a new vault position for the agent

*Talking point:* "The agent is offline for this entire step. No agent key signed anything here. The keeper used zero information from the agent — only what was committed on-chain in Step 3."

**Step 5 — Submit ZK credit proof**
The agent submits a ZK proof that its receipt history is constraint-compliant. `CreditVerifier` assigns a higher credit tier (BRONZE → SILVER → GOLD). The next borrow gets a larger unsecured limit.

*Talking point:* "This is the credit loop that no existing system has. The agent proves compliance without revealing individual trades. The proof is portable — it works across any lending protocol that verifies Atlas receipts."

**Right panel — Lender perspective**
The `LenderPanel` shows the lender's view: $500 funded, 5% APY, $25 profit share from this repayment. Enforcement guarantees checklist. Key-compromise invariant:

| Without Atlas | With Atlas |
|---|---|
| Attacker holds full key → drains everything | Attacker holds full key → executes only pre-signed intent, within $600 debtCap |
| Lender has zero protection | Lender's $500 is repaid regardless of what happens to the agent |

---

## Scenario 2 — Dead Man's Switch (`?scenario=dms`)

**Talking points:** reverse liveness enforcement, estate planning without intermediaries, organizational continuity.

**Time:** ~3 minutes.

### Walk-through

**Step 0 — Mint $2,000 treasury**
The DAO agent controls a $2,000 USDC treasury. Mint it to your wallet.

**Step 1 — View beneficiary**
Anvil account #1 is the DAO multisig beneficiary. Its address is committed — encoded into the EIP-712 intent hash. Nobody can redirect the transfer to a different address; changing the beneficiary changes the hash and invalidates the agent's signature.

*Talking point:* "The beneficiary is cryptographically committed at envelope creation. An attacker who somehow intercepts the execution cannot reroute funds — the intent hash would fail kernel verification."

**Step 2 — Deposit treasury into vault**
Same vault, same commitment model.

**Step 3 — Arm the Dead Man's Switch**
The agent registers an envelope with:
- Condition: `block.timestamp > lastHeartbeat + 24 hours`
- Adapter: `DirectTransferAdapter(beneficiary = DAO multisig)`

The `DirectTransferAdapter` forwards `amount - 1` to the beneficiary and returns 1 dust unit to satisfy the vault's non-zero commitment invariant.

**Step 4A — Check In (agent stays alive)**
The agent re-registers with a fresh 24h deadline. This cancels the old envelope (releasing the encumbrance) and creates a new one. As long as the agent checks in, funds stay under agent control.

**Step 4B — Go Dark (agent stops responding)**
Skip check-in. Click "Trigger Switch" (warps time +25h). Any keeper triggers the envelope. The $1,999 USDC flows to the beneficiary. Beneficiary balance updates live on-chain.

*Talking point:* "Existing solutions for this use Gnosis Safe time-locks or manually-deployed inheritance contracts. Atlas uses a generic envelope with a standard adapter — no custom contract per use case. The same kernel handles the DMS, the stop-loss, and the loan repayment."

---

## Scenario 3 — Sub-agent Fleet (`?scenario=orchestration`)

**Talking points:** hierarchical agent architectures, budget isolation, fleet analytics.

**Time:** ~5 minutes (running both agents).

### Walk-through

**Orchestrator dashboard**
Live metrics from `MockSubAgentHub`:
- Total budget: $3,000 USDC
- Allocated to agents: $1,500 Alpha + $1,500 Beta = $3,000
- Outstanding debt, repaid, fleet P&L, utilisation bar

**Sub-agent Alpha / Beta cards**
Each shows: agent address, budget cap, current debt, status. "Run full cycle" atomically:

1. Borrows $500 from Clawloan
2. Records borrow in hub (reverts if over budget cap — the isolation guarantee)
3. Deposits $1,000 earnings
4. Signs capability + intent + manage capability
5. Registers envelope
6. Warps time past deadline
7. Triggers envelope (debt repaid, surplus returned)
8. Records repay in hub (P&L updates)
9. Submits credit proof (tier upgrades)

Run both agents. The orchestrator dashboard shows aggregate fleet P&L updating in real time.

**Delegation architecture diagram**
The right panel shows the hierarchical architecture:
- Orchestrator → Sub-agent Alpha, Sub-agent Beta
- Each sub-agent's capability is a strict subset of the orchestrator's root capability
- Phase 1: `MockSubAgentHub` enforces budget at application layer
- Phase 2: `parentCapabilityHash + delegationDepth` enforces on-chain at kernel level

*Talking point:* "Institutional trading desks run Analyst AI → Risk AI → Execution AI chains today with shared keys. Every agent in the chain has full authority if any one is compromised. Atlas bounds each level. The execution agent cannot exceed what the risk agent authorized. The risk agent cannot exceed what the analyst authorized. Compromise of any node is isolated to that node's capability."

---

## Key Questions Investors Ask

**"Can't MetaMask just add this?"**

MetaMask's delegation toolkit (ERC-7710/7715) solves consent and permission UX. It does not solve commitment-based custody or liveness-independent enforcement. The liveness guarantee requires positions to be discrete, encumberable objects — not account balances. You cannot lock an account balance. You can lock a commitment. Adding commitment-based custody to MetaMask would require redesigning custody from scratch. They would ship a new protocol, which is Atlas.

**"What's the moat if the contracts are open source?"**

Not the code — the execution data. The protocol observes every intent, every rejected intent, every envelope trigger, every oracle staleness event. No other system sits at the intersection of authorization, custody, and enforcement simultaneously. After 12 months of production, that dataset powers better constraint presets, better anomaly detection, and agent safety oracles. A competitor copying the code starts from zero data.

**"Why would a keeper run this?"**

Every triggered envelope earns `keeperRewardBps` of the output plus `minKeeperRewardWei` as a minimum. On Base, trigger gas costs $0.05–0.20. The minimum reward must exceed this by design — envelopes with inadequate keeper rewards are rejected at registration. Any address can trigger any matured envelope. One keeper being bribed or offline creates an arbitrage opportunity for every other keeper.

**"What about oracle manipulation?"**

`minReturn` on every intent provides a hard output floor independent of the oracle. Oracle manipulation can cause an early trigger; it cannot cause a bad fill — the kernel reverts if the fill doesn't meet `minReturn`. For large positions, TWAP leaf conditions (Phase 2) require manipulation to persist across hundreds of blocks, making the attack economically infeasible.

**"This seems like it only works for simple stop-losses."**

Look at EXTENSIONS.md. The condition tree (AND/OR of oracle conditions) means this is the settlement infrastructure for any pre-committed autonomous strategy. Protective puts, covered calls, collars, cascading liquidations, cross-asset rotation, protocol health monitoring exits — all expressible as condition trees. The commitment model (hash-then-reveal) means complex strategies stay private until execution. No existing conditional execution system (Gelato, Chainlink Automation, Uniswap limit orders) can combine private strategies with manipulation-resistant execution.

---

## Talking Points Summary

```
"An AI agent is not an account. It is a policy engine with a signing key.
 It should hold no custody and have authority scoped to exactly what the user intended —
 cryptographically enforced on-chain, not instructed in a system prompt."

"Three demos. Each proves something no existing system can prove."

"The invariant that matters: the attacker holds the full key.
 Without Atlas: they drain everything within session scope.
 With Atlas:    they execute one pre-signed intent, bounded by debtCap, then revocation fires."

"The envelope fires even if the agent is offline, compromised, or destroyed.
 That is a hard guarantee. Not a best-effort. Not a monitoring service. A cryptographic commitment."
```
