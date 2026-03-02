# Atlas Protocol: A Stateless Agent Authorization and Conditional Settlement Layer

**Version 1.0 — Draft for Review**
**February 2026**

---

> *"No agent signature can move more value than the capability bounds, regardless of whether the agent key is compromised, jailbroken, manipulated, or acting maliciously."*
>
> — Atlas Protocol Invariant

---

## Abstract

Atlas is a stateless agent authorization and conditional settlement protocol deployed on public EVM chains. It introduces a clean separation between four primitives that every existing protocol conflates: asset custody, agent identity, authorization scope, and execution enforcement. Assets are held in a singleton vault as UTXO-style hash commitments. Authorization is expressed as off-chain EIP-712 signed capability tokens that bind agents to hard, kernel-enforced constraints. Execution is performed by ephemeral CREATE2 executor contracts that hold no persistent state. Liveness-independent enforcement is achieved through pre-committed conditional execution envelopes that any keeper can trigger permissionlessly when conditions are satisfied.

The protocol's commitment model — positions as `keccak256(owner, asset, amount, salt)` commitments rather than account balances — is architecturally compatible with the Aztec note model and designed for direct migration to private execution: the commitment structure maps cleanly onto Aztec notes, requiring only a change to the hash function and proof system rather than a protocol redesign. A zero-knowledge compliance layer, specified in this paper, uses Noir circuits compiled to UltraHonk proofs and verified by Solidity contracts on-chain to provide compression, delegation compression, and portable compliance credentials — while being precise about what ZK cannot provide on a public EVM chain.

Atlas is not positioned as an improvement to existing delegation standards. It is a different layer: not the consent rail, but the enforcement rail. Wallet delegation (ERC-7710, ERC-7715) answers whether an agent is permitted to act. Atlas answers whether that action can happen reliably, safely, and with correct outcomes — even when the agent is offline, the network is adversarial, and MEV is actively extracting value.

---

## Table of Contents

1. Problem Statement
2. Design Principles
3. Architecture Overview
4. Core Data Structures
5. Execution Flows
6. Security Model and Formal Properties
7. Zero-Knowledge Layer
8. Derivatives and Settlement Extensions
9. Competitive Analysis
10. Application Layer: ClawLoan Reference Integration
11. Deployment and Phasing
12. Open Questions and Future Work
13. Conclusion

**Appendices**
- Appendix A: EIP-712 Type Hashes
- Appendix B: Phase 1 Core Operation Gas Costs
- Appendix B2: Protocol Constants (Phase 1, Locked)
- Appendix C: Circuit Constraint Budget Summary

---

## 1. Problem Statement

### 1.1 The Account-Agent Conflation

Every existing approach to on-chain agent authorization commits the same architectural error: it makes the agent the account.

ERC-4337 smart accounts bundle custody, identity, and logic into a single on-chain object. Session keys reduce scope but preserve the fundamental model: the account is the custody container, and authority over the account implies access to its contents. EIP-7702 allows an EOA to temporarily adopt smart contract code, reducing deployment friction, but leaves the account-centric custody model intact.

The consequences of this conflation are severe for autonomous AI agents:

**Compromise blast radius is proportional to custody value.** A compromised agent key on a smart account has access to everything in that account up to the session scope. There is no architectural separation between "what the agent is allowed to do" and "what the agent can do if it is adversarial."

**Agent rotation requires on-chain transactions.** Rotating an agent key on a smart account requires a transaction from the original key or a guardian. Under the Atlas model, a new capability token issued off-chain instantly voids the previous agent's authority — no transaction, no guardian, no timelock.

**Liveness-independent enforcement is architecturally impossible.** If the agent is offline when a stop-loss condition is met, nothing executes. The enforcement of a conditional instruction is coupled to agent liveness. For AI agents that can be rate-limited, killed, or compromised, this is a fundamental safety gap.

**Privacy migration requires complete redesign.** Account balance models (`balances[user]`) cannot be mapped to private note systems without replacing the entire custody architecture. A commitment-based model, by contrast, is structurally compatible with what private execution systems like Aztec require — both represent state as hash commitments over (asset, amount, owner) tuples, where spending a commitment requires revealing its preimage and providing a validity proof.

### 1.2 The Missing Layer

The agent infrastructure stack as it exists in February 2026 has identifiable gaps:

```
┌──────────────────────────────────────────────────────┐
│  Agent Identity / Discovery                           │  ERC-8004, ERC-8126
├──────────────────────────────────────────────────────┤
│  Multi-Agent Coordination                             │  ERC-8001
├──────────────────────────────────────────────────────┤
│  Delegation / Authorization                           │  ERC-7710, MetaMask MDT
├──────────────────────────────────────────────────────┤
│  Intent Execution                                     │  ERC-7521, ERC-7683
├──────────────────────────────────────────────────────┤
│  Custody Isolation                  ← UNADDRESSED    │
├──────────────────────────────────────────────────────┤
│  Liveness-Independent Enforcement   ← UNADDRESSED    │
├──────────────────────────────────────────────────────┤
│  Privacy Migration Path             ← UNADDRESSED    │
└──────────────────────────────────────────────────────┘
```

Each standard above explicitly defers the layers below it. ERC-7710 defers custody. ERC-7683 defers conditional enforcement. ERC-8001 defers execution mechanics. The gaps are not incidental — they reflect genuine unsolved problems, not scope decisions. Atlas addresses exactly these three gaps.

### 1.3 The AI Agent Threat Model

AI agents interacting with financial protocols face a threat model that is qualitatively different from human users:

- **They are hot keys on servers.** Compromise is a matter of when, not if.
- **They are not present continuously.** Conditional execution cannot depend on agent liveness.
- **They can be manipulated by adversarial inputs.** Jailbreaking, prompt injection, and model drift are live attack surfaces.
- **Their authority chains are deep.** An orchestrator delegates to analysts who delegate to execution agents. Each link in this chain is an attack surface.
- **They execute at machine speed.** A compromised agent can exhaust an authorization scope in milliseconds.

The correct response to this threat model is not better monitoring — it is architectural separation that makes the blast radius of any compromise bounded and deterministic regardless of agent behavior.

---

## 2. Design Principles

The following principles govern every design decision in the Atlas protocol. Where tradeoffs are required, these principles establish the priority ordering.

**1. Agents have zero on-chain footprint between actions.**
An agent is a signing key and a capability token. Nothing is deployed. Nothing is registered. An agent does not exist on-chain until it submits an intent, and leaves no persistent trace after execution except a spent nullifier.

*What "stateless" means precisely:* An agent's authorization to act is encoded entirely in an off-chain EIP-712 signed data structure (the capability token) held by the agent. No per-agent contract, storage slot, or registry entry exists on-chain before or after execution. The only on-chain state the agent's actions produce is (a) a nullifier in the kernel's `nullifierMap` and (b) a new position commitment in the vault — both of which are protocol-level state, not agent-level state. An agent can be created, given a capability, used, and fully decommissioned without any on-chain transaction other than the intent execution itself.

**2. Asset custody is separated from agent identity.**
Assets live in a singleton vault. Positions are tracked as hash commitments, not as `balances[userAddress]`. The vault has no concept of users. It knows only whether a commitment exists.

**3. Capabilities are scoped, expiring, revocable, and off-chain.**
Authorization is expressed as EIP-712 signed capability tokens. Revoking an agent requires one on-chain transaction from the issuer. No guardian. No timelock. No on-chain state per agent.

**4. Execution is atomic and ephemeral.**
Each intent deploys a CREATE2 executor, executes atomically, and the executor holds no persistent state. No leftover approvals. No lingering contracts.

**5. Enforcement does not require agent liveness.**
Envelopes are pre-committed conditional execution instructions. They fire permissionlessly via keepers when conditions are met — even when the agent is offline, compromised, or destroyed.

**6. The design ports directly to private execution.**
The commitment model is structurally compatible with the Aztec note model. When private execution is added, public commitments become private notes with ZK proofs of spend. No architectural redesign is required — only the hash function (keccak256 → Poseidon2) and proof system change.

**7. ZK is honest about what it delivers on a public chain.**
On a public EVM, ZK provides computation compression, proof-of-knowledge without full revelation, and portable compliance credentials. It does not provide private balances, private counterparties, or hidden execution history. Every ZK circuit in this protocol is specified with explicit statements of what is and is not hidden.

---

## 3. Architecture Overview

### 3.1 System Diagram

```
┌─────────────────────────────────────────────────────────────┐
│                        OFF-CHAIN                            │
│                                                             │
│   User Wallet                                               │
│       ├── signs ──► Capability Token (EIP-712)              │
│       │              └── grantee: Agent Key                 │
│       │              └── scope, expiry, nonce               │
│       │              └── constraints: maxSpend, adapters    │
│       │                                                     │
│   Agent Key (AI agent / hot key)                            │
│       └── signs ──► Intent (EIP-712)                        │
│                      └── positionCommitment                 │
│                      └── adapter + adapterData              │
│                      └── minReturn, deadline, nonce         │
│                                                             │
│   Solver (whitelisted at Phase 1; permissionless Phase 3)   │
│       └── picks up Intent + Capability → submits on-chain   │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                        ON-CHAIN                             │
│                                                             │
│   CapabilityKernel (UUPS proxy)                             │
│       ├── verify capability signature (issuer)              │
│       ├── verify intent signature (grantee)                 │
│       ├── verify all constraints                            │
│       ├── check nullifier not spent                         │
│       ├── deploy IntentExecutor (CREATE2)                   │
│       ├── mark nullifier spent                              │
│       └── emit IntentExecuted receipt                       │
│                                                             │
│   SingletonVault (UUPS proxy)                               │
│       ├── releases position assets to executor              │
│       ├── nullifies old commitment                          │
│       └── stores new commitment (output position)           │
│                                                             │
│   IntentExecutor (ephemeral, CREATE2, no storage)           │
│       ├── receives assets from vault                        │
│       ├── calls adapter                                     │
│       └── returns output to vault                          │
│                                                             │
│   Adapters (UniswapV3, AaveV3, ...)                         │
│       └── validate params + execute protocol interaction    │
│                                                             │
│   EnvelopeRegistry (UUPS proxy, Phase 2)                    │
│       └── permissionless keeper execution on condition met  │
└─────────────────────────────────────────────────────────────┘
```

### 3.2 The Four Separations

Atlas achieves four separations that no existing protocol implements simultaneously:

| Concern | Atlas | ERC-4337 | MetaMask MDT |
|---|---|---|---|
| Custody | SingletonVault (shared, commitment-based) | Smart account (per-user) | Smart account (per-user) |
| Identity | Signing key only, no on-chain presence | Account address | DeleGator address |
| Authorization | Off-chain capability token | On-chain session key | On-chain delegation |
| Enforcement | Kernel + ephemeral executor | Account code | Caveat enforcer bytecode |

These separations are not a feature list — they are the architectural consequence of treating each concern as a distinct primitive. When they are conflated (as in every alternative), a failure in any one dimension propagates to the others.

---

## 4. Core Data Structures

### 4.1 Position Commitment

The vault does not store balances. It stores hash commitments.

```solidity
struct Position {
    address owner;    // user's address — controls capability issuance
    address asset;    // ERC-20 token address
    uint256 amount;   // token amount (uint256, standard ERC-20 precision)
    bytes32 salt;     // user-chosen entropy, never reused
}

positionHash = keccak256(abi.encode(position));

mapping(bytes32 positionHash => bool exists)      public positions;
mapping(bytes32 positionHash => bool encumbered)  public encumbrances;
```

**Why UTXO-style commitments over account balances:**

The commitment model gives each position an independent lifecycle. Positions can be encumbered independently (one stop-loss per position, with no interference from parallel positions). They can be transferred by revealing the preimage and committing a new one with a different owner. They map structurally to Aztec private notes — the only difference is that the note is public and the spending proof is a signature rather than a ZK proof. When privacy is added in a later phase, the transition from `keccak256(position)` public commitments to `Poseidon2(position)` private note commitments requires no redesign of the surrounding protocol — only the hash function and the proof system change.

**Owner inclusion:** The `owner` field is included in the Phase 1 preimage. This simplifies revocation — the kernel can verify `capability.issuer == position.owner` directly from the revealed preimage without additional indirection. The privacy cost (the owner address is visible in calldata at spend time) is acceptable on a public EVM. In the ZK note migration (Phase 3+), the `owner` field is replaced by a derived spending key, removing the linkage.

**Salt entropy requirement:** The salt must be sampled uniformly at random from `[0, 2^256)`. Two positions with the same `(owner, asset, amount)` tuple but different salts produce different `positionHash` values. The SDK enforces this at the call site: `salt = crypto.getRandomValues(new Uint8Array(32))`.

**Direct user withdrawal (censorship resistance):** `vault.withdraw(position)` is callable directly by any address whose `position.owner` matches `msg.sender`. It requires only the position preimage — no agent signature, no capability, no keeper involvement. This is an unconditional escape hatch: even if all solvers and keepers are offline or hostile, the position owner can always recover their assets unilaterally. Encumbered positions cannot be withdrawn until the encumbrancing envelope expires or is cancelled — this is a user-chosen restriction, not a protocol-imposed one.

### 4.2 Capability Token

```solidity
struct Capability {
    address issuer;           // user granting authority
    address grantee;          // agent key receiving authority
    bytes32 scope;            // keccak256("vault.spend") | keccak256("envelope.manage")
    uint256 expiry;           // unix timestamp; checked against block.timestamp
    bytes32 nonce;            // prevents capability replay; revocation handle
    Constraints constraints;
}

struct Constraints {
    uint256 maxSpendPerPeriod;    // max token amount (in token units) per period; 0 = unlimited (skip period check)
    uint256 periodDuration;       // period length in seconds; 0 = no period limit (skip period check)
    uint256 minReturnBps;         // minimum acceptable amountOut / amountIn × 10000 (same-denomination swaps; see §4.2)
    address[] allowedAdapters;    // empty = all registered adapters permitted
    address[] allowedTokensIn;    // empty = all tokens permitted
    address[] allowedTokensOut;   // empty = all tokens permitted
}
```

Capability tokens are **never stored on-chain**. They exist as EIP-712 typed data structures signed by the issuer's wallet. The issuer's signature is the proof of authorization. The kernel verifies this signature on every `executeIntent` call.

**Capability scopes:**

| Scope | Permitted actions |
|---|---|
| `keccak256("vault.spend")` | Spend positions via adapter execution |
| `keccak256("vault.deposit")` | Create new positions (deposit on behalf) |
| `keccak256("envelope.manage")` | Register and cancel envelopes |
| `keccak256("solver.execute")` | Submit intents as a solver |

**`minReturnBps` semantics and cross-asset swaps:** `minReturnBps` enforces `amountOut / amountIn × 10000 ≥ minReturnBps`. This ratio is dimensionless only when `amountIn` and `amountOut` are in the same token denomination — e.g., USDC→USDC arbitrage, stablecoin swaps, or LST↔ETH rebalancing where near-parity is expected. For general cross-asset swaps (ETH→USDC, BTC→SOL), the ratio `amountOut / amountIn` is in mixed units and the constraint is not semantically interpretable as a slippage bound. **For cross-asset operations, `intent.minReturn` (absolute floor on `amountOut`) is the correct and enforced slippage control.** The `minReturnBps` field should be set to `0` (disabled) for cross-asset capabilities; the SDK enforces this by default for non-homogeneous token pairs and emits a warning when `minReturnBps > 0` is set on a capability whose `allowedTokensIn` and `allowedTokensOut` differ.

**Constraint enforcement:** All constraint checks are performed by the kernel before any asset movement. If any constraint is violated, the kernel emits `IntentRejected` and reverts — note that because the transaction reverts, this event is only observable via debug traces, not standard RPC logs; see §5.1 for full observability details. The full check sequence is specified in §5.1 (steps 5a–5n) and includes: revocation check → issuer/grantee signature verification → expiry check → scope check → adapter constraint check → token-in/token-out constraint check → period spend check → nullifier check → position existence check → encumbrance check → preimage integrity check. Revocation is checked first because it is the user's emergency abort path and must have the lowest latency to enforce.

*Terminology note — two distinct allowlists:* The protocol uses two separate token restriction mechanisms that must not be confused. (1) The **vault-level token allowlist** (`SingletonVault.tokenAllowlist`) is a protocol-wide security filter that excludes non-standard tokens (ERC-777, ERC-1363) from deposit entirely — this is enforced in `vault.deposit()`, not in the kernel constraint checks. (2) The **capability-level token constraints** (`Constraints.allowedTokensIn`, `Constraints.allowedTokensOut`) are per-capability fields that restrict which specific tokens *this agent* may trade — enforced in the kernel at steps 5h and 5i. These operate at different layers and serve different purposes: the vault allowlist is a protocol-wide security invariant; the capability token constraints are user-defined authorization scope.

**Revocation:** The issuer calls `kernel.revokeCapability(capability.nonce)`. This writes `revokedNonces[issuer][nonce] = true`. The storage cost is one `SSTORE` (~20,000 gas cold). All future intents referencing this capability fail immediately at the revocation check. Any in-flight intents included in the same block as the revocation transaction will revert. There is no revocation delay or grace period — revocation is instantaneous.

### 4.3 Sub-Capability (Delegation Chain)

```solidity
struct SubCapability {
    bytes32 parentCapabilityHash; // keccak256(abi.encode(parentCapability))
    address issuer;               // agent key re-delegating (grantee of parent)
    address grantee;              // downstream agent receiving authority
    bytes32 scope;                // must equal parent scope
    uint256 expiry;               // must be <= parent expiry
    bytes32 nonce;                // prevents sub-capability replay
    Constraints constraints;      // must be subset of parent constraints
    bytes32[] lineage;            // ordered chain of hashes from root to parent
}
```

**Constraint inheritance rules (enforced by kernel):**

```
subCap.constraints.maxSpendPerPeriod  ≤  parent.constraints.maxSpendPerPeriod
subCap.constraints.minReturnBps       ≥  parent.constraints.minReturnBps
subCap.constraints.periodDuration     ≥  parent.constraints.periodDuration  (tighter floor)
subCap.constraints.allowedAdapters    ⊆  parent.constraints.allowedAdapters
subCap.constraints.allowedTokensIn    ⊆  parent.constraints.allowedTokensIn
subCap.constraints.allowedTokensOut   ⊆  parent.constraints.allowedTokensOut
subCap.expiry                         ≤  parent.expiry
subCap.scope                          ==  parent.scope
```

Sub-capabilities form an ordered lineage. The kernel verifies `isRevoked` for every hash in `lineage` at execution time. Maximum chain depth is **8**, bounded to prevent gas-exhaustion attacks through deep delegation chains. The worst-case gas for lineage verification at depth 8 is approximately 8 × 2,100 gas (cold SLOAD per check) = ~16,800 gas.

**Period spending is tracked against the root capability hash.** This prevents aggregation attacks where an agent issues many sub-capabilities with individually small limits that collectively exceed the root's `maxSpendPerPeriod`. A delegation chain A→B→C→D shares a single spending counter anchored to `keccak256(abi.encode(A))`. No amount of sub-capability issuance can cause the aggregate spend to exceed A's limit.

**`periodDuration` and the period index:** At execution time the kernel resolves the root capability from `lineage[0]` and computes `periodIndex = block.timestamp / rootCapability.constraints.periodDuration`. The period bucket is always indexed against the root's period window — not the sub-capability's. The sub-capability constraint `subCap.periodDuration ≥ parent.periodDuration` is an inheritance guard: it prevents delegation from shortening the period window and thereby allowing more spending per unit time. It does not grant sub-capabilities independent spending counters. A sub-cap with `periodDuration = 7 days` delegated from a root with `periodDuration = 1 day` still has its spend debited from the root's daily counter.

### 4.4 Intent

```solidity
struct Intent {
    bytes32 positionCommitment; // position being spent (preimage revealed at execution)
    bytes32 capabilityHash;     // keccak256(abi.encode(capability))
    address adapter;            // adapter contract to route through
    bytes   adapterData;        // ABI-encoded adapter parameters
    uint256 minReturn;          // absolute floor on output amount (enforced by executor)
    uint256 deadline;           // unix timestamp; reverts if block.timestamp > deadline
    bytes32 nonce;              // intent-specific entropy (nullifier seed)
    address outputToken;        // expected output token address
    address returnTo;           // where to create output position (always vault)
}
```

Intents are signed by the capability grantee (the agent key) as EIP-712 typed data. The intent signature is the agent's authorization to proceed with this specific execution.

**Nullifier derivation:**
```
nullifier = keccak256(abi.encode(intent.nonce, intent.positionCommitment))
```

The nullifier is stored in `mapping(bytes32 => bool) public nullifiers` in the kernel. Once stored, the input position is simultaneously deleted from the vault. Replay protection is therefore doubly enforced: the nullifier mapping prevents re-execution of the same intent, and the position commitment is deleted preventing re-spend of the same position through any intent.

### 4.5 Envelope (Pre-Committed Conditional Execution)

```solidity
struct Envelope {
    bytes32 positionCommitment; // position this envelope encumbers
    bytes32 conditionsHash;     // merkle root of condition tree — private until trigger
    bytes32 intentCommitment;   // keccak256(abi.encode(intent)) — private until trigger
    bytes32 capabilityHash;     // capability that authorized envelope creation
    uint256 expiry;             // envelope expires; position unencumbered automatically
    uint256 keeperRewardBps;    // basis points of output transferred to triggering keeper
}
```

An envelope is a **cryptographic commitment to a future action**, not a live execution request. At registration time, the strategy is hidden: `conditionsHash` and `intentCommitment` are opaque hashes. At trigger time, the keeper reveals the preimages, the registry verifies the hashes match, evaluates conditions against live on-chain oracle state, and forwards the revealed intent to the kernel for execution.

**The privacy property:** The full condition tree — oracle addresses, thresholds, boolean operators, and strategy structure — is committed as a hash and never revealed until the moment of execution. This eliminates the front-running window that exists in all current conditional execution systems (Chainlink Automation, Gelato, Uniswap limit orders), which store conditions in plaintext at registration time. With Atlas, there is no window between "strategy known to MEV bots" and "strategy executed."

### 4.6 Composable Condition Tree

The `conditionsHash` in an envelope commits to the root of a Merkle-structured condition tree. The tree is evaluated by the keeper revealing a minimal satisfying path.

**Node types:**

```solidity
enum ConditionNodeType { LEAF_PRICE, LEAF_TIME, LEAF_VOLATILITY, LEAF_ONCHAIN, COMPOSITE }

struct PriceLeaf {
    address oracle;       // Chainlink / Pyth / custom price feed
    address baseToken;
    address quoteToken;
    uint256 threshold;    // price × 1e8 (Chainlink convention)
    ComparisonOp op;      // LESS_THAN | GREATER_THAN | EQUAL | LESS_THAN_OR_EQUAL | ...
}

struct TimeLeaf {
    uint256 threshold;    // unix timestamp or modulo value
    ComparisonOp op;
    bool modulo;          // if true: check (block.timestamp % moduloBase) op threshold
    uint256 moduloBase;   // e.g., 604800 for weekly recurrence
}

struct VolatilityLeaf {
    address oracle;       // realized volatility oracle (e.g., Volmex, custom TWAP-variance)
    address asset;
    uint256 windowSecs;   // lookback window
    uint256 threshold;    // annualized vol × 1e4 (e.g., 8000 = 80%)
    ComparisonOp op;
}

struct OnChainStateLeaf {
    address target;       // contract to call (must be in protocol allowlist)
    bytes4  selector;     // view function returning uint256
    uint256 threshold;
    ComparisonOp op;
}

struct CompositeNode {
    BoolOp   op;          // AND | OR
    bytes32  leftHash;    // keccak256(abi.encode(nodeType, nodeData))
    bytes32  rightHash;
}
```

**Tree commitment:**

Leaf hashes: `keccak256(abi.encode(ConditionNodeType.LEAF_PRICE, priceLeaf))`

Internal node hashes: `keccak256(abi.encode(ConditionNodeType.COMPOSITE, compositeNode))`

The envelope stores only the root hash. The full tree is never on-chain.

**Keeper revelation:** At trigger time, the keeper submits a `ConditionProof` — the minimal subtree proving the root evaluates to `true`. For an `OR` node, only the true branch needs to be revealed; the false branch's hash is left as an opaque commitment, remaining permanently private. For an `AND` node, both branches must be revealed. This selective revelation provides partial privacy that is preserved even after execution — false branches of OR nodes are never disclosed.

**Gas scaling:** Condition verification cost scales with the number of *revealed* nodes in the satisfying path, not total tree size. A 16-leaf balanced OR tree where only 2 conditions must be true costs approximately 28,000 gas (2 oracle calls + hash verifications) — not 16 × 15,000.

| Tree structure | Revealed nodes | Oracle calls | Approximate gas |
|---|---|---|---|
| Single leaf | 1 | 1 | ~15,000 |
| AND(leaf, leaf) | 2 | 2 | ~28,000 |
| OR(leaf, leaf) — one branch true | 1 | 1 | ~18,000 |
| AND(OR(leaf, leaf), leaf) | 2–3 | 2–3 | ~40,000 |
| Depth-4 balanced tree (satisfying path) | 4–8 | 4–8 | ~80,000–120,000 |

Maximum tree depth: **8** (protocol constant, governance-adjustable). Maximum depth bounds worst-case gas and prevents unbounded condition tree construction.

### 4.7 Dead Man's Switch Envelope

An inverse envelope that fires when a condition *stops* being maintained — the first on-chain liveness enforcement primitive that requires no third party.

```solidity
struct DeadManEnvelope {
    bytes32 positionCommitment;   // position this envelope encumbers
    bytes32 intentCommitment;     // keccak256(abi.encode(intent)) — revealed at trigger
    bytes32 capabilityHash;       // capability that authorized envelope creation
    uint256 heartbeatInterval;    // max seconds allowed between keepalive calls
    uint256 lastHeartbeat;        // timestamp of most recent keepalive (updated on-chain)
    address heartbeatAuthorizer;  // address allowed to send keepalive (agent key or user)
    uint256 expiry;               // envelope expires if not triggered before this
    uint256 keeperRewardBps;      // basis points of output given to keeper on trigger
}
```

**Lifecycle:** The agent (or user) calls `keepalive(envelopeHash)` at intervals shorter than `heartbeatInterval`. Any keeper can trigger by proving `block.timestamp - lastHeartbeat > heartbeatInterval`. The keeper receives the standard reward; the silence is the trigger condition.

**Use cases:** Emergency portfolio liquidation if an agent goes offline for 72 hours. Estate transfer if a user fails to heartbeat for 30 days. Infrastructure liveness enforcement ("if my server stops signaling, sell everything and return to user address"). This is the only protocol primitive that turns *silence* into an enforceable action.

### 4.8 Conditional Capability

A capability that is only active when an external oracle condition holds. Collapses "is the agent authorized?" and "is the market condition right?" into a single verifiable object.

```solidity
struct ConditionalCapability {
    Capability capability;            // the underlying capability (constraints, scope, expiry)
    Conditions activationCondition;   // oracle condition that must be TRUE for capability to be active
    // If activationCondition.oracle == address(0), the capability is unconditionally active
    // Same Conditions struct as Envelope — identical oracle evaluation path
}
```

**Kernel check:** At `executeIntent` time, if `activationCondition.oracle != address(0)`, the kernel evaluates the oracle condition. If false, the kernel emits `IntentRejected` with reason `CAPABILITY_NOT_ACTIVE` and reverts. The capability is not revoked — it will be active again when market conditions change. As with all `IntentRejected` emissions, the event is not visible in standard `eth_getLogs` because the transaction reverts; use `simulateIntent()` for monitoring (see §5.1 observability note).

**Use cases:** "Yield optimizer only authorized during low-volatility regimes." "High-limit capability activates only when BTC dominance > 60%." "Emergency sell capability activates only after agent has been silent 48 hours" (combined with Dead Man's Switch heartbeat oracle). These enable regime-sensitive authorization — risk management enforced at the protocol level, not the AI level.

### 4.9 M-of-N Consensus Intent

An intent requiring signatures from M of N pre-authorized agent keys before the kernel executes. Eliminates single-agent-as-single-point-of-failure for high-value operations.

```solidity
struct ConsensusPolicy {
    uint256 requiredSignatures;   // M — minimum signatures required
    bytes32 approvedSignerRoot;   // Merkle root of approved agent key set
    uint256 signatureWindowSecs;  // all M signatures must be collected within this window
}

// Off-chain accumulation: solver collects M signatures before submission
struct ConsensusBundle {
    Intent        intent;
    ConsensusPolicy policy;
    Capability[]  signerCapabilities;   // one per signer
    bytes[]       capSigs;             // one signature per capability
    bytes[]       intentSigs;          // one signature per signer over intent
    bytes32[][]   merkleProofs;        // one Merkle proof per signer (inclusion in approvedSignerRoot)
}
```

**Kernel verification:** Verifies M capability signatures, M intent signatures, M Merkle membership proofs, and that all signatures fall within `signatureWindowSecs` of each other. Applies the *most restrictive* constraint intersection across all M capabilities. Calldata scales O(M) in the non-ZK path; Circuit 4 compresses this to O(1).

**Security property:** Compromising M independent agent systems simultaneously is orders of magnitude harder than single-agent compromise. With M=3 and independent models/providers/contexts, coordinated manipulation approaches the complexity of compromising independent key infrastructure.

### 4.10 TWAP Leaf (Manipulation-Resistant Price Condition)

A leaf condition that evaluates a time-weighted average price rather than a spot price. Available as an extension to the base `PriceLeaf` for positions above protocol-defined size thresholds.

```solidity
struct TWAPLeaf {
    address twapOracle;    // Uniswap V3 OracleLibrary, Chainlink TWAP, or Atlas TWAP Registry
    address baseToken;
    address quoteToken;
    uint32  windowSecs;    // lookback window (min: 60s, max: 86400s; governance-adjustable)
    uint256 threshold;     // price × oracleDecimals
    ComparisonOp op;
}
```

The oracle must be registered in the `AtlasTWAPRegistry` (governance-controlled allowlist). At evaluation time, the registry reads the TWAP value and compares it to `threshold`. A single-block manipulation attack cannot move a TWAP — the attack cost scales with `(required_deviation × windowSecs × pool_liquidity)`. SDK enforces minimum TWAP windows based on position size: positions > $100k require at least a 5-minute TWAP; positions > $1M require at least a 1-hour TWAP.

### 4.11 Nullifier and EIP-712 Domain

**EIP-712 Domain Separator:**

```solidity
DOMAIN_SEPARATOR = keccak256(abi.encode(
    keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
    keccak256("Atlas Protocol"),
    keccak256("1"),
    block.chainid,
    address(kernel)         // verifyingContract is always the CapabilityKernel
));
```

The `verifyingContract` is bound to the `CapabilityKernel` address. Cross-chain replay of a capability signed for Base against an Arbitrum deployment is prevented by the `chainId` field. If the kernel is ever redeployed (UUPS upgrade to new address), all existing capability tokens are automatically invalidated — this is intentional. Redeployment produces a clean authorization slate.

**All contracts share the same address across chains via CREATE2:**

```
deploymentSalt = keccak256("atlas-protocol-v1")
```

Address determinism enables consistent contract addresses across chains, allowing the SDK to derive addresses without an RPC call. Note: the EIP-712 domain separator is intentionally *different* across chains — it includes `chainId`, producing a distinct separator per chain and preventing cross-chain capability replay. A capability signed for Base cannot be replayed against an Arbitrum deployment even if the kernel address is identical. What is consistent across chains is the `verifyingContract` *address*, simplifying SDK configuration and user experience.

---

## 5. Execution Flows

### 5.1 Direct Intent Execution

```
1. User: sign Capability { issuer, grantee: agentKey, scope, expiry, nonce, constraints }
2. User: vault.deposit(asset, amount, salt)
         → positionHash = keccak256(owner, asset, amount, salt)
         → positions[positionHash] = true
         → emit PositionCreated(positionHash, asset, amount)

3. Agent: sign Intent { positionCommitment, capabilityHash, adapter, adapterData,
                        minReturn, deadline, nonce, outputToken, returnTo }

4. Solver: kernel.executeIntent(position, capability, intent, capSig, intentSig)

5. Kernel verification sequence:
   a. revokedNonces[capability.issuer][capability.nonce] == false
   b. ecrecover(keccak256("\x19\x01" || DOMAIN_SEPARATOR || capabilityHash), capSig) == capability.issuer
   c. ecrecover(keccak256("\x19\x01" || DOMAIN_SEPARATOR || intentHash), intentSig) == capability.grantee
   d. block.timestamp <= capability.expiry
   e. block.timestamp <= intent.deadline
   f. capability.scope == keccak256("vault.spend")
   g. intent.adapter ∈ capability.constraints.allowedAdapters
   h. position.asset ∈ capability.constraints.allowedTokensIn
   i. intent.outputToken ∈ capability.constraints.allowedTokensOut
   j. if (rootCap.constraints.periodDuration > 0 && rootCap.constraints.maxSpendPerPeriod > 0):
         periodIndex = block.timestamp / rootCap.constraints.periodDuration
         periodSpending[rootCapHash][periodIndex] + amount <= maxSpendPerPeriod
      // periodDuration == 0 or maxSpendPerPeriod == 0: skip period check (unlimited)
   k. nullifiers[keccak256(intent.nonce, intent.positionCommitment)] == false
   l. vault.positionExists(intent.positionCommitment) == true
   m. vault.isEncumbered(intent.positionCommitment) == false
   n. keccak256(abi.encode(position)) == intent.positionCommitment  (preimage check)

6. Kernel state mutations (all in one transaction, atomic):
   a. nullifiers[nullifier] = true                              // ← EFFECT: written first
   b. if (rootCap.constraints.periodDuration > 0 && rootCap.constraints.maxSpendPerPeriod > 0):
         periodSpending[rootCapHash][periodIndex] += amount     // ← EFFECT
   c. executorAddress = precompute CREATE2 address (salt = keccak256(nonce, positionCommitment))
   d. deploy IntentExecutor at executorAddress via CREATE2      // ← DEPLOY before token transfer
   e. vault.release(positionCommitment, position, executorAddress)
      → positions[positionCommitment] = false                   // ← EFFECT: position deleted
      → SafeERC20.transfer(position.asset, executorAddress, position.amount)  // ← INTERACTION last

7. IntentExecutor.execute():
   a. IERC20(tokenIn).approve(adapter, amountIn)
   b. amountOut = adapter.execute(tokenIn, tokenOut, amountIn, minReturn, adapterData)
   c. require(amountOut >= intent.minReturn, "MIN_RETURN_NOT_MET")
   d. IERC20(tokenIn).approve(adapter, 0)                       // revoke residual approval
   e. SafeERC20.transfer(outputToken, vault, amountOut)
   f. outputSalt = keccak256(abi.encode(intent.nonce, "atlas-output-v1"))
      vault.commit(outputToken, amountOut, position.owner, outputSalt)
      → newPositionHash = keccak256(owner, outputToken, amountOut, outputSalt)
      → positions[newPositionHash] = true
      → emit PositionCreated(newPositionHash, outputToken, amountOut)
      // outputSalt is derived deterministically from intent.nonce to ensure uniqueness
      // per intent and reproducibility off-chain without a separate random draw.
   g. selfdestruct(address(0))                                  // zero-ETH selfdestruct in same tx
      // EIP-6780: selfdestruct clears contract storage and code when called within the same
      // transaction as deployment. The executor is always deployed and destroyed in a single
      // transaction, satisfying the EIP-6780 same-tx condition.

8. Kernel: emit IntentExecuted(nullifier, positionIn, positionOut, adapter, amIn, amOut, receiptHash)
```

**Atomicity guarantee:** Steps 6–8 are a single transaction. Either the entire execution succeeds and the output position is committed, or the transaction reverts and the input position remains intact.

**Checks-Effects-Interactions (CEI) analysis:** The kernel follows strict CEI ordering within `executeIntent`:
- *Checks* (steps 5a–5n): all signature, constraint, nullifier, and preimage verifications complete before any state change.
- *Effects* (steps 6a–6e partial): nullifier is set (6a), period counter is updated (6b), executor is deployed (6d), and the input position is deleted from the vault (6e: `positions[positionCommitment] = false`) — all before the first token transfer.
- *Interactions* (steps 6e token transfer onward): `SafeERC20.transfer` and the executor call occur only after all state mutations that could affect re-entry paths are complete. Because the nullifier is set and the position is deleted before any token movement, a reentrancy attempt (e.g., via an ERC-777 `tokensReceived` hook on the executor) cannot re-execute the same intent (nullifier blocks it) or double-spend the same position (already deleted). The executor itself is deployed before the token transfer (step 6d precedes 6e transfer), so the tokensReceived hook, if any, fires into already-deployed executor code rather than an empty address, making the code path deterministic.

**`outputSalt` derivation:** The output position salt is `keccak256(abi.encode(intent.nonce, "atlas-output-v1"))`. This is deterministic: given a known `intent.nonce`, any party can reproduce the output `positionHash` off-chain without extra communication. Because `intent.nonce` is unique per intent (replay protection requires it), the output salt is unique per execution, preventing output commitment collisions even for identical `(owner, outputToken, amountOut)` tuples.

**`receiptHash` derivation:** The `IntentExecuted` event emits a `receiptHash` used as a private input to the Circuit 1 selective disclosure proof:
```
receiptHash = keccak256(abi.encode(
    nullifier, positionIn, positionOut, adapter, amountIn, amountOut, block.timestamp
))
```
This binds the execution parameters to a specific block timestamp on-chain. **Phase 1 (before receipt accumulator):** the `receiptHash` is emitted as an on-chain event, but the compliance circuit cannot verify its inclusion — receipts are self-attested private inputs and a prover could, in principle, fabricate consistent but fictitious ones. **Phase 2 (after receipt accumulator):** the circuit proves each `receiptHash_k` is a leaf in the `receiptAccumulatorRoot` public input, making fabrication cryptographically impossible — see §7.3.

**`block.timestamp` precision and manipulation:** Ethereum PoS validators can adjust the timestamp of a block they propose within the protocol-allowed range. Under current Ethereum consensus rules, a timestamp is valid as long as it is strictly greater than the parent block's timestamp and is not more than 15 seconds in the future relative to the validator's wall clock. In practice, the manipulation window is approximately ±6–12 seconds. For `receiptHash` integrity, this window is inconsequential — the hash is a binding of execution parameters and is not used to make period-bucketing decisions (that uses `r_k.timestamp` in the ZK circuit, which is the same value). **Period boundary edge case:** An execution that lands within 12 seconds of a period boundary could be bucketed in the adjacent period by a validator who nudges the timestamp. This is a known, bounded limitation. Recommended mitigation: set `periodDuration ≥ 3,600 seconds` (1 hour) so that any manipulation window is at most 0.33% of a period, and set `intent.deadline` conservatively (at least 60 seconds before the desired period boundary closes) for intents near period boundaries.

**`intent.nonce` — security property vs. privacy property:** `intent.nonce` serves dual roles that must be explicitly distinguished:
- *Security:* The nullifier `keccak256(intent.nonce, intent.positionCommitment)` is written to the nullifier registry before any asset movement. A replayed intent with the same nonce produces the same nullifier, which is already set, causing an immediate revert. This is a *hard security property* — replay is impossible regardless of attacker capability.
- *Privacy:* If nonces are sequential (0, 1, 2...), an observer can correlate all intents from the same agent and infer the agent's total execution count. If nonces are uniformly random 256-bit values, this correlation is impossible. Nonces **must** be sampled from a cryptographically secure random source (`crypto.getRandomValues` or equivalent). Sequential nonces violate the privacy guarantee even though they preserve the security guarantee.

**`simulateIntent()` view function interface:**
```solidity
/// @notice Dry-run the full executeIntent check sequence without state changes.
/// @return success  true if the intent would execute successfully
/// @return reason   keccak256 of the rejection key, or bytes32(0) on success
/// @return spentThisPeriod  current period spend for the root capability (useful for period limit checks)
function simulateIntent(
    Position calldata position,
    Capability calldata capability,
    Intent calldata intent,
    bytes calldata capSig,
    bytes calldata intentSig
) external view returns (bool success, bytes32 reason, uint256 spentThisPeriod);
```
Agents and solvers MUST call `simulateIntent` before broadcasting `executeIntent` to avoid wasted gas on predictable rejections. This function replicates all checks in §5.1 steps 5a–5n (including the signature recovery) but performs no state mutations and emits no events.

**`IntentRejected` event — observability caveat:**
```solidity
event IntentRejected(
    bytes32 indexed capabilityHash,
    address indexed grantee,
    bytes32 reason,           // keccak256 of error key e.g. keccak256("PERIOD_LIMIT_EXCEEDED")
    uint256 spentThisPeriod,
    uint256 periodLimit
);
```
**Important:** Because `executeIntent` always reverts when a constraint is violated, the `IntentRejected` event is emitted inside a reverted transaction. Ethereum's EVM does not include logs from reverted transactions in the standard `eth_getLogs` / `eth_getTransactionReceipt` response — the event will NOT appear in standard RPC event queries. It IS observable via `debug_traceTransaction` (which captures the full execution trace including pre-revert logs) and via `eth_call` simulation (which can return the event as part of a dry-run). For production agent monitoring, the recommended pattern is: (1) call `kernel.simulateIntent(position, capability, intent, capSig, intentSig)` — a view function that replicates the full check sequence and returns `(bool success, bytes32 reason, uint256 spentThisPeriod)` as return values rather than events; (2) use the `IntentRejected` event only for debug-trace-based analytics pipelines, not as a real-time monitoring primitive. The ~3,000 additional gas emitted per rejection in simulation is justified by the auditability guarantee it provides in debug tooling.

### 5.2 Envelope Trigger (Keeper Execution)

```
1. Agent: pre-compute conditionsHash = root_hash(conditionTree)
          pre-sign Intent (same structure as §5.1)
          intentCommitment = keccak256(abi.encode(intent))

2. Agent: envelopeRegistry.register(envelope, capability, capSig, intentSig)
          → vault.encumber(positionCommitment)
          → envelopes[envelopeHash] = envelope

3. Keeper: monitors oracle conditions off-chain
           conditions become true at block N

4. Keeper: envelopeRegistry.trigger(envelopeHash, conditionProof, intent)
   Registry verification:
   a. verifyConditionProof(envelope.conditionsHash, conditionProof)
      — walks the revealed proof path bottom-up
      — re-reads all oracle values from on-chain state (not from keeper-provided data)
      — recomputes all node hashes and verifies root matches conditionsHash
   b. keccak256(abi.encode(intent)) == envelope.intentCommitment
   c. block.timestamp < envelope.expiry
   d. vault.unencumber(positionCommitment)
   e. forward intent to kernel.executeIntent(...)
   f. transfer keeperRewardBps of output to msg.sender

5. Agent was offline the entire time. Execution fired correctly.
```

**Oracle re-read guarantee:** The registry re-reads all oracle values from on-chain state at trigger time. The keeper cannot provide forged oracle values — they are not inputs to the trigger call; they are read directly from the oracle contracts. A keeper cannot trigger an envelope by claiming a false price; the condition check uses the actual oracle state in the same block as the trigger transaction.

### 5.3 Agent Revocation

```
1. User: kernel.revokeCapability(capability.nonce)
         → revokedNonces[msg.sender][nonce] = true
         → emit CapabilityRevoked(msg.sender, nonce)

Result: All future intents referencing this capability hash revert at step 5a.
        In-flight intents in the same block: if included after the revocation tx, revert.
        If included before: succeed (consistent with standard EVM ordering semantics).
        Keeper-held envelope intents: revert on next trigger attempt.
        No guardian required. No timelock. One transaction.
```

---

## 6. Security Model and Formal Properties

### 6.1 Protocol Invariants

The following properties hold unconditionally for any valid execution through the Atlas protocol. They are enforced by contract code and do not depend on the honesty of any off-chain party.

**I1 — Spend Authenticity:**
A position can be spent only if the spending transaction includes a valid EIP-712 capability signature from `position.owner` and a valid intent signature from the capability's `grantee`. Formally: for any spent position P, there exist signed messages `capSig` and `intentSig` such that `ecrecover(capHash, capSig) == P.owner` and `ecrecover(intentHash, intentSig) == capability.grantee`.

**I2 — Constraint Supremacy:**
No intent can cause `amountSpent > capability.constraints.maxSpendPerPeriod` within any single period. No intent can reference an adapter not in `capability.constraints.allowedAdapters`. No intent can produce a return ratio `amountOut / amountIn < minReturnBps / 10000`. These constraints are enforced by the kernel before any asset movement. The agent cannot bypass them regardless of what data it signs.

**I3 — Nullifier Uniqueness:**
Each `(intent.nonce, intent.positionCommitment)` pair can produce at most one execution. The nullifier is written before `vault.release()` is called, preventing reentrancy-based re-execution. The input position is deleted from the vault simultaneously, preventing double-spend through a different intent.

**I4 — Output Preservation:**
The total token value entering a `vault.release()` call equals the total token value committed back via `vault.commit()`, minus the keeper reward. No value is created or destroyed. Formally: `amountOut_committed + keeperReward == amountIn_released` (modulo gas costs paid by the solver, not the vault).

**I5 — Encumbrance Exclusivity:**
A position encumbered by an envelope cannot be spent by a direct intent and cannot be encumbered by a second envelope simultaneously. The `encumbrances` mapping enforces mutual exclusion at the vault level.

**I6 — Delegation Monotonicity:**
Sub-capability constraints are always a subset (never a superset) of parent constraints. An agent cannot grant a downstream agent more authority than it was granted. The kernel enforces every constraint relationship in §4.3 before accepting a sub-capability chain.

### 6.2 Threat Analysis

#### 6.2.1 Compromised Agent Key

**Attack:** An attacker obtains the agent's signing key. They attempt to drain positions.

**Bound:** The attacker can only act within `capability.constraints.maxSpendPerPeriod` per period. With a period of 86,400 seconds and `maxSpendPerPeriod = 1,000 USDC`, the maximum loss is 1,000 USDC per day. The attacker cannot exceed this regardless of how many intents they submit — the kernel accumulates the period spend counter and rejects any intent that would exceed the limit.

**Mitigation:** User calls `kernel.revokeCapability(capability.nonce)`. From that block onward, the compromised key is worthless — it holds no authority and cannot reference the revoked capability.

**Comparison to ERC-4337 session keys:** A compromised session key on a smart account provides access to the full session scope until the account owner rotates the key — which requires a transaction from the master key or guardian, introducing a window during which the attacker can operate. Under Atlas, revocation is a single transaction from the user's wallet with no guardian requirement and no grace period.

#### 6.2.2 Solver/Executor Misbehavior

**Attack:** A whitelisted solver picks up an intent but delays submission, routes through an unfavorable path, or attempts to sandwich the execution.

**Bound:** `intent.minReturn` is an absolute floor enforced on-chain by the executor: `require(amountOut >= intent.minReturn)`. If the solver's routing produces less than `minReturn`, the transaction reverts. The `intent.deadline` prevents indefinite delay. Multiple solvers can race to fill the same intent — censorship by one solver does not prevent execution.

**MEV protection:** All execution is routed through Flashbots Protect bundles, which keep transactions in a private mempool and guarantee inclusion without exposure to the public transaction pool. This prevents front-running of the specific trade parameters because competing bots cannot observe `adapterData` contents before block inclusion. For higher-value executions, the `adapterData` field can be encrypted at the application layer to the target builder's public key — providing pre-trade privacy analogous to commit-reveal, without requiring threshold cryptography infrastructure. The `intent.minReturn` floor provides a guaranteed lower bound on output regardless of any MEV extraction that does occur.

#### 6.2.3 Vault Drain

**Attack:** An attacker constructs a capability claiming to be a position owner and attempts to drain positions.

**Defense:** The capability's `issuer` field must match `position.owner` from the revealed position preimage. The kernel verifies `capability.issuer == position.owner` before any release. An attacker who does not hold the position owner's private key cannot produce a valid `capSig` for a capability with the correct issuer address.

#### 6.2.4 Replay Attacks

**Attack:** An attacker replays a previously valid intent.

**Defense:** Three independent layers:
1. `nullifiers[nullifier] = true` — the nullifier is set before `vault.release()` executes.
2. `positions[positionCommitment] = false` — the input position is deleted simultaneously.
3. `intent.deadline` — expired intents revert regardless.

An intent cannot be replayed because its input position no longer exists after execution.

#### 6.2.5 CREATE2 Pre-Deployment Frontrun

**Attack:** An attacker front-runs the executor deployment by sending tokens to the pre-computed executor address before the intent transaction. The executor receives extra tokens not accounted for in the intent.

**Defense:** The executor address is pre-computed and `vault.release()` sends assets to it before the executor is deployed. Any tokens at the executor address before deployment are inert — the executor's `execute()` function only interacts with the specific asset and amount specified in the intent. Surplus tokens at the executor address cannot be extracted because the executor has no withdrawal function. When the intent transaction completes, the executor is an empty contract with no storage. Any frontrunner attempting this attack loses their tokens to the executor permanently.

#### 6.2.6 Oracle Manipulation (Envelope Triggers)

**Attack:** An attacker manipulates an oracle to force-trigger an envelope, executing a trade at an unfavorable price.

**Defense (TWAP leaves):** The condition evaluates against the 30-minute TWAP, not the spot price. A flash manipulation that moves the spot price for a single block does not affect the TWAP. The cost of sustaining a TWAP deviation long enough to trigger a condition is proportional to `(required_deviation × time_window × asset_liquidity)` — economically prohibitive for any liquid asset.

**Defense (N-block confirmation):** The condition must be true for N consecutive blocks before execution. A condition that flips true then false is noise — the N-block confirmation filters it out.

**Defense (oracle allowlist):** The `OnChainStateLeaf` selector must be in the protocol allowlist, preventing calls to arbitrary contracts that could enable reentrancy, gas griefing, or state manipulation during condition verification.

**Defense (dual-oracle design):** Every price condition evaluation uses both Chainlink and Pyth feeds. A stale round on either feed does not trigger — it delays. This handles four distinct failure modes as independent cases: chain halt (both feeds stale), depeg (one feed deviates), feed outage (one feed stops), and manipulation (one feed is pushed). An envelope that requires consensus between two independent oracle providers is substantially harder to manipulate than one relying on a single feed. The dual-oracle requirement is configurable at the envelope level; single-oracle is permitted for non-price leaf types.

#### 6.2.7 Aggregation Attack via Sub-Capabilities

**Attack:** An agent issues 100 sub-capabilities each with `maxSpendPerPeriod = 100 USDC`, collectively bypassing the root's `maxSpendPerPeriod = 500 USDC`.

**Defense:** Period spending is tracked against `keccak256(abi.encode(rootCapability))`, not against the sub-capability hash. All sub-capabilities in the chain read and update the same counter. When the root's period limit is hit, all sub-capabilities sharing that root are simultaneously blocked — regardless of how many exist or what individual limits they carry.

#### 6.2.8 Non-Standard Token Reentrancy (ERC-777 and Callback Tokens)

**Attack:** A user deposits a token that implements the ERC-777 `tokensReceived` hook (or ERC-1363 `onTransferReceived`). During `vault.release()`, the token transfer fires the hook on the executor, which could re-enter the vault, kernel, or envelope registry with adversarial calldata.

**Threat characterization:** The CEI ordering described in §5.1 provides the primary mitigation: the nullifier is set (step 6a) and the position is deleted (step 6e effect) before any token transfer occurs. A re-entrant call to `executeIntent` with the same intent will fail at the nullifier check. A re-entrant `vault.withdraw` for the same position will fail because `positions[positionCommitment]` is already false. The attack surface is therefore limited to: (a) re-entering *other* vault positions (positions unrelated to the current execution), (b) re-entering the `EnvelopeRegistry` during an active trigger, or (c) triggering state changes in adapters or the keeper reward logic.

**Primary defense — protocol-enforced token allowlist:** The `SingletonVault.deposit()` function checks `tokenAllowlist[asset] == true` before accepting any deposit. The allowlist is administered by the protocol multisig. ERC-777 tokens (`LSETH`, `imBTC`, legacy DeFi tokens), ERC-1363 tokens, and any token with non-standard transfer hooks are *excluded from the allowlist by default*. Standard ERC-20 tokens (`USDC`, `WETH`, `WBTC`, `DAI`, etc.) are included. Any new token listing requires a security review by the protocol multisig. This allowlist is a Phase 1 invariant and must be enforced from the first deployment.

**Defense depth:** Even if a token were mistakenly allowlisted while having callback hooks, the CEI ordering ensures the re-entrant call cannot produce a double-execution or double-spend of the triggering position. The residual risk is limited to cross-position interactions, which are mitigated by the vault's position-level isolation (each position is an independent commitment; spending one does not affect others).

#### 6.2.9 Keeper MEV: Front-Running, Suppression, and Reproof Costs

**Attack 1 — Reward front-running:** A keeper (K1) submits a valid `envelopeRegistry.trigger()` transaction when conditions are met. A MEV searcher (K2) observes K1's transaction in the public mempool, copies it with a higher gas price, and front-runs K1 to claim the keeper reward. K1's transaction reverts (the envelope has been triggered) and K1 bears the failed-transaction gas cost.

**Bound and mitigation:** This is economically equivalent to generalized MEV competition, not a protocol safety issue — the envelope executes correctly regardless of which keeper triggers it. The protocol mitigates the front-running cost: (1) **Flashbots Protect integration** — keepers are expected to submit trigger transactions through a private mempool (Flashbots Protect, bloXroute) to prevent mempool observation. Private-mempool submission eliminates the searcher's ability to copy and race the transaction. (2) **Keeper registration with priority tiers** (Phase 2) — a whitelist of registered keepers who receive first-mover priority for envelope triggers, with open fallback participation after a grace period. (3) `keeperRewardBps` must be set high enough to cover gas costs even if the keeper occasionally loses to front-running; the risk models for keepers should account for this probability.

**Attack 2 — Suppression (censorship past expiry):** A validator with malicious intent delays including a keeper's trigger transaction until `block.timestamp > envelope.expiry`, at which point the trigger reverts and the envelope expires without execution. The user's position remains encumbered until they call `unencumber` manually.

**Bound:** On Ethereum/Base PoS, a single validator controls at most one block (~12 seconds). Suppressing a transaction for longer requires coordination across multiple validators, which is economically and operationally costly. For envelopes with `expiry` set sufficiently far in the future (weeks rather than hours), single-block suppression is harmless. **Recommendation:** set `envelope.expiry` with at least 10 minutes of buffer beyond the expected trigger window. For long-horizon envelopes (stop-losses, take-profits), set `expiry` to match the position's holding horizon, not the trigger condition's immediacy.

**Attack 3 — Reproof cost (Circuit 3 only):** For envelopes using Circuit 3 (ZK condition tree proof), the keeper generates a proof when oracle conditions are met. If the oracle value changes between proof generation and block inclusion (e.g., price recovers before the trigger transaction lands), the on-chain verifier rejects the stale proof and the keeper must regenerate it. Each failed proof attempt costs the keeper gas for the reverted transaction plus the off-chain proving time (~5–15 seconds for Circuit 3). This is an economic cost, not a safety issue, but it increases the effective cost of keepering ZK-gated envelopes. **Mitigation:** keepers should only generate Circuit 3 proofs after confirming oracle conditions have been stable for at least 2 consecutive blocks, and should submit proofs as MEV bundles with condition-stability checks embedded in the bundle's validity constraints.

### 6.3 Attack Surface Summary

| Component | State held | Primary attack surface |
|---|---|---|
| SingletonVault | Position commitments, encumbrances | Custody isolation; cross-position leakage prevention |
| CapabilityKernel | Nullifiers, revoked nonces, period spend | EIP-712 signature verification; constraint enforcement correctness |
| IntentExecutor | None (ephemeral) | CREATE2 address collision; ERC-777/callback token hook (mitigated by token allowlist + deploy-before-transfer ordering) |
| Adapters | None | Parameter validation bypass; reentrancy on output transfer |
| EnvelopeRegistry | Envelope commitments | Oracle manipulation at trigger; condition hash preimage collision |

### 6.4 Formal Security Properties (Sketch)

A complete formal security proof is out of scope for this paper. The following properties are stated as targets for formal verification in Phase 2, using a game-based security model (similar to the UC framework [Canetti 2001] or the EVM-specific model used in Ethanos/SmartPulse). Each property corresponds to a security game in which a polynomial-time adversary attempts to break the property and is bounded by the hardness of ECDSA (secp256k1 DLP) and keccak256 collision resistance.

**Upgrade trust boundary:** The protocol invariants stated below hold for the deployed bytecode at any given block. Both `SingletonVault` and `CapabilityKernel` are UUPS proxies — an upgrade transaction from the protocol multisig can change the contract logic. The invariants therefore carry an implicit trust assumption: *the protocol multisig does not upgrade contracts to violate them*. The multisig is M-of-N with a 48-hour timelock on upgrades. Any upgrade that modifies nullifier uniqueness, custody conservation, or constraint enforcement requires a full audit re-engagement and public disclosure period before activation. Users who require stronger guarantees can use the non-upgradeable `IntentExecutorFactory` and `Adapter` contracts — these hold no custody state and have immutable bytecode.

**Conservation:** For any sequence of `deposit`, `executeIntent`, and `withdraw` calls, the total token balance held by the `SingletonVault` contract equals the sum of amounts in all active (unspent, not withdrawn) position commitments.

**Bounded authority:** For any agent key `A` holding capability `C`, the aggregate `amountIn` across all successfully executed intents within any contiguous time window of length `C.constraints.periodDuration` is at most `C.constraints.maxSpendPerPeriod`.

**Liveness of revocation:** For any capability `C` revoked at block `B`, no intent referencing `C` can be successfully executed in any block `B' >= B` (assuming standard EVM ordering where revocation and intent execution appear in the same block, the revocation transaction must precede the intent transaction to block it).

**Constraint monotonicity:** For any sub-capability chain `C_0 → C_1 → ... → C_k`, the effective constraint set applicable to `C_k` is the intersection (most restrictive element) of all constraints along the chain.

---

## 7. Zero-Knowledge Layer

### 7.1 What ZK Delivers on a Public EVM Chain

Before specifying circuits, precision is required about what ZK can and cannot provide on a public EVM. Overclaiming here is a disqualifying error.

**ZK provides on a public EVM:**

- **Proof of knowledge without full revelation.** An agent can prove it satisfied constraints across N historical executions without revealing the individual trade parameters (asset, amount, direction, counterparty, timing).
- **Computation compression.** O(N) on-chain constraint verification (adapter allowlist, period spend, return ratio across N intents) is replaced by O(1) SNARK proof verification. Nullifier membership verification achieves O(1) only once the on-chain nullifier accumulator and receipt accumulator are deployed (Phase 2 infrastructure); prior to that, nullifier checks require O(N) verifier storage reads.
- **Delegation chain compression.** O(depth) sub-capability lineage verification is replaced by a single proof that the chain is valid. The full lineage does not appear in calldata.
- **Signature aggregation.** M ECDSA signatures can be replaced by a single proof of M valid signatures, reducing O(M) calldata to O(1).
- **Portable compliance credentials.** A proof is a constant-size artifact that any verifier can check without access to the raw trade history.

**ZK does not provide on a public EVM:**

- **Private balances.** Position amounts are visible when deposited (`vault.deposit()` calldata) and when spent (preimage revealed in `executeIntent` calldata). Amount privacy requires a private execution environment (shielded pool, private L2). This is architecturally out of scope for the current protocol.
- **Private counterparties.** Transaction sender addresses are visible in all EVM calldata.
- **Hidden execution history.** Transactions are public. An observer can reconstruct execution history from on-chain events regardless of whether ZK proofs are used.

**What ZK does buy in the Atlas context:** The most valuable ZK capability for Atlas on a public EVM is the selective disclosure proof (Circuit 1) — an agent proves that a disclosed set of its executions satisfied its capability constraints, without revealing the individual trade parameters. This transforms execution history from a privacy liability (publishing all trades) into a compliance asset (portable, verifiable constraint adherence credential). The second most valuable capability is delegation chain compression: the full lineage of a depth-8 sub-capability chain (8 capability structs × ~500 bytes each = ~4 kB of calldata) is replaced by a ~2 kB proof and two public inputs.

### 7.2 Hash Function Decision

All Atlas circuits face a fundamental tension: the protocol uses `keccak256` on-chain for commitment hashing, but `keccak256` is expensive in arithmetic circuits.

**Constraint cost comparison (ACIR-level approximations):**
- `keccak256` in Noir (ACIR opcode count): ~10,000–15,000 gates per hash call
- `Poseidon2` in Noir (ACIR opcode count): ~100–150 gates per hash call

*Terminology note:* Throughout this section, "gates" refers to ACIR (Aztec Circuit Intermediate Representation) opcode counts as emitted by the Noir compiler. These are **not** identical to the prover constraint count in the UltraHonk backend — UltraHonk introduces a 2–5× expansion factor during ACIR-to-proving-key compilation, depending on gate type composition (arithmetic, range, lookup, custom). Proving times below are estimated against ACIR gate counts and should be treated as lower bounds; actual prover wall-clock time on commodity hardware may be 2–3× higher pending empirical Barretenberg benchmarks. Production deployment should be gated on measured performance, not ACIR estimates.

A circuit that verifies 100 position preimage hashes using `keccak256` requires approximately 1,000,000–1,500,000 ACIR gates. The same circuit using Poseidon2 requires ~10,000–15,000 ACIR gates — a ~100× reduction, consistent with measured Barretenberg benchmarks as of Noir 0.36.

The Phase 1 protocol uses `keccak256` everywhere on-chain. This is correct for Phase 1: it requires no new primitives, no trusted setup for the hash function, and produces position hashes that match what the EVM expects. The cost is borne later in the ZK layer.

**Three options for the ZK layer:**

| Option | Effort | Risk | Circuit cost |
|---|---|---|---|
| **A. keccak256 in circuits** | Zero (no on-chain changes) | Low | ~10,000 gates per hash — expensive but feasible for small N |
| **B. Poseidon2 in circuits + keccak256 on-chain (dual-hash bridge)** | Medium — bridge adds one indirection | Medium — bridge increases attack surface | ~100 gates per hash in circuit; keccak256 commitments remain on-chain |
| **C. Migrate on-chain commitments to Poseidon2** | High — breaking change; re-audit required | High — migration complexity | Cheapest circuits; cleanest design |

**Recommendation for Phase 2 ZK circuits:** Option B. The dual-hash bridge works as follows: the on-chain `positionHash = keccak256(position)` remains unchanged. Off-chain, the prover also computes `poseidonHash = Poseidon2(position)` over the same preimage. The circuit receives `poseidonHash` as a private input and `keccak256Hash` as a public input, and proves that both hash to the same preimage. This adds one keccak256 call per position commitment in the circuit (paying the ~10,000-gate cost once per position), after which all internal operations use Poseidon2. For a compliance proof over N=100 intents, the bridge adds 100 keccak256 calls (~1,000,000 gates) plus 100 Poseidon2 operations for the internal tree (~10,000 gates) — still approximately 10× cheaper than full keccak256 throughout.

**Byte-to-field-element encoding for the keccak256 bridge:** Noir circuits operate over the BN254 scalar field, whose prime is p ≈ 2²⁵⁴ + 4·2⁶⁴ + ... (strictly less than 2²⁵⁶). A raw 256-bit keccak256 output does not fit in a single BN254 field element. The canonical encoding splits the 32-byte hash into two 128-bit chunks:
```
lo_128 = hash[0:16]   as big-endian uint128  // lower 128 bits
hi_128 = hash[16:32]  as big-endian uint128  // upper 128 bits
```
Both values are in `[0, 2¹²⁸)` and fit comfortably in BN254 field elements. The bridge witness therefore consists of `(lo_128, hi_128)` — two field elements per keccak hash. The circuit verifies that `Poseidon2(preimage) == intended_poseidon_hash` while simultaneously constraining `keccak256(preimage) == (lo_128 << 128) | hi_128` (reconstructed from the two field elements). This encoding is consistent with the Noir standard library's `std::hash::keccak256` output representation and with the `aztec-packages` keccak gadget. Any off-chain prover generating bridge witnesses must split keccak outputs using this exact 128-bit split to produce matching field elements.

**Prior art for keccak256 in Noir circuits:** The keccak256 gadget used in Atlas circuits is not a novel construction — it relies on existing, audited implementations:
- **Noir standard library:** `std::hash::keccak256` in `aztec-packages` (MIT license) — the reference Barretenberg-native keccak opcode, used as-is.
- **Barretenberg native keccak backend:** The `bb` proving backend has a native keccak opcode (not ACIR-level emulation) for UltraHonk, which significantly reduces constraint count compared to a hand-rolled keccak in ACIR. Atlas circuits should use the native opcode path, not the ACIR emulation path, to achieve the ~10,000–15,000 gate estimate cited in this section.
- **zkEmail / circom-keccak (reference implementation):** The circom-keccak circuit by zkEmail (MIT license) provides an alternative constraint budget reference for comparison; it reports ~160,000 R1CS constraints for a single keccak256 invocation in Circom/Groth16, confirming that the Barretenberg native opcode is substantially more efficient.
These implementations should be cited in the production circuit specification and any future technical reports accompanying the Atlas ZK layer audit.

**Axis lock requirement for the bridge migration:**

Migration from option A to option B touches multiple independent axes and must be executed sequentially with a verification gate between each step:

1. **Axis 1:** Add Poseidon2 hashing to the circuit layer only. No on-chain changes. Gate: one complete prove-verify cycle succeeds with the bridge circuit.
2. **Axis 2:** Deploy bridge verifier contract. Test against existing keccak256 commitments. Gate: existing commitments resolve correctly through the bridge.
3. **Axis 3 (Phase 3, optional):** Migrate on-chain commitments to Poseidon2 natively. Gate: full prove-verify closure with new commitments. This requires a new vault deployment and a migration period.

Do not proceed to Axis 2 until Axis 1's gate passes. Do not combine axes.

### 7.3 Circuit 1: ZK Selective Disclosure Proof (Compliance Credential)

This is the most important circuit in the Atlas ZK layer. It is also the circuit for which ZK provides the clearest value proposition over the non-ZK alternative.

**Precise characterization — selective disclosure, not complete compliance audit:**

A critical distinction must be stated upfront. This circuit produces a *selective disclosure proof*: the prover demonstrates that a chosen set of N intents satisfied the capability constraints. It does **not** prove that *all* of the agent's historical executions were compliant. A dishonest agent could selectively omit non-compliant executions from the proof set.

This is not a design flaw — it is an accurate characterization of what a SNARK over a prover-chosen witness set can soundly assert. The credential is valuable precisely because: (1) the prover cannot fabricate compliant intents that never occurred on-chain (the nullifier membership check prevents this), and (2) the prover cannot falsify the constraint checks for included intents (the circuit enforces them). What the prover *can* do is choose which of their real intents to include. Verifiers should understand this as "the agent can prove compliance for any subset of its history it chooses to disclose."

**Path to complete compliance (requires Phase 2 infrastructure):** A complete compliance proof — one that covers *all* executions under a given capability — requires a per-capability nullifier accumulator: an on-chain or trust-minimized data structure that records every nullifier ever produced under a given `rootCapabilityHash`. Once this exists, the circuit can prove that the prover's disclosed nullifier set equals the complete capability nullifier set (not merely a subset of it). This is the target architecture for the institutional compliance credential use case. The per-capability accumulator design is an explicit prerequisite for the compliance credential claim and is tracked as Q2 in §11.

**The problem:** An AI agent operates on a user's behalf across hundreds of executions. A verifier (user, institution, or regulator) wants to verify that a disclosed set of the agent's historical executions satisfied capability constraints — without the agent revealing the individual trade parameters.

**Formal proof statement:**

> The prover knows a set of N intent preimages `{i_1, ..., i_N}` and N execution receipts `{r_1, ..., r_N}` such that:
> 1. For each `i_k`, the on-chain nullifier `keccak256(i_k.nonce, i_k.positionCommitment)` is a leaf in the capability-scoped nullifier Merkle tree with root `nullifierSetRoot`; equality between the keccak256 value and the circuit's internal Poseidon2 computation is verified via the dual-hash bridge witness
> 2. For each `i_k`, `i_k.adapter ∈ allowedAdapters` (constraint set committed in `capabilityKeccakHash`; the circuit derives the Poseidon2 constraints representation internally via the keccak256 bridge)
> 3. For each period `p`, `Σ{i_k : period(i_k) == p} i_k.amountIn ≤ maxSpendPerPeriod`
> 4. For each `i_k`, `r_k.amountOut / i_k.amountIn ≥ minReturnBps / 10000`
> 5. Each `receiptHash_k` is a leaf in the on-chain `IntentExecuted` event accumulator with root `receiptAccumulatorRoot` (public input); proved via Merkle inclusion path private input — this anchors each receipt to an actual on-chain execution event and prevents fabrication

**Public inputs:**
- `capabilityKeccakHash`: `keccak256(abi.encode(capability))` — the EIP-712 struct hash of the root capability. This hash identifies which capability the selective disclosure proof is for; verifiers can look up the full capability struct by scanning `Capability` issuance events (where `capabilityHash` is indexed), then check revocation via `revokedNonces[capability.issuer][capability.nonce]` — a two-step lookup, not a single-SLOAD from the hash alone. **Verifier precision note:** the on-chain verifier contract cannot derive `issuer` and `nonce` from `capabilityKeccakHash` alone (hashes are one-way). If an on-chain verifier needs to enforce "capability must not be revoked at proof verification time," `capability.issuer` and `capability.nonce` must be added as additional public inputs and the verifier calls `revokedNonces[issuer][nonce]` directly. For the primary Phase 2 use case (off-chain credential presentation), the two-step lookup via event scanning is sufficient and `capabilityKeccakHash` alone is correct. Note also: because every receipt in the proof already passed through the kernel (which verified non-revocation at execution time), the receipts themselves implicitly attest that the capability was valid when each intent executed — Circuit 1 does not need to re-prove non-revocation for historical intents; only for claims about the capability's current status would additional public inputs be needed. The prover internally re-derives the Poseidon2 version of the constraints via the dual-hash bridge for in-circuit constraint checks; this internal value is never exposed as a public input and does not need EVM verification. *(Design note: an earlier version of this spec used `capabilityConstraintsHash = Poseidon2(constraints)` as the public input. This was incorrect — the EVM has no Poseidon2 precompile and cannot verify a Poseidon2 hash against the on-chain capability data. The keccak256 hash is the correct choice because it is already available on-chain.)*
- `N`: number of intents proved
- `nullifierSetRoot`: Merkle root of the prover's disclosed nullifier set (subset of the capability's full nullifier set)
- `receiptAccumulatorRoot`: Merkle root of the on-chain `IntentExecuted` event accumulator (published by the protocol's event indexer; Phase 2 infrastructure)
- `periodStart`, `periodEnd`: time range for the selective disclosure proof (enables sub-period proofs)

**Private inputs:**
- N intent preimages (adapter, amountIn, deadline, nonce, positionCommitment, ...)
- N execution receipts (amountOut, timestamp, receiptHash)
- N Merkle inclusion proofs from nullifier to `nullifierSetRoot`
- N Merkle inclusion proofs from `receiptHash_k` to `receiptAccumulatorRoot`
- 2N keccak256-to-Poseidon2 bridge witnesses, two per intent: one for `positionHash = keccak256(owner, asset, amount, salt)` and one for `nullifier = keccak256(nonce, positionCommitment)`. Each bridge witness is a pair `(lo_128, hi_128)` — the 128-bit low and high halves of the keccak output (see byte-to-field encoding note in §7.2)
- 1 capability bridge witness: `(lo_128, hi_128)` for `capabilityKeccakHash`, used internally so the circuit can re-derive the Poseidon2 representation of the constraints for in-circuit constraint checks

**Key circuit design decisions:**

*Period bucketing:* The circuit must sort intents by execution timestamp and sum amounts within each period bucket. Sorting in a ZK circuit is non-trivial. The approach: the prover provides intents in sorted order by execution timestamp from the receipt (private input). The circuit verifies that the sort order is correct (`r_k.timestamp ≤ r_{k+1}.timestamp` for all k) — using the execution receipt timestamp, not `intent.deadline`, which is a maximum boundary, not the actual execution time. The circuit then accumulates sums using a running counter that resets when `floor(r_k.timestamp / periodDuration)` changes across consecutive intents. Constraint cost: O(N) comparisons + O(N) additions.

*Return ratio check:* `amountOut / amountIn ≥ minReturnBps / 10000`. Division in field arithmetic requires care. The circuit rewrites this as: `amountOut × 10000 ≥ amountIn × minReturnBps`. This is a field multiplication comparison — no division, no precision loss. Range checks on `amountIn` and `amountOut` prevent overflow: both are constrained to `[0, 2^128)` using 128-bit range decomposition. Note: this ratio is only semantically meaningful for same-denomination or near-parity swaps (see §4.2 for cross-asset semantics).

*Adapter set membership:* `adapter ∈ allowedAdapters`. For small adapter sets (≤ 8 addresses, typical), enumerate and check equality against each. For larger sets, commit the allowed adapter set as a Merkle tree root and prove inclusion per intent. The compact Merkle tree over adapter addresses uses Poseidon2, making each membership proof ~7 Poseidon2 calls (for depth-3 tree over 8 adapters) = ~700 gates per proof.

*Nullifier Merkle inclusion:* The circuit proves each of the N nullifiers is a leaf in a Merkle tree with root `nullifierSetRoot`. This tree is maintained off-chain by the protocol's indexer (or by the prover) and scoped per capability. Tree depth 20 (supporting 2^20 ≈ 1,000,000 nullifiers) × N=100 intents × ~100 gates per Poseidon2 hash × 20 levels = ~200,000 gates for nullifier inclusion alone.

*Receipt anchoring (on-chain event accumulator):* The circuit proves each `receiptHash_k` is a leaf in the `receiptAccumulatorRoot`. The accumulator is an on-chain Merkle tree maintained by the `CapabilityKernel`: each `IntentExecuted` event appends `receiptHash` to the accumulator, and the current root is a public storage variable. The circuit's Merkle inclusion proof over receipts prevents the prover from fabricating execution history. This accumulator adds ~200 gas per intent execution to maintain the root (SLOAD + keccak + SSTORE). Without this accumulator, receipt inputs are self-attested and unverifiable — the credential's anti-fabrication property is absent. The accumulator is Phase 2 infrastructure; Phase 1 proofs that omit it should be labelled "uncorroborated disclosure" rather than anchored credentials.

**Verifier work:** The constraint checks (adapter, spend, return) are O(1) to verify via the SNARK. The nullifier membership claim is also O(1) — the verifier only checks `nullifierSetRoot` against the published capability nullifier accumulator root (one SLOAD). The receipt accumulator root is checked in the same way (one SLOAD). This achieves genuine O(1) on-chain verification for all claims, once the two accumulator infrastructure pieces are deployed.

**Approximate constraint count:**

Each intent requires TWO keccak256 bridge calls: (1) `positionHash = keccak256(owner, asset, amount, salt)` and (2) `nullifier = keccak256(intent.nonce, intent.positionCommitment)`. These are independent hashes that must both be bridged to Poseidon2 for in-circuit operations.

- Bridge keccak256 witnesses: N × 2 × ~12,000 gates = 2,400,000 (N=100)
- Intent sort verification (receipt timestamp): N × ~50 gates = 5,000
- Period bucket accumulation: N × ~100 gates = 10,000
- Return ratio checks: N × ~200 gates = 20,000
- Adapter set membership (8 adapters, Merkle): N × ~700 gates = 70,000
- Nullifier Merkle inclusion (depth 20): N × 20 × ~120 gates = 240,000
- Receipt accumulator Merkle inclusion (depth 20): N × 20 × ~120 gates = 240,000 *(Phase 2 only)*
- **Total (N=100, Phase 1 — no receipt accumulator): ~2,745,000 gates** (dominated by keccak256 bridge)
- **Total (N=100, Phase 2 — with receipt accumulator): ~2,985,000 gates**
- **Total (N=100, Option C — Poseidon2 on-chain, Phase 2): ~585,000 gates**

For N=1,000: scale linearly. ~27,000,000 gates with keccak256 bridge. At this scale, Option C (migrating on-chain commitments to Poseidon2) is strongly justified. The crossover point where migration becomes cost-effective is approximately N > 200–300 intents per proof window, depending on hardware.

**Proof system recommendation: UltraHonk (Barretenberg)**

Rationale: UltraHonk does not require a circuit-specific trusted setup. The universal SRS (EIP-4844 KZG ceremony) is sufficient. For a ~1.5M gate circuit, UltraHonk proving time on commodity hardware (32-core, 64 GB RAM) is approximately 3–8 minutes. Verification gas on Base: approximately 280,000–400,000 gas (UltraHonk verifier). Proof size: ~2 KB.

**Groth16 alternative:** Would reduce verification gas to ~250,000 and proof size to 192 bytes. Requires a circuit-specific trusted setup MPC ceremony. For the compliance proof circuit, this is feasible but adds operational overhead: any circuit change (e.g., adding a new constraint type) requires a new ceremony. Given that the compliance circuit is likely to evolve during Phase 2–3, UltraHonk's universal setup is preferable until the circuit stabilizes.

**IVC/incremental proving (honest assessment):** Incrementally Verifiable Computation (Nova-style folding schemes) would allow new intents to be added to a compliance proof without reproving all historical intents — O(1) marginal cost per new intent. This is the theoretically correct approach for a rolling compliance proof. However, IVC in Noir/Barretenberg is **not production-ready as of February 2026.** The Barretenberg team is actively developing folding scheme support, but it has not been validated for production deployment. **Do not build Phase 2 circuits on IVC.**

**Batch proving and multi-window credentials:** The practical Phase 2 recommendation is batch proving per time window (e.g., one proof per calendar quarter). Each batch proof is an independent, self-contained selective disclosure credential for its window. **Important:** two batch proofs for different windows are *not composable* by simply checking them in sequence. A pair of SNARK proofs has no cryptographic linkage — a verifier checking P1 (Q1) and P2 (Q2) independently cannot cryptographically confirm they cover the same capability or agent without additional binding. Options for multi-window composition: (a) accept that each credential is standalone and verifiers manually check the `capabilityKeccakHash` public input matches across proofs — since this is the on-chain EIP-712 hash of the capability struct, it is human-readable and independently verifiable by looking up the capability on-chain; (b) use recursive proof verification — a "meta-proof" that verifies two inner proofs and asserts they share the same `capabilityKeccakHash` — this is the cryptographically correct composition and is feasible with UltraHonk's recursive verification support, at the cost of increased proving time for the meta-proof. For Phase 2, option (a) is sufficient. Option (b) is the target for Phase 3.

**Time-range parameterization:** Include `periodStart` and `periodEnd` as public inputs. The circuit verifies that all N receipts satisfy `r_k.timestamp ∈ [periodStart, periodEnd]` — using the execution receipt timestamp, not `intent.deadline` (the deadline is a maximum bound on when execution may occur, not the actual execution time). This allows generating a compliance proof for any arbitrary date range without reproving the full history.

### 7.4 Circuit 2: Sub-Capability Chain Verification

**The problem:** Sub-capability chain verification currently requires O(depth) on-chain storage reads and exposes the full delegation lineage in calldata (~4 kB for depth-8). An agent executing frequently with deep sub-capability chains pays significant gas and reveals the full organizational delegation structure to chain observers.

**Formal proof statement:**

> The prover knows a delegation chain `C_0 → C_1 → ... → C_k` (k ≤ 8) such that:
> 1. `C_0` is the root capability, with hash matching `rootCapabilityHash`
> 2. For each `i`, `C_{i+1}.issuer == C_i.grantee`
> 3. For each `i`, `C_{i+1}` constraints are a subset of `C_i` constraints (per §4.3 rules)
> 4. For each `i`, `C_{i+1}.expiry ≤ C_i.expiry`
> 5. No `keccak256(C_i)` for `i ∈ {0, ..., k-1}` is in the revocation registry
> 6. `C_k.grantee == terminalGrantee`
> 7. `effectiveConstraintsKeccakHash == keccak256(abi.encode(intersection_of_all_constraints))` — the on-chain verifiable commitment to the computed effective constraints

**Public inputs:**
- `rootCapabilityHash`: keccak256 of the root capability (matches on-chain revocation registry key — on-chain verifiable by checking `revokedNonces[issuer][nonce]`)
- `terminalGrantee`: address of the agent actually submitting the intent
- `effectiveConstraintsKeccakHash`: `keccak256(abi.encode(effectiveConstraints))` — the keccak256 hash of the computed intersection of all constraints along the chain. This is the public input consumed by the `CapabilityKernel` on-chain: the kernel recomputes `keccak256(abi.encode(appliedConstraints))` from the intent's stated constraints and checks that it equals this public input. Using keccak256 here is required because the EVM verifier cannot evaluate Poseidon2; a Poseidon2 `effectiveConstraintsHash` would be unverifiable on-chain. *(Design note: this public input was previously specified as `effectiveConstraintsHash = Poseidon2(effectiveConstraints)`. This was incorrect for the same reason as the Circuit 1 `capabilityConstraintsHash` error — the EVM cannot verify Poseidon2 values against on-chain data. Corrected to keccak256.)*
- `revocationStateRoot`: Merkle root of the current revocation registry snapshot

**Private inputs:**
- k capability structs `{C_0, ..., C_k}`
- k issuer signatures over each capability
- k revocation non-membership proofs against `revocationStateRoot`

**Revocation non-membership:** The revocation registry is an on-chain flat mapping. Proving non-membership in a mapping inside a ZK circuit requires either (a) a Merkle tree structure over the mapping with off-chain maintenance, or (b) accepting that the prover provides a snapshot root that the on-chain verifier validates against a known published state. Option (b) is used: the protocol publishes a Merkle accumulator of all revoked nonces at a defined epoch interval (e.g., every 12 hours). The circuit proves non-membership in this accumulator. The verifier checks that the accumulator root used in the proof is the canonical on-chain root.

**Revocation staleness window (critical security consideration):** The epoch interval introduces a window during which a freshly revoked capability could still produce a valid sub-capability chain proof — because the Merkle accumulator has not yet been updated to include the new revocation. With a 12-hour epoch, this window is up to 12 hours. **This is the primary security tradeoff of Circuit 2.** Mitigations: (1) require the on-chain verifier to check the canonical accumulator root was updated within the last epoch before accepting the proof; (2) provide an emergency "fast revocation" path that triggers an immediate accumulator update for critical revocations; (3) set epoch intervals based on the maximum acceptable revocation-to-enforcement latency for the deployment. For Phase 2, a 1-hour epoch with emergency fast-update is the recommended starting point. The non-ZK sub-capability path (which checks revocation from the on-chain mapping directly, with no staleness window) remains available and should be used for all high-value operations until the revocation accumulator design is validated.

**Constraint intersection computation:** The circuit computes the element-wise minimum/maximum across all constraint fields along the chain:
- `effectiveMaxSpend = min(C_0.maxSpend, C_1.maxSpend, ..., C_k.maxSpend)`
- `effectiveMinReturn = max(C_0.minReturn, C_1.minReturn, ..., C_k.minReturn)`
- `effectiveAllowedAdapters = ∩(C_0.adapters, ..., C_k.adapters)` (via bitmap or Merkle intersection)

The result is committed as `effectiveConstraintsKeccakHash = keccak256(abi.encode(effectiveConstraints))`. The on-chain verifier checks: (1) the proof is valid, (2) `rootCapabilityHash` is not in the revocation registry, (3) `terminalGrantee` matches the intent signer, and (4) the constraints applied during intent execution match `effectiveConstraintsKeccakHash`. The circuit internally also computes `Poseidon2(effectiveConstraints)` as a private intermediate for circuit operations; this Poseidon2 value is never a public input and therefore never requires EVM verification.

**Approximate constraint count:** ~50,000–120,000 gates (highly dependent on constraint intersection implementation). Proving time: <30 seconds. This is the most impactful circuit for routine protocol operations and the best candidate for Phase 2 prioritization.

### 7.5 Circuit 3: Condition Tree Proof

**The problem:** Keepers currently reveal the full condition tree at trigger time, permanently disclosing the strategy structure. A ZK circuit would allow the keeper to prove the tree evaluates to `true` without revealing its contents.

**What privacy is actually achieved on a public EVM:** This requires careful scoping.

- Oracle *values* (Chainlink prices, Aave rates) are public on-chain. The circuit cannot hide them.
- Oracle *thresholds* remain private. An observer learns that *some* condition was met, but not at what threshold.
- The *boolean structure* of the condition tree remains private. An observer cannot determine whether the strategy used AND or OR logic, or how many conditions were required.
- The *set of oracles used* remains private. An observer learns that the envelope triggered, but not which oracle feeds were consulted.

For simple price-leaf stop-losses, the threshold is inferable from the transaction context (the trade happened when ETH was at $X, so the threshold was probably near $X). The privacy gain is marginal for single-condition strategies and brute-forceable from execution timing.

**For multi-condition strategies, the privacy gain is real and significant.** A complex tree with AND/OR logic across price, volatility, and on-chain state conditions reveals a sophisticated strategy structure that is commercially sensitive. The circuit protects this structure permanently.

**Honest recommendation:** Build Circuit 3 only for composite condition trees (depth ≥ 2 with at least one OR node). Single-leaf envelopes use the existing plaintext reveal — the ZK overhead is not justified by the marginal privacy gain.

**Circuit-level depth bound enforcement:** The condition tree protocol constant `MAX_TREE_DEPTH = 8` is enforced by the on-chain `EnvelopeRegistry` via gas-bounded evaluation. Circuit 3 must additionally enforce this bound as an explicit circuit constraint: the prover provides the tree depth as a private input `d`, and the circuit asserts `d ≤ 8` using a range check. Without this constraint, a malicious prover could construct a proof claiming a tree of depth 9 evaluates to `true` — the on-chain verifier would accept the proof (since the circuit did not reject it) and only the gas limit would prevent execution. Enforcing depth in the circuit makes the depth bound a cryptographic guarantee, not a gas-limit heuristic.

**Oracle freshness:** The most important design question for Circuit 3 is how to handle oracle values that change between proof generation and block inclusion.

**Recommendation: Option B (pull — verifier re-reads oracle at verification time).** The verifier contract calls the oracle directly at proof verification time. The circuit's oracle value public inputs must match the oracle's current value. If the price has moved between proof generation and block inclusion, the proof becomes invalid and the keeper must regenerate it. This is the correct behavior for a stop-loss: if the price has recovered, the stop-loss should not trigger.

**Stale-proof risk:** A keeper generates a proof when ETH = $1,795 (below the $1,800 threshold). The price recovers to $1,850 before block inclusion. The verifier reads $1,850 from the oracle, the proof's public input says $1,795, the verifier rejects. The envelope does not trigger. This is correct and desirable — the keeper should regenerate the proof in the new price environment and check whether the condition still holds.

### 7.6 Circuit 4: M-of-N Threshold Aggregation

**The problem:** M-of-N consensus intents submit O(M) calldata (M capability signatures, M intent signatures, M Merkle proofs). For M=5, this is ~3–4 kB of calldata. For swarm-scale M=60-of-100, this is ~50–60 kB — impractical.

**ECDSA in Noir:** Noir's standard library includes secp256k1 ECDSA verification. Constraint cost: approximately 3,500–5,000 gates per ECDSA verification (hardware-dependent; measured on UltraHonk backend). For M=5: ~20,000–25,000 gates for signatures alone. For M=60: ~210,000–300,000 gates — feasible but expensive.

**BLS vs ZK-aggregated ECDSA comparison:**

| | BLS Signature Aggregation | ZK-aggregated ECDSA |
|---|---|---|
| Verification cost | O(1) — ~100,000–150,000 gas for aggregate BLS verify | O(1) ZK proof verify — ~250,000–400,000 gas |
| Proof/sig size | 48 bytes (G1 point) | ~2 kB proof |
| Key infrastructure | Requires BLS key registration (separate from Ethereum keys) | Uses existing secp256k1 keys |
| Trust assumption | None (BLS is a standard construction) | ZK proving system security |
| Setup overhead | Agents must register BLS keys on-chain | No setup — existing keys work |

**Recommendation for M ≤ 20 (M-of-N committees):** ZK-aggregated ECDSA. Agents hold standard Ethereum keys. No key migration required. The circuit is feasible and the gas cost (one ZK proof verification) is competitive with M on-chain ECDSA verifications for M ≥ 5.

**Recommendation for M > 20 (swarm model, Tier 4):** BLS signature aggregation. Re-keying 100 swarm agents is operationally feasible at setup time. The O(1) BLS aggregate verification is more gas-efficient than a 60-ECDSA ZK circuit at scale, and the verification gas cost is lower. ZK-aggregated ECDSA at M=60 costs ~250,000 gates for ECDSA alone — proving time becomes a user-facing latency problem.

### 7.7 Verifier Deployment Architecture

**Recommendation: One Solidity verifier contract per circuit, plus a verifier registry.**

One verifier per circuit provides:
- Clean separation of verification keys and circuit logic
- Targeted upgradeability (circuit update → deploy new verifier → update registry pointer, no protocol restart)
- Independent auditability per circuit

A governance-controlled `VerifierRegistry` maps circuit identifiers to verifier addresses:

```solidity
mapping(bytes32 circuitId => address verifier) public verifiers;
function updateVerifier(bytes32 circuitId, address newVerifier) external onlyGovernance;
```

New circuits are registered by governance. Existing circuits can be upgraded (new Noir version, constraint optimization, security fix) by deploying a new verifier and updating the registry — without changing the `CapabilityKernel` or `EnvelopeRegistry` interfaces.

**Against a universal verifier:** A single verifier that accepts any Noir-generated proof with the appropriate verification key is flexible but sacrifices the ability to enforce circuit-specific input layout and validity rules at the contract level. Per-circuit verifiers allow the Solidity code to enforce that specific public inputs are correctly populated before calling the ZK verifier.

### 7.8 ZK Build Phasing

| Circuit | Phase | Rationale |
|---|---|---|
| Circuit 2: Sub-Capability Chain | Phase 2 (weeks 8–16) | Highest impact on routine operations; moderate complexity; no IVC required |
| Circuit 1: Selective Disclosure Proof | Phase 2 (weeks 12–16) | Core value proposition; build after hash decision and receipt accumulator design are resolved |
| Circuit 4: M-of-N Aggregation (ECDSA, M≤20) | Phase 3 (weeks 16–24) | Requires Phase 2 circuits to prove the ECDSA approach is feasible |
| Circuit 3: Condition Tree (composite trees only) | Phase 3 (weeks 20–24) | Depends on oracle freshness decision |
| Circuit 5: Position Split/Merge | Phase 4 | Privacy value limited on public EVM; build when on-chain Poseidon2 migration occurs |
| Circuit 6: Proof of Reserves | Phase 3 | High institutional value; straightforward implementation |
| Circuit 7: Treasury Compliance (DAO) | Phase 4 | Complex portfolio weight constraints; depends on Circuit 1 |

**The two circuits to build first (highest value, fastest):**

1. **Circuit 2 (Sub-Capability Chain):** Immediately reduces calldata cost and hides delegation topology from observers. Moderate circuit complexity (~100,000 gates). Direct path from specification to production.

2. **Circuit 1 (Selective Disclosure Proof):** The protocol's most differentiated capability. An agent with a portable, verifiable credential proving constraint adherence is categorically more trustworthy than one without. Build after resolving the hash function decision and receipt accumulator design (Q2).

---

## 8. Derivatives and Conditional Settlement Extensions

### 8.1 The Generalization

The condition tree envelope was designed for AI agent stop-losses and rebalancing triggers. Its actual generality is broader: every conditional financial contract reduces to the same three-component structure.

1. **One or more parties commit assets to a shared execution context.** Neither can withdraw unilaterally. Both are locked in.
2. **A condition tree defines when and how the committed assets are redistributed.**
3. **The keeper network enforces settlement.** Execution is automatic, permissionless, and liveness-independent.

Step 1 is the vault commitment. Step 2 is the condition tree. Step 3 is the keeper network. Every derivative is a configuration of these three components.

### 8.2 Options Settlement

An options contract is precisely: the right to execute a specified asset transfer at a specified price, under specified conditions, settled automatically when the condition is met.

**Type 1 — Automated conditional execution (no counterparty):**

```
User deposits 1 ETH to vault.
Registers envelope:
    condition: ETH/USD PriceLeaf < 1,800 (LESS_THAN)
    intent:    sell 1 ETH → USDC via UniswapV3Adapter
    minReturn: 1,791 USDC (0.5% slippage floor)
    expiry:    none
```

This is economically equivalent to a put option at $1,800 strike with no expiry. Cost: one keeper reward (~$1 on Base). No premium. No counterparty. Executes automatically if the condition is met regardless of agent liveness.

**Type 2 — Real options with hard price guarantees (two-party vault commitment):**

```
Writer (yield-seeking, willing to buy ETH at $1,800):
    vault.deposit(USDC, 1800e6, salt_writer)
    — 1,800 USDC is in the vault, locked, irrevocable until expiry

Buyer (wants hard downside protection):
    vault.deposit(ETH, 1e18, salt_buyer)
    — pays 50 USDC premium to writer at commitment time

Envelope (bilateral):
    condition (exercise): ETH/USD < 1800 at expiry
        → deliver 1,800 USDC to buyer
        → deliver 1 ETH to writer
        → writer keeps premium

    condition (expire): timestamp > expiry AND ETH/USD ≥ 1800
        → return 1 ETH to buyer
        → return 1,800 USDC to writer
        → writer keeps premium
```

**The gap risk property:** The 1,800 USDC was committed before the option was created. If ETH drops to $200, the buyer receives exactly $1,800 — not approximately, not subject to pool solvency, not subject to oracle manipulation at a single block. The collateral is pre-committed. Default risk is zero by construction.

This is qualitatively different from pool-based options protocols (Lyra, Hegic, Opyn): pool-based protocols aggregate counterparty risk across many options, creating the possibility of pool insolvency under correlated stress. The two-party vault model carries zero counterparty default risk per contract.

**Options structure coverage:**

| Contract type | Condition tree encoding | Requires counterparty |
|---|---|---|
| Protective put | `PriceLeaf(ETH/USD < strike)` | No (Type 1) or Yes (Type 2) |
| Covered call | `PriceLeaf(ETH/USD > strike)` | No |
| Collar | Two PriceLeaf envelopes on split positions | No |
| Straddle | `OR(PriceLeaf < low, PriceLeaf > high)` | No |
| Asian option | `TWAP_PriceLeaf` (30-min TWAP) | No |
| Barrier option | `ConditionalCapability` + inner envelope | No |
| Compound option | Chained envelopes (parent registers child) | No |
| Quanto option | `PriceLeaf(ETH/BTC < ratio)` | No |
| Forward contract | `TimeLeaf(timestamp == settlement_date)` + two-party vault | Yes |
| Digital/binary | Any condition tree + fixed-output intent | No |

No new protocol infrastructure is required for any entry in this table. Each is a configuration of existing primitives.

### 8.3 Broader Derivatives

The same structure extends to the complete landscape of financial derivatives:

**Interest Rate Swaps:** Party A (fixed rate payer) and Party B (floating rate payer) commit collateral. A chain of `TimeLeaf` envelopes fires at each settlement date, reads the floating rate from an `OnChainStateLeaf` (e.g., Aave V3 `getReserveData(USDC).currentLiquidityRate`), and transfers the net payment between parties. No bank intermediary. No ISDA master agreement. The on-chain rate oracle is the arbiter.

**Protocol Insurance (CDS):** Protection buyer pays periodic premium; protection writer commits collateral. Trigger condition: `OnChainStateLeaf(AavePool.totalDeposits) < (inception_value × 0.5)` — parametric payout fires if Aave loses more than 50% of deposits. No governance vote on whether the hack "counts." The oracle state is the arbiter. Payout is immediate and unchallengeable.

**Perpetual Futures:** Party A (long) and Party B (short) commit collateral. A chain of `TimeLeaf` envelopes fires at each funding interval (e.g., every 8 hours), reads the funding rate and perpetual/spot spread from oracle, and transfers the net funding payment. A separate health factor envelope fires when `position_pnl + collateral < threshold`, liquidating the underwater party. The protocol is the liquidation engine — no centralized liquidator bot, no protocol-owned liquidity pool.

**Volatility Swaps:** Party A (volatility buyer) and Party B (volatility seller) commit collateral. At settlement, a `VolatilityLeaf` oracle provides realized volatility for the period. Net payment: `notional × (realized_vol - strike_vol)`. First trustless on-chain volatility product.

### 8.4 The Meta-Primitive: Programmable Credible Commitment

The deepest insight that the vault commitment + condition tree unlocks is not financial: it is the ability to manufacture **credible commitment** — a guarantee that is cryptographically irreversible.

Every existing commitment mechanism fails in edge cases:
- Legal contracts can be disputed, delayed, or nullified
- Social contracts depend on continued reputation
- Institutional promises can be abandoned under pressure
- Smart contract multisigs can be rotated by their signers

The vault commitment + condition tree is the first mechanism that makes commitment genuinely irreversible. Once assets are in the vault, they cannot be redirected. Once a condition tree is committed, the execution logic cannot be altered. The committing party cannot renegotiate, buy time, or apply pressure. **This applies to any party — human, institution, DAO, or AI agent.**

The economic consequence: a party that can credibly commit changes the behavior of every counterparty that interacts with them. A protocol that cannot change its fee structure commands higher LP liquidity. A founder with a cryptographically locked vesting schedule commands higher investor confidence. A DAO that cannot claw back committed grants commands higher contributor engagement.

Atlas does not merely settle financial contracts. It manufactures credibility. And credibility is one of the scarcest resources in every domain of human coordination.

---

## 9. Competitive Analysis

### 9.1 MetaMask Delegation Toolkit (ERC-7710 / ERC-7715)

The most direct architectural competitor.

**What it is:** A delegation framework built on ERC-7710. Requires a deployed DeleGator smart account per user. Delegations are stored on-chain in a `DelegationManager` singleton. Constraint enforcement is provided by Caveat Enforcer contracts — arbitrary Solidity bytecode that runs during intent validation.

**The `EIP-7702` variant:** Allows any EOA to adopt delegation capabilities without deploying a contract, reducing the deployment friction. The `EIP7702StatelessDeleGator` is a genuine improvement over the standard DeleGator path.

**What MDT does not address:**

| Gap | MDT (ERC-7710) | MDT (EIP-7702) | Atlas |
|---|---|---|---|
| Liveness-independent enforcement | No | No | Yes — envelopes fire without agent or EOA |
| Commitment-based custody | No — EOA balance model | No — EOA balance model | Yes — UTXO commitments |
| MEV protection for conditional execution | None specified | None specified | Flashbots Protect + minReturn floor |
| Multi-agent constraint inheritance | Partial — chains supported; subset enforcement not specified | Partial | Yes — kernel enforces full monotonicity |
| Aztec portability | No — EOA model cannot map to private notes | No | Yes — commitment model = note model |
| Arbitrary caveat code audit surface | Scales with caveat count | Scales with caveat count | Fixed — declarative Constraints struct |

**The caveat enforcer problem is structural:** Every new constraint type requires a new audited Solidity contract. The audit surface of an MDT deployment scales with the number of caveat types. Atlas's `Constraints` struct encodes a fixed set of constraint dimensions that cover all practical agent authorization needs. Adding a new constraint type requires an interface-level review and a kernel upgrade — but the scope is bounded and auditable.

### 9.2 ERC-4337 Smart Accounts + Session Keys

**What it is:** Account abstraction standard with per-user smart accounts. Session keys provide scoped authorization.

**The structural gap:** The account IS the custody object. A compromised session key with insufficient scope bounds still has access to the account's state. Recovery requires guardians or social recovery mechanisms — stateful, slow, and adversarially reachable. There is no on-chain primitive for liveness-independent conditional execution in the base standard.

### 9.3 Coinbase AgentKit + CDP Wallet

**What it has:** AgentKit (developer SDK with DeFi integrations), CDP Wallet (key management), Base (AI developer concentration), and distribution through Coinbase exchange.

**The structural gap:**

| Dimension | Coinbase AgentKit + CDP | Atlas |
|---|---|---|
| Custody | CDP Wallet — Coinbase holds keys | User-controlled vault; non-custodial |
| Enforcement | CDP-run keeper — centralized; censorship risk | Permissionless keeper network |
| Agent compromise bound | Session key scope = loss ceiling | Capability constraints = hard bound |
| Censorship resistance | CDP can freeze operations | Users withdraw directly from vault; no agent or keeper approval required |
| Regulatory perimeter | US-regulated financial infrastructure | Protocol-level; no single jurisdiction |

The fundamental difference: any keeper infrastructure operated by a single company is a single point of failure and a single regulatory target. A permissionless keeper market with economic incentives is censorship-resistant by construction.

### 9.4 ERC-7579: Modular Smart Accounts

**What it is:** A standard module interface for smart accounts, enabling pluggable executor, validator, and hook modules. A UCAN-inspired capability module built as a 7579 executor could replicate approximately 60% of the EVM-side functionality of Atlas's Phase 1 within the existing smart account ecosystem.

**What it can replicate:** Capability scoping, adapter allowlists, basic spend limits, multi-step execution flows.

**What it cannot replicate:**
- **Commitment-based custody with no per-user contracts** — 7579 is built on smart accounts; custody is always tied to the account.
- **Liveness-independent enforcement** — there is no envelope primitive; conditional execution requires the account to be present or a trusted module to be authorized.
- **Off-chain capability issuance** — module state must live in the account; zero-gas delegation is not possible.
- **Aztec portability** — account balance models cannot map to note commitments without replacing the custody layer.

**Why it matters more than ERC-8001:** ERC-7579 has a larger ecosystem, active development, and can be deployed by developers today. A well-built 7579 executor module is a faster time-to-market for ~60% of Phase 1 value. The strategic response is not to ignore this risk but to demonstrate the remaining 40% (envelopes, commitment model, privacy path) as non-replicable differentiation.

### 9.5 ERC-7521: Generalized Intents

**What it is:** ERC-7521 (Generalized Intents Standard) proposes a common interface for expressing user intents with arbitrary intent standards registered via a `IIntentStandard` interface. Users sign intents specifying desired outcomes; solvers compete to produce optimal execution paths. It is the most architecturally similar standard to Atlas's intent layer in the existing ERC landscape — more directly relevant than ERC-8001.

**What it does well:** Solver competition, arbitrary outcome specifications, account abstraction compatibility, and a permissionless standard registration mechanism.

**What it does not address:**

| Gap | ERC-7521 | Atlas |
|---|---|---|
| Custody isolation | Intents reference account balances; no commitment model | UTXO-style commitments; vault holds no per-user state |
| Liveness-independent enforcement | No envelope primitive; intents require active submission | Envelopes fire permissionlessly via keepers |
| Capability constraint scoping | No on-chain constraint enforcement; outcome-only | Hard `Constraints` struct enforced by kernel on every execution |
| Privacy migration path | Account-centric; cannot map to note model | Commitment model = direct Aztec migration path |
| Delegation chains | Not specified | Sub-capability chains with monotone inheritance |

**Positioning relative to Atlas:** ERC-7521 solves solver coordination for account-centric users. Atlas solves custody isolation, agent constraint enforcement, and liveness-independent execution — the three layers ERC-7521 intentionally leaves unspecified. The two could coexist: Atlas could register as an `IIntentStandard` implementation, using the ERC-7521 solver network as the execution layer while Atlas provides the constraint enforcement and custody model above it.

### 9.6 Strategy NFTs and Protocol Revenue

**What they are:** ERC-1155 tokens representing reusable condition tree templates. A strategy creator mints a token encoding a condition tree root and intent template. Users apply the strategy to their positions. Every time the strategy triggers, the creator earns a royalty (up to 100 bps of execution value) paid atomically at trigger time. On-chain execution statistics (fill rate, average slippage, total executions, total volume) provide an unforgeable live track record.

**Why this matters competitively:** Atlas becomes a strategy marketplace with provable performance history. This is the only protocol in the competitive landscape where strategies earn passive income from live execution and where track records cannot be fabricated — they are produced by on-chain execution events. Every existing strategy marketplace (dHedge, Enzyme, Yearn) uses off-chain or governance-layer reputation. Atlas's track records are cryptographically attested.

### 9.7 The Structural Gaps All Alternatives Share

| Property | Atlas | MDT (ERC-7710) | ERC-4337 | AgentKit | ERC-7579 | ERC-7521 |
|---|---|---|---|---|---|---|
| Zero per-user contracts | Yes | No | No | No | No | No |
| Off-chain delegation (zero gas) | Yes | No | No | No | No | No |
| Liveness-independent enforcement | Yes | No | No | No | No | No |
| Commitment-based custody | Yes | No | No | No | No | No |
| Capability constraint enforcement | Declarative, kernel-level | Caveat bytecode | Session key scope | SDK-level | Module bytecode | Not specified |
| Privacy migration path | Yes (Aztec) | No | No | No | No | No |
| Strategy marketplace / provable track records | Yes | No | No | No | No | No |
| AI agent threat model | Designed for it | Partial | Partial | Partial | Partial | No |

---

## 10. Application Layer: ClawLoan Reference Integration

ClawLoan — a credit protocol for AI agents — is Atlas's primary beachhead application and the clearest single demonstration of the protocol's value proposition. Four use cases demonstrate the full capability surface across both sides of the market.

### The Two-Sided Market

**Borrower side (AI agents):** ClawLoan extends uncollateralized credit to AI agents based on ZK-attested credit history. The fundamental problem is liveness: repayment requires the agent to be online at the loan deadline. If the agent is offline, rate-limited, compromised, or destroyed, the loan goes unpaid. Atlas replaces "the agent will repay" with a pre-committed Atlas Envelope — a cryptographic instruction registered at loan origination that any keeper can execute at deadline with no agent participation.

*Reference use case document: `CLAWLOAN_BORROW.md`*

**Lender side (institutional capital):** For institutional capital providers, the barrier to entering AI-agent lending is the absence of enforceable, lender-defined risk controls. Governance-based risk management is too slow for AI-agent utilization dynamics. Atlas gives institutional lenders a new primitive: define a utilization threshold, sign three EIP-712 messages, and have the `PoolPauseAdapter` fire permissionlessly via any keeper when the pool exceeds that threshold. No governance vote. No ops team. No single point of failure.

*Reference use case document: `CLAWLOAN_LEND.md`*

### The Strategy Graph Extension

The same infrastructure that handles individual loan enforcement composes into multi-step strategy graphs:

**Borrow-to-Yield Self-Repaying Loan:** An agent borrows USDC, pre-signs a 3-stage chain (ETH rally → harvest yield position → repay loan → rebuy WETH) in one session, then goes offline. When ETH hits the trigger price, the entire chain executes permissionlessly. The critical mechanism is deterministic position chaining: the output salt of Stage N is computable before Stage N fires, enabling Stage N+1 to be committed in advance. This is the primitive that turns individual enforcement envelopes into composable strategy graphs.

*Reference use case document: `SELF_REPAYING_LOAN.md`*

**Bi-Directional Collateral Rotation:** An agent pre-commits a two-stage protection cycle — de-risk WETH → USDC when ETH drops, re-risk USDC → WETH when ETH recovers — with the full cycle signed before the agent goes offline. The strategy is hash-committed at registration, remaining private until each stage fires. MEV operators cannot front-run a strategy whose parameters are unknown until execution is already atomic. This demonstrates that Atlas is not a stop-loss protocol; it is a general-purpose pre-committed strategy primitive.

*Reference use case document: `COLLATERAL_ROTATION.md`*

### Integration Architecture

```
ClawLoan Pool (borrow/lend)
  └── ClawloanRepayAdapter    → repay(botId, amount) via Atlas kernel
  └── PoolPauseAdapter        → pauseBorrowing() via Atlas keeper envelope
  └── UtilisationOracle       → Chainlink AggregatorV3-compatible feed wrapping pool utilization

Atlas Protocol
  └── SingletonVault          → holds agent positions as commitments
  └── CapabilityKernel        → verifies signatures, enforces constraints, routes to adapter
  └── EnvelopeRegistry        → stores conditional orders, checks oracles, forwards to kernel
  └── ZK CreditVerifier       → verifies agent's compliance history proof (credit tier assignment)
```

All four components are deployed and functional in the Phase 1 demo stack. The `PoolPauseAdapter` and `UtilisationOracle` are new contracts that wrap ClawLoan-specific functionality into the Atlas adapter/oracle interface, requiring no changes to Atlas's core contracts. The integration surface from ClawLoan's side is two interface additions: `repay()` callable from the kernel address, and `pauseBorrowing()` accessible via an `authorizedKeeper` mapping.

---

## 11. Deployment and Phasing

### 10.1 Contract Architecture

| Contract | Upgradeable | Justification |
|---|---|---|
| `SingletonVault` | UUPS proxy | Custody-critical; upgrade path required for security fixes |
| `CapabilityKernel` | UUPS proxy | Protocol logic; upgrade path required |
| `EnvelopeRegistry` | UUPS proxy | Condition tree evaluation logic evolves with extensions |
| `IntentExecutorFactory` | Not upgradeable | Stateless; fixed bytecode is a security property |
| `UniswapV3Adapter` | Not upgradeable | Stateless; new adapters deployed as new contracts |
| `AaveV3Adapter` | Not upgradeable | Stateless |

**Owner:** Protocol multisig. Upgrade transactions require M-of-N multisig approval.

### 10.2 Address Determinism

All contracts deploy via CREATE2 with salt `keccak256("atlas-protocol-v1")`. Same address on every chain. This enables:
- SDK address resolution without RPC calls
- Consistent `verifyingContract` address in EIP-712 domain across chains
- Clear cross-chain identity (same address, different domain separators per `chainId` — replay protected by design)

**Post-deployment validation (required before any integration):**

```
vault.code.length > 0
kernel.code.length > 0
kernel.vault() == address(vault)
uniswapAdapter.name() returns non-empty string
aaveAdapter.name() returns non-empty string
```

Do not announce or integrate until all five checks pass.

### 10.2.1 Protocol Fee Model

The protocol charges a basis-point fee on execution value, deducted at commit time from the output position before it is returned to the vault. The initial fee is 10 bps on swap volume and 0 bps on Aave supply/withdraw, payable in the output token. Strategy NFT royalties (up to 100 bps) are additive and flow to the strategy creator, not the protocol treasury. The fee rate is governable by the protocol multisig with a 48-hour timelock on any increase.

### 10.3 Phased Build Plan

**Phase 1 (Weeks 1–8): Core Protocol, Single Chain**

*In scope:*
- `SingletonVault` — deposit, withdraw, release, commit, encumber, unencumber; **token allowlist** (ERC-777/ERC-1363 excluded by default, protocol multisig-administered)
- `CapabilityKernel` — executeIntent, simulateIntent, revokeCapability, adapter registry, solver whitelist
- `IntentExecutorFactory` + `IntentExecutor` — CREATE2 ephemeral executor with same-tx selfdestruct and post-call approval revocation
- `UniswapV3Adapter` — exact input swaps via V3 router
- `AaveV3Adapter` — supply and withdraw

*Explicitly not in scope:*
- `EnvelopeRegistry` — no envelopes, no keeper execution
- Sub-capabilities — structs defined, delegation chains in Phase 2
- Solver market — whitelisted solver only
- Cross-chain — single chain only
- ZK circuits — none

*Target:* 5 AI agent integrations, $1M TVL, one complete audit.

**Phase 2 (Weeks 8–16): Envelopes + Sub-Capabilities + ZK Pilot**

*In scope:*
- `EnvelopeRegistry` with condition tree verification
- Sub-capability chain execution and constraint enforcement
- Keeper network (open permissionless participation)
- Chainlink oracle integration + TWAP leaf support
- Circuit 2 (sub-capability chain verification) — full spec and first proof
- Circuit 1 (selective disclosure proof) — initial build, keccak256 bridge; receipt accumulator design resolved

*Target:* Agent-liveness-independent execution demonstrated. One major DeFi integration. First verifying ZK proof on Base.

**Phase 3 (Weeks 16–24): Solver Market + ZK Production + Multi-Sig**

*In scope:*
- Open solver market with staking and slashing
- Circuit 1 (selective disclosure proof) — production deployment with receipt accumulator
- Circuit 4 (M-of-N aggregation for committees)
- Circuit 6 (Proof of Reserves)
- M-of-N Consensus Intent support
- ZK VerifierRegistry

*Target:* 3+ independent solvers. Protocol self-sustaining. First institutional compliance credential issued.

**Phase 4+: Cross-Chain + Privacy Migration**

*In scope:*
- Cross-chain nullifier coordination (Ethereum as root)
- Bridge adapters (LayerZero, CCIP)
- Aztec migration path for position commitments (Poseidon2 on-chain)
- ZK privacy-preserving collaborative funds

---

## 12. Open Questions and Future Work

The following questions are unresolved design decisions that will be addressed in Phase 2–3:

**Q1 — Hash function migration timeline:** At what N (intents per compliance proof) does the gas and proving cost of the keccak256 bridge justify migrating on-chain commitments to Poseidon2? Each intent requires two keccak256 bridge calls (~24,000 gates). Preliminary analysis suggests the crossover is around N > 200–300 intents per proof window, where the Poseidon2-native circuit is ~8× cheaper. A precise empirical crossover analysis with actual Barretenberg benchmarks is needed before Phase 3, as the theoretical gate count does not account for prover memory pressure at large circuit sizes.

**Q2 — Nullifier and receipt accumulators [Phase 2 prerequisite for Circuit 1]:** Two on-chain accumulators must be designed before the selective disclosure proof (Circuit 1) can achieve its full security properties: (a) a per-capability nullifier accumulator — a Merkle tree (or append-only log with Merkle root) of nullifiers indexed by `rootCapabilityHash`, enabling provers to demonstrate their disclosure covers a known slice of the capability's execution history; (b) a global receipt accumulator — a Merkle tree of `receiptHash` values from all `IntentExecuted` events, enabling the circuit to anchor receipts to on-chain state and prevent fabrication. Without (b), receipts are self-attested. Without (a), the proof is selective disclosure only (verifiers cannot determine what fraction of the capability's history is disclosed). Design options: protocol-run indexer (trusted), distributed indexer with consistency proofs (trust-minimized), or an on-chain accumulator contract updated on every kernel execution (trustless, ~20,000 extra gas per intent). The on-chain accumulator is the recommended target for institutional-grade compliance credentials. Phase 2 decision — must be resolved before Circuit 1 production deployment.

**Q3 — Keeper economic sustainability:** What is the minimum keeper reward (`keeperRewardBps`) needed to sustain a competitive keeper market for envelopes with long time horizons (e.g., a stop-loss registered for 365 days)? The keeper bears the gas cost of monitoring and triggering. Keeper incentive modeling is needed for Phase 2.

**Q4 — Cross-chain nullifier coordination:** When the protocol deploys on multiple chains, what prevents the same capability token from authorizing executions on both chains simultaneously? The EIP-712 domain separator includes `chainId`, preventing cross-chain signature replay. But `maxSpendPerPeriod` is enforced per-chain, not globally. Cross-chain global spend limits require a nullifier coordinator on a root chain. Phase 4 design question.

**Q5 — IVC readiness:** When will IVC/Nova folding be production-ready in Noir/Barretenberg? Circuit 1 (selective disclosure proof) should be redesigned to use incremental proving once IVC stabilizes — each new intent would be folded into the existing proof with O(1) marginal cost rather than requiring a full reprove of the window. Current estimate: 6–12 months from production-ready Barretenberg IVC support. Monitor the Barretenberg changelog.

**Q6 — PerformanceLeaf oracle:** The agent tournament capability (Tier 4.6) requires a `PerformanceLeaf` condition type that reads per-strategy returns from an on-chain performance registry. Designing a manipulation-resistant performance oracle is a non-trivial problem and is deferred to Phase 3 specification work.

---

## 13. Conclusion

Atlas addresses three gaps that every existing agent authorization standard explicitly defers: custody isolation, liveness-independent enforcement, and a privacy migration path.

The architecture is grounded in four clean separations — custody, identity, authorization, and enforcement — that are not a feature list but a consequence of treating each concern as a distinct primitive. When these concerns are conflated, compromise in any dimension propagates to the others. When they are separated, the blast radius of any failure is bounded and deterministic.

The commitment model is the load-bearing primitive. Positions as `keccak256(owner, asset, amount, salt)` commitments provide encumbrance isolation, UTXO-style atomicity, and a structurally direct path to Aztec private notes. This cannot be retrofitted onto an account balance model — it must be designed in from the start, which is why Phase 1 establishes it as the foundation rather than an optimization.

The ZK layer is honest about what it delivers. On a public EVM, ZK provides computation compression, proof-of-knowledge without full revelation, and portable compliance credentials. It does not provide private balances or hidden execution history. Circuit 1 (selective disclosure proof) and Circuit 2 (sub-capability chain verification) deliver the highest value for the lowest complexity and are the correct first circuits to build. Circuit 1 produces a verifiable credential that a disclosed set of executions satisfied constraints; once the receipt and nullifier accumulators are deployed in Phase 2, it becomes an anchored credential that cannot be fabricated or selectively backdated. IVC-based incremental proving is the theoretically correct long-term design for rolling compliance proofs, but is not production-ready today and should not be on the critical path for Phase 2 delivery.

The conditional settlement extensions — options, perpetuals, interest rate swaps, insurance, employment contracts — are not a second product. They are what the protocol becomes when the agent-specific assumptions are relaxed and the vault + condition tree + keeper network is recognized as general-purpose conditional settlement infrastructure. The agent use case is the correct beachhead. The settlement layer is what it grows into.

The core protocol guarantee — no agent signature can move more value than the capability bounds, regardless of agent behavior — is not a promise about AI alignment. It is an architectural property enforced by Solidity, cryptographic signatures, and an append-only nullifier registry. It holds whether the agent is honest, compromised, jailbroken, or destroyed. That is the correct threat model for autonomous AI agents interacting with financial protocols, and it is the design standard every agent infrastructure layer should be evaluated against.

---

## Appendix A: EIP-712 Type Hashes

**Array encoding rule (EIP-712 §4):** Dynamic array fields (`address[] allowedAdapters`, etc.) are encoded as `keccak256` of the concatenation of the ABI-encoded (32-byte padded) representation of each element. Each `address` is encoded as a 32-byte left-padded value (i.e., `abi.encode(addr)` → 32 bytes). An empty array encodes as `keccak256("")` (zero-length input). The struct hash substitutes the array's `keccak256` digest in place of the array itself.

**Two common encoding anti-patterns — both produce wrong hashes:**

1. `abi.encodePacked(address[])` — packs each address as **20 bytes** (not 32). Violates EIP-712.
2. `abi.encode(address[])` — includes ABI offset (32 bytes) + length (32 bytes) + elements. The extra prefix bytes change the hash. Also violates EIP-712.

Both cause `ecrecover` to silently return the wrong address with no error. The EIP-712 spec (§Definition of `enc`) requires: *"The array values are encoded as the keccak256 hash of the concatenated encodeData of their contents."* For `address`, `encodeData(a)` is the 32-byte left-zero-padded representation — identical to `abi.encode(a)` for a single address (not for an array). The correct pattern is element-by-element encoding:

```solidity
// CORRECT: iterate elements, encode each address to 32 bytes, concatenate, then hash
// Note: this is reference pseudocode showing correctness of encoding.
// Production implementation should pre-allocate: bytes memory encoded = new bytes(arr.length * 32);
// to avoid the O(n²) gas cost of repeated abi.encodePacked allocation on each iteration.
function _hashAddressArray(address[] memory arr) internal pure returns (bytes32) {
    bytes memory encoded = new bytes(arr.length * 32);  // pre-allocate: O(n) not O(n²)
    for (uint256 i = 0; i < arr.length; i++) {
        bytes32 padded = bytes32(uint256(uint160(arr[i])));  // left-pad address to 32 bytes
        assembly { mstore(add(add(encoded, 0x20), mul(i, 32)), padded) }
    }
    return keccak256(encoded);
    // Empty array: arr.length == 0 → encoded is zero-length → keccak256("") per EIP-712
}

// WRONG #1: packs addresses as 20 bytes each
// keccak256(abi.encodePacked(c.allowedAdapters))   ← DO NOT USE

// WRONG #2: includes 32-byte offset + 32-byte length prefix
// keccak256(abi.encode(c.allowedAdapters))          ← DO NOT USE
```

SDK and on-chain implementations must agree on this element-wise 32-byte encoding; any mismatch produces a hash that fails `ecrecover` silently with no error message.

```solidity
CONSTRAINTS_TYPEHASH = keccak256(
    "Constraints(uint256 maxSpendPerPeriod,uint256 periodDuration,uint256 minReturnBps,"
    "address[] allowedAdapters,address[] allowedTokensIn,address[] allowedTokensOut)"
);

// hashStruct(Constraints c) =
//   keccak256(abi.encode(
//     CONSTRAINTS_TYPEHASH,
//     c.maxSpendPerPeriod,
//     c.periodDuration,
//     c.minReturnBps,
//     _hashAddressArray(c.allowedAdapters),    // element-wise 32-byte encoding per above
//     _hashAddressArray(c.allowedTokensIn),
//     _hashAddressArray(c.allowedTokensOut)
//   ))

CAPABILITY_TYPEHASH = keccak256(
    "Capability(address issuer,address grantee,bytes32 scope,uint256 expiry,"
    "bytes32 nonce,Constraints constraints)"
    "Constraints(uint256 maxSpendPerPeriod,uint256 periodDuration,uint256 minReturnBps,"
    "address[] allowedAdapters,address[] allowedTokensIn,address[] allowedTokensOut)"
);

INTENT_TYPEHASH = keccak256(
    "Intent(bytes32 positionCommitment,bytes32 capabilityHash,address adapter,"
    "bytes adapterData,uint256 minReturn,uint256 deadline,bytes32 nonce,"
    "address outputToken,address returnTo)"
);
// Note: adapterData (bytes) is encoded as keccak256(adapterData) per EIP-712 dynamic bytes rule.

ENVELOPE_TYPEHASH = keccak256(
    "Envelope(bytes32 positionCommitment,bytes32 conditionsHash,bytes32 intentCommitment,"
    "bytes32 capabilityHash,uint256 expiry,uint256 keeperRewardBps)"
);
```

**EIP-712 Encoding Test Vector**

Implementors must verify their SDK's `hashStruct(Constraints)` output matches this reference *before* generating any capability signatures. A silent mismatch causes `ecrecover` to return the wrong signer address with no error. The reference script below is the ground truth; all on-chain and SDK implementations must produce identical intermediate bytes and final hashes.

*Test inputs:*

```
Constraints {
    maxSpendPerPeriod : 1_000_000_000          // 1,000 USDC (6 decimals)
    periodDuration    : 86_400                 // 1 day in seconds
    minReturnBps      : 9_900                  // 99% minimum return (1% max slippage)
    allowedAdapters   : [
        0xE592427A0AEce92De3Edee1F18E0157C05861564,  // Uniswap V3 SwapRouter
        0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45   // Uniswap V3 SwapRouter02
    ]
    allowedTokensIn   : [0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48]  // USDC (mainnet)
    allowedTokensOut  : [0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2]  // WETH (mainnet)
}
```

*Step-by-step encoding (all values hex):*

```
// Step 1: CONSTRAINTS_TYPEHASH
typeString = "Constraints(uint256 maxSpendPerPeriod,uint256 periodDuration," +
             "uint256 minReturnBps,address[] allowedAdapters," +
             "address[] allowedTokensIn,address[] allowedTokensOut)"
CONSTRAINTS_TYPEHASH = keccak256(typeString)   // run script to get exact value

// Step 2: Hash allowedAdapters (element-wise 32-byte encoding, two addresses)
encoded_adapters = concat(
    0x000000000000000000000000E592427A0AEce92De3Edee1F18E0157C05861564,  // 32 bytes
    0x00000000000000000000000068b3465833fb72A70ecDF485E0e4C7bD8665Fc45   // 32 bytes
)  // total: 64 bytes, NO offset/length prefix
adaptersHash = keccak256(encoded_adapters)     // run script to get exact value

// Step 3: Hash allowedTokensIn (one address)
encoded_tokensIn  = 0x000000000000000000000000A0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
tokensInHash  = keccak256(encoded_tokensIn)    // run script to get exact value

// Step 4: Hash allowedTokensOut (one address)
encoded_tokensOut = 0x000000000000000000000000C02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2
tokensOutHash = keccak256(encoded_tokensOut)   // run script to get exact value

// Step 5: hashStruct(Constraints)
constraintsHash = keccak256(abi.encode(
    CONSTRAINTS_TYPEHASH,
    uint256(1_000_000_000),   // maxSpendPerPeriod: 32 bytes
    uint256(86_400),          // periodDuration:    32 bytes
    uint256(9_900),           // minReturnBps:      32 bytes
    adaptersHash,             // bytes32:           32 bytes
    tokensInHash,             // bytes32:           32 bytes
    tokensOutHash             // bytes32:           32 bytes
))                            // total inner payload: 224 bytes
```

*Known boundary condition — empty array:*
```
keccak256("") = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470
```
An empty `allowedAdapters` array must produce exactly this hash (meaning: all registered adapters are permitted). This value is deterministic and can be hard-coded as a test assert.

*Reference verification script (ethers.js v6, Node.js ESM):*

```javascript
// save as verify-eip712.mjs  →  node verify-eip712.mjs
import { ethers, AbiCoder, keccak256, toUtf8Bytes } from "ethers";

const CONSTRAINTS_TYPE =
  "Constraints(uint256 maxSpendPerPeriod,uint256 periodDuration," +
  "uint256 minReturnBps,address[] allowedAdapters," +
  "address[] allowedTokensIn,address[] allowedTokensOut)";

const CONSTRAINTS_TYPEHASH = keccak256(toUtf8Bytes(CONSTRAINTS_TYPE));
console.log("CONSTRAINTS_TYPEHASH:", CONSTRAINTS_TYPEHASH);

// EIP-712 array hash: encode each element as a SEPARATE fixed-size "address" type
// (NOT "address[]" — that adds an offset + length prefix, violating EIP-712).
function hashAddressArray(addrs) {
  if (addrs.length === 0) return keccak256("0x");
  const coder = AbiCoder.defaultAbiCoder();
  const encoded = coder.encode(addrs.map(() => "address"), addrs);
  return keccak256(encoded);
}

const adapters   = [
  "0xE592427A0AEce92De3Edee1F18E0157C05861564",
  "0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45",
];
const tokensIn   = ["0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"];
const tokensOut  = ["0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"];

const adaptersHash  = hashAddressArray(adapters);
const tokensInHash  = hashAddressArray(tokensIn);
const tokensOutHash = hashAddressArray(tokensOut);

console.log("adaptersHash :", adaptersHash);
console.log("tokensInHash :", tokensInHash);
console.log("tokensOutHash:", tokensOutHash);

const coder = AbiCoder.defaultAbiCoder();
const constraintsHash = keccak256(coder.encode(
  ["bytes32","uint256","uint256","uint256","bytes32","bytes32","bytes32"],
  [
    CONSTRAINTS_TYPEHASH,
    1_000_000_000n,   // maxSpendPerPeriod
    86_400n,          // periodDuration
    9_900n,           // minReturnBps
    adaptersHash,
    tokensInHash,
    tokensOutHash,
  ]
));
console.log("constraintsHash (hashStruct):", constraintsHash);

// Boundary condition: empty array must produce the canonical keccak256("") value
const EMPTY_HASH = "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470";
console.assert(hashAddressArray([]) === EMPTY_HASH, "FAIL: empty array hash mismatch");
console.log("empty array boundary: PASS");
```

Run this script against every SDK implementation (TypeScript, Python `eth_abi`, Solidity test) and assert byte-for-byte identical `constraintsHash`. Divergence at any intermediate step (`adaptersHash`, `tokensInHash`, `tokensOutHash`) pinpoints the encoding error.

---

## Appendix B: Phase 1 Core Operation Gas Costs

Estimates for Base mainnet (EIP-1559 base fee ~0.05 gwei, cold storage reads assumed). Warm SLOAD ~100 gas; cold SLOAD ~2,100 gas; SSTORE (new slot) ~20,000 gas; ERC-20 transfer ~21,000–30,000 gas.

| Operation | Dominant cost drivers | Estimated gas |
|---|---|---|
| `vault.deposit(asset, amount, salt)` | ERC-20 transferFrom + SSTORE commitment | ~55,000–70,000 |
| `vault.withdraw(positionPreimage)` | SLOAD commitment + ERC-20 transfer + SSTORE delete | ~45,000–60,000 |
| `kernel.executeIntent(intent, intSig, cap, capSig)` | EIP-712 hash + ecrecover × 2 + SLOAD revocation + SSTORE nullifier + CREATE2 deploy + ERC-20 transfer × 2 + adapter call + approve(0) revocation + selfdestruct (same-tx EIP-6780) | ~200,000–270,000 |
| `kernel.simulateIntent(...)` | Same as executeIntent checks; no SSTORE | ~30,000–50,000 (view call, no gas cost to caller) |
| `kernel.revokeCapability(nonce)` | SSTORE revoked nonce | ~25,000–30,000 |
| `envelopeRegistry.register(envelope)` | SSTORE tree root + SSTORE expiry | ~50,000–70,000 |
| `envelopeRegistry.trigger(envelopeId)` | Oracle reads × N_leaves + condition eval + intent execution | ~250,000–400,000 |
| Lineage verification (depth 8) | 8 × cold SLOAD | +~16,800 |

*Note: These estimates do not include ZK proof verification. ZK verification adds ~230,000–400,000 gas per proof (see Appendix C).*

---

## Appendix B2: Protocol Constants (Phase 1, Locked)

| Constant | Value | Rationale |
|---|---|---|
| `MAX_CHAIN_DEPTH` | 8 | Bounds worst-case O(depth) lineage verification gas |
| `MAX_TREE_DEPTH` | 8 | Bounds worst-case condition tree evaluation gas |
| `MIN_POSITION_SALT_BITS` | 256 | Salt must be full 32-byte random value |
| `DEPLOYMENT_SALT` | `keccak256("atlas-protocol-v1")` | Address determinism across chains |
| `DOMAIN_VERSION` | `"1"` | Capability invalidation on kernel redeployment is intentional |

---

## Appendix C: Circuit Constraint Budget Summary

| Circuit | Hash function | Approx. gate count (N=100) | Proof system | Est. prove time | Est. verify gas |
|---|---|---|---|---|---|
| C1: Selective Disclosure (Phase 1, no receipt accum.) | keccak256 bridge (2× per intent) | ~2,745,000 | UltraHonk | 8–15 min | ~400,000 |
| C1: Selective Disclosure (Phase 2, with receipt accum.) | keccak256 bridge (2× per intent) | ~2,985,000 | UltraHonk | 9–17 min | ~420,000 |
| C1: Selective Disclosure (Phase 2, Poseidon2 on-chain) | Poseidon2 on-chain | ~585,000 | UltraHonk | 2–4 min | ~290,000 |
| C2: Sub-Cap Chain | Poseidon2 bridge | ~80,000–120,000 | UltraHonk | <30 sec | ~250,000 |
| C3: Condition Tree | Poseidon2 | ~40,000–80,000 | UltraHonk | <15 sec | ~230,000 |
| C4: M-of-N (M=5 ECDSA) | keccak256 | ~25,000 + overhead | UltraHonk | <10 sec | ~250,000 |
| C4: M-of-N (M=60 ECDSA) | keccak256 | ~280,000 + overhead | UltraHonk | ~2 min | ~280,000 |
| C6: Proof of Reserves | Poseidon2 bridge | ~400,000 (N=100 pos) | UltraHonk | 2–5 min | ~300,000 |

*All gate counts are ACIR-level approximations (Noir compiler output). UltraHonk backend expands ACIR gates by 2–5× into prover constraints; actual proving times will be higher than ACIR-only estimates suggest. Proving times are order-of-magnitude estimates for 32-core, 64 GB RAM commodity hardware — production benchmarks against actual Barretenberg builds are required before Phase 2 deployment. Circuit 1 gate counts with keccak256 bridge require TWO bridge calls per intent — one for `positionHash` and one for `nullifier` — at ~12,000 ACIR gates each. Verification gas estimates for Base L2 (EVM-equivalent execution). The Poseidon2 on-chain option (Option C) reduces C1 gate count by ~8× and becomes cost-justified at approximately N > 200–300 intents per proof window.*

---

*Atlas Protocol — Version 1.0*
*February 2026*
*Status: Draft for Review*

*This document is the design reference. DECISIONS.md is the locked implementation source of truth for Phase 1. Where they conflict, raise it explicitly — do not silently resolve in code.*

