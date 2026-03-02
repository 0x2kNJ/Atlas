# Atlas Protocol — Demo Suite

> **The enforcement rail for AI agent finance.**
> No agent signature can move more value than the capability bounds — regardless of whether the agent is offline, its key is compromised, or it never comes back online.

Three working scenarios demonstrate properties no existing system can prove. All run on a local Anvil node.

---

## What is Atlas?

Atlas is a **stateless agent execution layer**. It solves four problems that ERC-4337, session keys, and delegation toolkits leave unsolved:

| Problem | Today's answer | Atlas's answer |
|---|---|---|
| Agent goes offline at 3am | Position unmanaged | Envelope fires permissionlessly via keeper |
| Agent key compromised | Everything within session scope drained | Capability bounds cap maximum loss to the period limit |
| Multi-agent authority chains | Multiple accounts, no constraint inheritance | Sub-capabilities verified as strict subset of parent |
| Proof of compliance without revealing trades | Not possible | ZK receipt chain → credit tier → higher borrow limits |

The invariant: **a valid capability + intent + nullifier produces a deterministic, bounded, non-replayable execution. Nothing else does.**

---

## Three Scenarios

### Phase 1 — Clawloan Credit (`?scenario=clawloan`)

An AI agent borrows **$500 USDC** unsecured from Clawloan based on its agent identity. It completes an on-chain task (earns **$1,000 USDC**), deposits the earnings into the Atlas vault, and pre-authorizes repayment via a signed envelope. The agent goes offline. A keeper triggers the envelope at the loan deadline — repaying the debt and returning the profit — without the agent's involvement.

**What this proves:** liveness-independent enforcement, credit tier accumulation via ZK proofs, lender protection with capability-bounded spending.

**Lender panel shows:** 5% APY on funded loan, 5% profit share per repayment, Atlas enforcement guarantees, key-compromise invariant (attacker can execute only the pre-signed intent, bounded by `debtCap`).

**Keeper Mode** (`?role=keeper`): open in a second tab to simulate a third-party keeper triggering envelopes registered by the agent tab.

### Phase 2 — Dead Man's Switch (`?scenario=dms`)

An AI agent manages a **$2,000 USDC** DAO treasury. It pre-signs a failsafe: "if I stop checking in for 24 hours, transfer all funds to the DAO multisig." The agent periodically checks in (cancel + re-register with fresh deadline). If it goes dark, any keeper triggers the switch and the funds flow to the DAO.

**What this proves:** inverse liveness enforcement, beneficiary commitment baked into EIP-712 intent hash (cannot be redirected by attacker), complete treasury protection without trusted intermediaries.

Uses `DirectTransferAdapter` — forwards (position.amount − 1) to the pre-committed beneficiary, returns 1 dust unit to vault to satisfy non-zero deposit invariant.

### Phase 3 — Sub-agent Fleet (`?scenario=orchestration`)

An orchestrator controls a **$3,000 USDC** budget and deploys two specialised sub-agents (Alpha: yield-farming, Beta: arbitrage), each with a **$1,500 USDC** allocation. Each sub-agent independently runs the full Clawloan credit cycle. The `MockSubAgentHub` enforces per-agent budget caps, tracks orchestrator P&L, and provides a single dashboard for fleet status.

**What this proves:** hierarchical agent architecture with budget isolation, independent credit histories per agent, aggregated orchestrator analytics.

`MockSubAgentHub` is the Phase 1 application-layer enforcement of what `parentCapabilityHash + delegationDepth > 0` will enforce natively in Phase 2.

---

## Architecture

```
Agent (off-chain)
  signs Capability (EIP-712, zero gas) ──── what the agent may do
  signs Intent (EIP-712, zero gas) ──────── exactly what to execute
  calls register() ──────────────────────── position becomes encumbered

EnvelopeRegistry
  stores keccak256(Envelope) ──────────────  only hashes on-chain
  encumbers position in SingletonVault ───── agent cannot withdraw

[any keeper, any time condition is met]
  calls trigger(hash, conditions, intent) ── reveals preimages
  CapabilityKernel re-verifies all sigs ──── 18-step check sequence
  adapter.execute() ──────────────────────── loan repaid / funds transferred

SingletonVault
  commits output as new position ─────────── surplus returned to agent
  ReceiptAccumulator records receipt ──────── ZK proof anchor
```

### Contracts

| Contract | Purpose |
|---|---|
| `SingletonVault` | Hash-commitment vault — `keccak256(owner, asset, amount, salt)`, no balance mapping |
| `CapabilityKernel` | 18-step EIP-712 verification + execution coordinator |
| `EnvelopeRegistry` | Pre-committed conditional execution — oracle-gated, keeper-triggered |
| `ReceiptAccumulator` | Per-capability execution receipts (ZK proof anchor for Circuit 1) |
| `CreditVerifier` | ZK-proof-gated credit tier assignment (NEW → BRONZE → SILVER → GOLD → PLATINUM) |
| `ClawloanRepayAdapter` | Repay Clawloan debt from earnings, return surplus as new vault position |
| `DirectTransferAdapter` | Transfer position to pre-committed beneficiary (Dead Man's Switch) |
| `MockSubAgentHub` | Orchestrator budget ledger — per-agent allocation, borrow/repay tracking |

### SDK

```typescript
import {
  buildCapability, buildManageCapability, buildIntent, buildEnvelope,
  signCapability, signManageCapability, signIntent,
  hashCapability, hashEnvelope, hashPosition,
  clawloanRepayLive, randomSalt, ComparisonOp, LogicOp,
} from "@atlas-protocol/sdk";
```

**Critical timing note:** All deadline/expiry calculations use **`publicClient.getBlock("latest").timestamp`**, not `Date.now()`. The demo scenarios warp Anvil time forward; using wall-clock time produces `EnvelopeNotActive()` on subsequent scenario runs.

---

## Deployed Addresses

Deterministic from Anvil account 0, starting at nonce 0. Always the same on a fresh Anvil.

```
MockUSDC:              0x5FbDB2315678afecb367f032d93F642f64180aa3  (nonce 0)
MockClawloanPool:      0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512  (nonce 1)
MockTimestampOracle:   0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9  (nonce 2)
SingletonVault:        0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9  (nonce 3)
CapabilityKernel:      0x5FC8d32690cc91D4c39d9d3abcBD16989F875707  (nonce 4)
EnvelopeRegistry:      0x0165878A594ca255338adfa4d48449f69242Eb8F  (nonce 5)
ReceiptAccumulator:    0xa513E6E4b8f2a923D98304ec87F64353C4D5C853  (nonce 6)
MockCircuit1Verifier:  0x2279B7A0a67DB372996a5FaB50D91eAA73d2eBe6  (nonce 7) [not in addresses.ts]
CreditVerifier:        0x8A791620dd6260079BF849Dc5567aDC3F2FdC318  (nonce 8)  [note: nonce 9 in cast]
ClawloanRepayAdapter:  0x610178dA211FEF7D417bC0e6FeD39F05609AD788  (nonce 10 in cast)
DirectTransferAdapter: 0xB7f8BC63BbcaD18155201308C8f3540b07f84F5e  (nonce 11)
MockSubAgentHub:       0xA51c1fc2f0D1a1b8494Ed1FE312d7C3a78Ed91C0  (nonce 12)
```

---

## Local Setup

### Prerequisites

- [Foundry](https://getfoundry.sh/) — `forge`, `anvil`, `cast`
- Node.js 18+
- Git submodules (OpenZeppelin)

### 1. Initialize dependencies

```bash
git submodule update --init --recursive
```

### 2. Build contracts

```bash
forge build
```

### 3. Start Anvil

```bash
anvil --block-time 1 --chain-id 31337
```

### 4. Deploy the full demo stack

Run **only this script** — `Deploy.s.sol` shifts deployer nonces and changes all contract addresses.

```bash
forge script script/DeployClawloanDemo.s.sol \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
```

This deploys all contracts including `DirectTransferAdapter` and `MockSubAgentHub` (Phase 2 & 3).

### 5. Build the SDK

```bash
cd sdk && npm install && npm run build
```

### 6. Start the UI

```bash
cd ui && npm install && npm run dev
```

Open `http://localhost:5173`. MetaMask: point to `localhost:8545`, chain ID `31337`.

The UI auto-airdrops 10 ETH to your wallet on first connect via `anvil_setBalance`.

---

## Switching Scenarios

URL routing:

| URL | Scenario |
|---|---|
| `http://localhost:5173` | Clawloan Credit (default) |
| `http://localhost:5173?scenario=dms` | Dead Man's Switch |
| `http://localhost:5173?scenario=orchestration` | Sub-agent Orchestration |
| `http://localhost:5173?role=keeper` | Keeper Mode (separate wallet) |

The scenario nav tab at the top also switches between scenarios without a page reload.

**Important:** After running a scenario that warps time (Clawloan trigger, DMS trigger), subsequent scenario registrations correctly use on-chain `block.timestamp` as the base for deadlines — not wall-clock time. If you restart Anvil, redeploy before using the UI.

---

## Running Tests

```bash
# Foundry: all unit + integration tests
forge test -v

# SDK hash parity + encoding tests
cd sdk && npm test

# Fork tests (requires ARBITRUM_RPC_URL)
ARBITRUM_RPC_URL=<url> forge test --match-path "test/fork/*" -v
```

---

## Project Structure

```
contracts/
  Types.sol                    — Position, Capability, Intent, Envelope, Conditions
  HashLib.sol                  — EIP-712 type hashes (single source of truth for SDK + contracts)
  SingletonVault.sol           — hash-commitment asset vault
  CapabilityKernel.sol         — 18-step verification + execution coordinator
  EnvelopeRegistry.sol         — oracle-gated conditional pre-commitment store
  ReceiptAccumulator.sol       — per-capability execution receipt log
  CreditVerifier.sol           — ZK-proof-gated credit tier assignment
  adapters/
    ClawloanRepayAdapter.sol   — Clawloan debt repayment (static + live-debt modes)
    DirectTransferAdapter.sol  — Treasury failsafe: transfer to beneficiary (Dead Man's Switch)
    UniswapV3Adapter.sol       — Uniswap v3 swap adapter
  interfaces/
    IAdapter.sol               — quote / validate / execute interface
  verifiers/
    HonkCircuit1Verifier.sol   — UltraHonk verifier for compliance ZK proof

test/mocks/
  MockERC20.sol
  MockClawloanPool.sol
  MockTimestampOracle.sol
  MockCircuit1Verifier.sol
  MockSubAgentHub.sol          — Orchestrator budget ledger (Phase 3)

script/
  DeployClawloanDemo.s.sol     — full demo stack (all 3 scenarios)

sdk/src/
  types.ts / eip712.ts / builders.ts / signing.ts / position.ts / adapters.ts

circuits/
  circuit1/                    — Noir ZK circuit: compliance proof (receipts → tier upgrade)

ui/src/
  App.tsx                      — scenario router + Phase 1 Clawloan flow
  scenarios/
    DeadMansSwitchScenario.tsx — Phase 2: full DMS flow
    SubAgentScenario.tsx       — Phase 3: orchestrator + 2 sub-agents
  components/
    ScenarioNav.tsx            — tab navigation between scenarios
    LenderPanel.tsx            — lender economics + key-compromise invariant (Phase 1)
    HeroSection.tsx            — investor pitch card
    TierUpgradeOverlay.tsx     — credit tier upgrade animation
    KeeperNetworkPanel.tsx     — live keeper network visualization
    KeeperModeView.tsx         — separate keeper perspective (localStorage bridge)
    WithoutAtlasCard.tsx       — "what breaks without Atlas" explainer
    InvestorBriefModal.tsx     — full investor brief
  contracts/
    addresses.ts               — deployed addresses (VITE_ADDR_* overrideable)
    abis.ts                    — viem ABIs + all custom errors for simulateContract
  hooks/useChainState.ts       — wagmi multi-read hook (debt, vault, credit tier, receipts)
```

---

## Security Properties Demonstrated

| Property | Mechanism |
|---|---|
| Liveness independence | Envelope registered once; keeper triggers without agent key or signature |
| Keeper cannot manipulate conditions | Conditions committed as hash at registration; oracle read on-chain at trigger |
| Keeper cannot modify intent | Intent committed as hash; full preimage must match exactly at trigger |
| Key-compromise bounded | Capability `maxSpendPerPeriod` caps maximum attacker extraction to the period limit |
| Beneficiary cannot be redirected | Beneficiary encoded in EIP-712 intent hash at envelope creation; modifying it invalidates agent sig |
| No double-execution | Nullifier = `keccak256(nonce, positionCommitment)` marked spent on first execution |
| Sub-agent budget isolation | `MockSubAgentHub.recordBorrow()` reverts if agent's allocation is exceeded |
| Reentrancy protection | `ReentrancyGuard` on Vault, Kernel, and Registry |
| Emergency exit always available | `vault.emergencyWithdraw()` bypasses encumbrance; callable even when paused |

---

## Known Limitations (Phase 1)

- `delegationDepth` must be 0 — on-chain sub-delegation enforced at kernel level from Phase 2
- `submitter` must be registry or `address(0)` — no open solver market yet
- `MockTimestampOracle` returns `block.timestamp`; production uses Chainlink
- `MockSubAgentHub` enforces orchestrator budget at application layer; Phase 2 enforces via `parentCapabilityHash` chain on-chain
- `DirectTransferAdapter` retains 1 dust unit (1 micro-USDC) as vault residual; production uses `returnTo = beneficiary` routing through vault
- ZK proof submission uses `MockCircuit1Verifier` (same interface as production UltraHonk verifier)

---

## Further Reading

| Document | Contents |
|---|---|
| `STRATEGY.md` | Full product strategy, threat model, roadmap, revenue model, competitive analysis |
| `EXTENSIONS.md` | Five phase-shift extensions: options protocol, strategy graphs, manipulation resistance, strategy NFTs, sustained conditions |
| `ATLAS_PROTOCOL.md` | Protocol specification |
| `WHITEPAPER.md` | Narrative overview and motivation |
| `SPEC.md` | Formal data type and function specification |
| `ZK_ARCHITECTURE.md` | Circuit 1 design (compliance proof) |
| `DECISIONS.md` | All architectural decisions with trade-offs |
| `AUDIT_PREP.md` | Audit readiness notes and full threat model |
