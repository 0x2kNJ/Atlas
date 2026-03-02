# Stateless Agent Protocol — Design Specification

**Version:** 0.1  
**Status:** Draft  
**Date:** February 2026

---

## 0. Problem Statement

Every existing agent/account model makes the same mistake: the agent is the account.

- ERC-4337 smart accounts hold state, hold assets, and hold logic in one object.
- Session keys reduce scope but don't change the fundamental model.
- If the agent key is compromised, the account is compromised.
- Rotating an agent requires on-chain transactions from the original key.
- Recovery requires guardians or social recovery — all stateful, all slow.

AI agents are hot keys on servers. They will be compromised. They will be rate-limited. They will go offline. The protocol must handle all of this without requiring the agent to be present, and without making asset custody depend on agent integrity.

The correct model:

```
Agent   = signing key + capability token    (no on-chain presence)
Vault   = singleton commitment registry    (no user accounts)
Intent  = signed execution instruction     (stateless)
Kernel  = verifier + executor deployer     (minimal state: nullifiers only)
```

These are four different things. No current protocol separates them cleanly.

---

## 1. Design Principles

**1. Agents have zero on-chain footprint between actions.**  
An agent is a signing key with a capability token. Nothing is deployed. Nothing is registered. The agent does not exist on-chain until it submits an intent, and leaves no trace after execution except a spent nullifier.

**2. Asset custody is separated from agent identity.**  
Assets live in a singleton vault. Positions are tracked as `keccak256` commitments, not as `balances[userAddress]`. The vault has no concept of users. It only knows whether a commitment exists.

**3. Capabilities are scoped, expiring, and revocable off-chain.**  
Authorization is expressed as EIP-712 signed capability tokens. Revoking an agent requires one off-chain signature from the user — no on-chain transaction, no guardian, no timelock.

**4. Execution is atomic and ephemeral.**  
Each intent deploys a CREATE2 executor, executes atomically, and the executor holds no persistent state. No leftover approvals. No lingering contracts.

**5. Enforcement does not require agent liveness.**  
Envelopes are pre-committed conditional execution instructions. A stop-loss, liquidation threshold, or rebalancing trigger can be registered once and executed permissionlessly by any keeper when conditions are met — even if the agent is offline.

**6. The design ports directly to private execution.**  
The commitment model is identical to Aztec's note model. When private execution is added, public commitments become private notes with ZK proofs. No redesign required — only the proof system changes.

---

## 2. Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                        OFF-CHAIN                            │
│                                                             │
│   User Wallet                                               │
│       │                                                     │
│       ├── signs ──► Capability Token (EIP-712)              │
│       │              └── granted to: Agent Key              │
│       │              └── scope: vault.spend                 │
│       │              └── constraints: maxSpend, adapters    │
│       │              └── expiry, nonce                      │
│       │                                                     │
│   Agent Key (AI agent / hot key)                            │
│       │                                                     │
│       └── signs ──► Intent (EIP-712)                        │
│                      └── positionCommitment                 │
│                      └── adapter + adapterData              │
│                      └── minReturn                          │
│                      └── deadline, nonce                    │
│                                                             │
│   Solver                                                    │
│       └── picks up Intent + CapabilityToken                 │
│       └── submits to CapabilityKernel on-chain              │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                        ON-CHAIN                             │
│                                                             │
│   CapabilityKernel                                          │
│       │  - verifies capability token signature              │
│       │  - verifies intent signature                        │
│       │  - verifies constraints                             │
│       │  - checks nullifier not spent                       │
│       │  - deploys IntentExecutor (CREATE2)                 │
│       │  - marks nullifier spent                            │
│       │  - emits receipt                                    │
│       │                                                     │
│       ├──► SingletonVault                                   │
│       │       - releases position assets to executor        │
│       │       - nullifies old commitment                    │
│       │       - stores new commitment (output position)     │
│       │                                                     │
│       └──► IntentExecutor (ephemeral, CREATE2)              │
│               - receives assets from vault                  │
│               - calls adapter                               │
│               - returns output to vault                     │
│               - holds no storage                            │
│                                                             │
│   Adapter (Uniswap / Aave / Bridge)                         │
│       - validates parameters against allowlist              │
│       - executes protocol interaction                       │
│       - enforces minReturn constraint                       │
│                                                             │
│   EnvelopeRegistry                                          │
│       - stores committed conditional intents                │
│       - permissionless keeper execution                     │
│       - triggers when conditions are revealed + verified    │
└─────────────────────────────────────────────────────────────┘
```

---

## 3. Data Structures

### 3.1 Position Commitment

A position is not stored as `balances[user][token]`. It is stored as a hash commitment.

```solidity
struct Position {
    address owner;          // user's address (controls capability issuance)
    address asset;          // ERC-20 token address
    uint256 amount;         // token amount
    bytes32 salt;           // user-chosen randomness
}

// stored in vault as:
positionHash = keccak256(abi.encode(position));
```

The vault stores only:
```solidity
mapping(bytes32 positionHash => bool exists) public positions;
```

To spend a position, you must reveal the preimage. This means positions are not linkable unless observed at deposit time. It does not provide full privacy (public EVM), but it provides:
- No user account model in the contract
- Transferable positions (reveal + commit new owner)
- Direct path to Aztec private notes later

---

### 3.2 Capability Token

```solidity
struct Capability {
    address issuer;             // user who grants authority
    address grantee;            // agent key receiving authority
    bytes32 scope;              // keccak256("vault.spend") | keccak256("envelope.manage")
    uint256 expiry;             // unix timestamp
    bytes32 nonce;              // prevents capability replay
    Constraints constraints;
}

struct Constraints {
    uint256 maxSpendPerPeriod;  // max token amount per period (0 = unlimited)
    uint256 periodDuration;     // period in seconds (0 = no period limit)
    uint256 minReturnBps;       // minimum return as basis points of input (e.g. 9800 = 98%)
    address[] allowedAdapters;  // empty = all registered adapters allowed
    address[] allowedTokensIn;  // empty = all tokens allowed
    address[] allowedTokensOut; // empty = all tokens allowed
}
```

**Capability scopes:**

| Scope | Meaning |
|---|---|
| `keccak256("vault.spend")` | Spend positions from vault |
| `keccak256("vault.deposit")` | Create positions in vault |
| `keccak256("envelope.manage")` | Create / cancel envelopes |
| `keccak256("solver.execute")` | Submit intents as solver |

Capability token is signed by `issuer` as EIP-712 typed data. It is never submitted to chain independently — it is submitted alongside an intent.

Revocation: issuer can register the capability nonce as revoked in a lightweight `RevocationRegistry`. This is the only on-chain action required to revoke.

---

### 3.2a Sub-Capability (Delegation Chain)

A sub-capability allows an agent to delegate a subset of its authority to another agent. This enables multi-agent hierarchies (Orchestrator → Analyst → Execution) with cryptographic constraint inheritance.

```solidity
struct SubCapability {
    bytes32 parentCapabilityHash;   // keccak256(abi.encode(parentCapability))
    address issuer;                 // agent key re-delegating (grantee of parent)
    address grantee;                // downstream agent receiving authority
    bytes32 scope;                  // must equal or be subset of parent scope
    uint256 expiry;                 // must be <= parent expiry
    bytes32 nonce;                  // prevents sub-capability replay
    Constraints constraints;        // must be subset of parent constraints (enforced by kernel)
    bytes32[] lineage;              // ordered chain of capability hashes from root to parent
}
```

**Constraint inheritance rules enforced by CapabilityKernel:**
- `subCap.constraints.maxSpendPerPeriod ≤ parentCap.constraints.maxSpendPerPeriod`
- `subCap.constraints.minReturnBps ≥ parentCap.constraints.minReturnBps`
- `subCap.constraints.allowedAdapters ⊆ parentCap.constraints.allowedAdapters` (empty parent = all; empty sub = all allowed by parent)
- `subCap.expiry ≤ parentCap.expiry`
- `subCap.scope == parentCap.scope` (scope cannot be changed in a sub-capability)

**Revocation:** Revoking any capability in the `lineage` chain invalidates the sub-capability. The kernel checks `isRevoked` for every hash in `lineage` at execution time. This is O(chain depth) — maximum chain depth is 8 to bound verification cost.

**Period spending:** Period spending is tracked against the *root* capability hash, not the sub-capability hash. A chain A→B→C all share the same period spend counter as A. An agent at any level of the chain cannot exceed the root's `maxSpendPerPeriod`, regardless of what sub-constraints were granted.

---

### 3.3 Intent

```solidity
struct Intent {
    bytes32 positionCommitment; // position being spent (preimage revealed in execution)
    bytes32 capabilityHash;     // keccak256(abi.encode(capability))
    address adapter;            // which adapter to use
    bytes adapterData;          // encoded adapter parameters
    uint256 minReturn;          // minimum output amount
    uint256 deadline;           // unix timestamp
    bytes32 nonce;              // intent-specific nonce (nullifier seed)
    address outputToken;        // expected output token
    address returnTo;           // where to create output position (vault)
}
```

Intent is signed by `grantee` (agent key) as EIP-712 typed data.

Nullifier = `keccak256(intent.nonce, intent.positionCommitment)` — prevents replay.

---

### 3.4 Envelope

An envelope is a pre-committed conditional execution instruction. It allows agent-liveness-independent enforcement.

```solidity
struct Envelope {
    bytes32 positionCommitment; // position this envelope encumbers
    bytes32 conditionsHash;     // keccak256(abi.encode(conditions)) — not revealed until trigger
    bytes32 intentCommitment;   // keccak256(abi.encode(intent)) — revealed at trigger
    bytes32 capabilityHash;     // capability that authorized envelope creation
    uint256 expiry;             // envelope expires if not triggered
    uint256 keeperRewardBps;    // basis points of output given to keeper
}

struct Conditions {
    address priceOracle;        // oracle to check
    address baseToken;
    address quoteToken;
    uint256 triggerPrice;
    ComparisonOp op;            // LESS_THAN | GREATER_THAN | EQUAL
}

enum ComparisonOp { LESS_THAN, GREATER_THAN, EQUAL }
```

**Envelope lifecycle:**
1. Agent creates envelope (off-chain) and submits to `EnvelopeRegistry`
2. Position is marked as encumbered in vault (cannot be spent by other intents)
3. Keeper monitors conditions
4. When triggered: keeper reveals `Conditions` + `Intent` preimages, submits to registry
5. Registry verifies: `keccak256(conditions) == conditionsHash`, condition is currently true
6. Registry forwards intent to `CapabilityKernel` for execution
7. Keeper receives `keeperRewardBps` of output

---

### 3.5 Dead Man's Switch Envelope

An inverse envelope that fires when a condition *stops being maintained*, rather than when a condition becomes true. Enables autonomous recovery when all infrastructure goes silent.

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

**Lifecycle:**
1. Agent creates dead man envelope and submits to `EnvelopeRegistry`
2. Position encumbered in vault
3. Agent (or authorized address) calls `keepalive(envelopeHash)` at regular intervals — must be called within `heartbeatInterval` seconds
4. Any keeper can trigger by proving `block.timestamp - lastHeartbeat > heartbeatInterval`
5. Registry verifies condition, forwards intent to CapabilityKernel for execution
6. Keeper receives `keeperRewardBps` of output

**Keeper incentive:** Keepers are incentivized to *monitor* for missed heartbeats and trigger when the interval is exceeded. They receive the same reward structure as standard envelopes. The economic incentive ensures that a silent agent does not go undetected.

**New registry function:**
```solidity
function keepalive(bytes32 envelopeHash) external;
// Only callable by envelope.heartbeatAuthorizer
// Updates lastHeartbeat to block.timestamp
// Reverts if envelope is not a DeadManEnvelope
```

---

### 3.6 Consensus Intent (M-of-N Multi-Agent Authorization)

An intent that requires M valid capability signatures from an approved set of N agent keys before the kernel will execute. Enables AI risk committees where no single agent has unilateral authority over large executions.

```solidity
struct ConsensusPolicy {
    uint256 requiredSignatures;   // M — minimum signatures required
    bytes32 approvedSignerRoot;   // merkle root of approved agent key set
    uint256 signatureWindowSecs;  // all M signatures must be collected within this window
}

struct ConsensusIntent {
    Intent intent;                // the underlying execution instruction
    ConsensusPolicy policy;       // M-of-N requirements
    bytes32 policyHash;           // keccak256(abi.encode(policy))
}

// Off-chain accumulation — solver collects M signatures before submission:
struct ConsensusBundle {
    ConsensusIntent consensusIntent;
    Capability[] signerCapabilities;   // one capability per signer
    bytes[] capSigs;                   // one signature per capability
    bytes[] intentSigs;               // one signature per signer over consensusIntent.intent
    bytes32[][] merkleProofs;         // one merkle proof per signer (proving inclusion in approvedSignerRoot)
}
```

**Kernel verification for consensus intents:**
1. Verify `policyHash == keccak256(abi.encode(policy))`
2. For each signer i: verify `capSigs[i]` signs `signerCapabilities[i]`; verify `intentSigs[i]` signs the intent; verify `merkleProofs[i]` proves signer i is in `approvedSignerRoot`
3. Verify count of valid signers ≥ `policy.requiredSignatures`
4. Apply *most restrictive* constraints across all signer capabilities (intersection of allowedAdapters, minimum of maxSpendPerPeriod, maximum of minReturnBps)
5. Verify all signatures are within `signatureWindowSecs` of each other (timestamps in signatures)
6. Execute via standard pipeline

**Security property:** To force a malicious execution, an attacker must compromise or manipulate M independent agent systems simultaneously. With M = 3 and independent models/providers/contexts, this is orders of magnitude harder than single-agent compromise.

---

### 3.7 Conditional Capability

A capability that only activates when an external oracle condition holds. Collapses "is the agent authorized" and "is the market condition right" into a single verifiable object.

```solidity
struct ConditionalCapability {
    Capability capability;            // the underlying capability (constraints, scope, expiry)
    Conditions activationCondition;   // oracle condition that must be TRUE for capability to be active
    // If activationCondition is zeroed-out (priceOracle = address(0)), capability is always active
    // Same Conditions struct as Envelope — identical oracle check path
}
```

**Kernel check:** At `executeIntent` time, if `capability.activationCondition.priceOracle != address(0)`, the kernel performs the same oracle condition check it performs for envelope triggers. If the condition evaluates to `false`, the intent is rejected with `CAPABILITY_NOT_ACTIVE`. The capability is not revoked — it will be active again when market conditions change.

**Example use cases:**
- "Yield optimizer only authorized during low-volatility regimes" — reduces risk of optimizer acting in chaotic markets
- "Emergency sell capability only activates after agent has been silent 48 hours" — combined with dead man's switch heartbeat oracle
- "High-limit capability activates only when BTC dominance > 60%" — regime-based authorization

---

### 3.8 Composable Condition Tree

The `conditionsHash` in an envelope commits to the merkle root of a condition tree rather than a flat `Conditions` struct. Keepers reveal only the minimal satisfying path. The actual strategy logic remains private until the moment of execution.

---

#### 3.8.1 Why the Commitment Model is the Prerequisite

All existing conditional execution systems (Chainlink Automation, Gelato, Uniswap limit orders) store conditions publicly at registration time. The strategy is immediately visible to MEV bots and competitors.

Atlas stores `conditionsHash = keccak256(merkle_root(tree))`. The condition tree is private. At trigger time, the keeper reveals only the minimal path that satisfies the root — atomically with execution. There is no window between "strategy known" and "trade executed."

This privacy property is what makes complex multi-condition strategies safe to pre-commit. Without it, a multi-condition tree is just a more complex public strategy waiting to be front-run. With it, the strategy is cryptographically private until the moment it is irreversibly executed.

---

#### 3.8.2 Condition Node Types

```solidity
// Node type discriminator
enum ConditionNodeType { LEAF_PRICE, LEAF_TIME, LEAF_VOLATILITY, LEAF_ONCHAIN, COMPOSITE }

// Price/ratio oracle comparison (existing Conditions, generalized)
struct PriceLeaf {
    address oracle;          // Chainlink / Pyth / custom price oracle
    address baseToken;
    address quoteToken;
    uint256 threshold;       // price * 1e8 (Chainlink convention)
    ComparisonOp op;         // LESS_THAN | GREATER_THAN | EQUAL
}

// Block timestamp comparison (enables time-based and DCA strategies)
struct TimeLeaf {
    uint256 threshold;       // unix timestamp or modulo value
    ComparisonOp op;
    bool modulo;             // if true: check (block.timestamp % moduloBase) op threshold
    uint256 moduloBase;      // e.g. 604800 for weekly DCA
}

// Realized volatility or implied volatility oracle comparison
struct VolatilityLeaf {
    address oracle;          // vol oracle (e.g. Volmex, custom TWAP-variance oracle)
    address asset;
    uint256 windowSecs;      // lookback window the oracle computes over
    uint256 threshold;       // annualized vol * 1e4 (e.g. 8000 = 80% annualized)
    ComparisonOp op;
}

// Arbitrary on-chain state: any contract view function returning uint256
struct OnChainStateLeaf {
    address target;          // contract to call
    bytes4 selector;         // view function selector (must be in protocol allowlist)
    uint256 threshold;       // value to compare against
    ComparisonOp op;
    // Example: Aave ETH utilization rate, Uniswap pool TVL, Compound APY
}

// Boolean combinator (internal node)
struct CompositeNode {
    BoolOp op;               // AND | OR
    bytes32 leftHash;        // keccak256(abi.encode(nodeType, nodeData)) of left child
    bytes32 rightHash;       // keccak256(abi.encode(nodeType, nodeData)) of right child
}

enum BoolOp { AND, OR }
enum ComparisonOp { LESS_THAN, GREATER_THAN, EQUAL, LESS_THAN_OR_EQUAL, GREATER_THAN_OR_EQUAL }
```

---

#### 3.8.3 Tree Commitment

The tree root is computed bottom-up:

```solidity
// Leaf hash
bytes32 leafHash = keccak256(abi.encode(ConditionNodeType.LEAF_PRICE, priceLeaf));

// Internal node hash
bytes32 nodeHash = keccak256(abi.encode(ConditionNodeType.COMPOSITE, compositeNode));
// where compositeNode.leftHash and compositeNode.rightHash are child hashes

// The envelope stores:
conditionsHash = root_hash_of_tree;
```

The root hash is the only on-chain commitment. The full tree structure, oracle addresses, thresholds, and boolean logic are private until trigger time.

---

#### 3.8.4 Keeper Revelation and On-Chain Verification

At trigger time, the keeper reveals a `ConditionProof` — the minimal subtree that proves the root evaluates to `true`:

```solidity
struct ConditionProof {
    ConditionProofNode[] nodes;  // ordered from root to satisfying leaves
}

struct ConditionProofNode {
    ConditionNodeType nodeType;
    bytes nodeData;              // abi.encoded leaf or composite struct
    bytes32 siblingHash;         // hash of the unexpanded sibling (for AND nodes only)
    // For OR nodes: only the true child needs to be revealed; sibling stays hidden
    // For AND nodes: both children must be revealed; siblingHash is unused
}
```

**On-chain verification algorithm:**

```
function verifyConditionProof(bytes32 conditionsHash, ConditionProof proof) returns (bool):
    computedRoot = evaluateNode(proof.nodes[0], proof.nodes)
    return computedRoot == conditionsHash

function evaluateNode(node, allNodes) returns (bytes32 nodeHash):
    if node.nodeType == COMPOSITE:
        composite = abi.decode(node.nodeData, CompositeNode)
        if composite.op == OR:
            // Reveal only one child — the one that evaluates to true
            leftResult = evaluateNode(findNode(composite.leftHash, allNodes))
            if leftResult.satisfied:
                return keccak256(abi.encode(COMPOSITE, composite))  // hash matches, OR is satisfied
            rightResult = evaluateNode(findNode(composite.rightHash, allNodes))
            require(rightResult.satisfied)
            return keccak256(abi.encode(COMPOSITE, composite))
        if composite.op == AND:
            // Both children must be revealed and satisfied
            leftResult = evaluateNode(findNode(composite.leftHash, allNodes))
            rightResult = evaluateNode(findNode(composite.rightHash, allNodes))
            require(leftResult.satisfied AND rightResult.satisfied)
            return keccak256(abi.encode(COMPOSITE, composite))
    if node.nodeType == LEAF_PRICE:
        leaf = abi.decode(node.nodeData, PriceLeaf)
        price = leaf.oracle.latestAnswer()
        satisfied = evaluate(price, leaf.op, leaf.threshold)
        return keccak256(abi.encode(LEAF_PRICE, leaf))
    // ... similar for TIME, VOLATILITY, ONCHAIN leaf types
```

**Privacy property of OR nodes:** For an OR node, only the true child's subtree is revealed. The false child's subtree remains as its hash only. An observer learns which branch of the OR satisfied the condition, but not the full strategy tree. If the tree has N OR nodes in the critical path, the unexpanded subtrees of the false branches remain private — permanently, because the envelope is spent after a single trigger.

---

#### 3.8.5 Gas Analysis

| Tree structure | Revealed nodes | Oracle calls | Approximate gas |
|---|---|---|---|
| Single leaf (current model) | 1 | 1 | ~15k |
| AND(leaf, leaf) | 2 | 2 | ~28k |
| OR(leaf, leaf) — one branch true | 1 | 1 | ~18k |
| AND(OR(leaf,leaf), leaf) | 2–3 | 2–3 | ~40k |
| Depth-4 balanced tree | 4–8 | 4–8 | ~80–120k |

Gas cost scales with the number of revealed nodes and oracle calls in the satisfying path, not the total tree size. A strategy with 16 leaf conditions in a balanced tree where only 3 conditions need to be checked for the satisfying path costs ~40k gas, not 16 × 15k.

Maximum tree depth is capped at 8 (protocol parameter, governance-adjustable) to bound worst-case gas.

---

#### 3.8.6 OnChainStateLeaf — the Protocol Monitoring Primitive

`OnChainStateLeaf` allows any contract view function returning `uint256` to be a trigger condition. The callable selector set is a protocol allowlist (governance-controlled) to prevent calls to arbitrary contracts that could be used for reentrancy, gas griefing, or state manipulation during verification.

**Initial allowlisted selectors:**

```
Aave V3 Pool:       getReserveData(address).currentLiquidityRate     → yield APY
Aave V3 Pool:       getReserveData(address).availableLiquidity       → pool liquidity
Compound V3:        getUtilization()                                  → utilization rate
Uniswap V3 Pool:    liquidity()                                       → pool TVL proxy
Chainlink Feed:     latestAnswer()                                    → any price feed
TWAP Oracle:        consult(address,uint32)                           → TWAP price
```

**Example: Protocol health monitoring envelope**
```
AND(
  OnChainStateLeaf(AaveV3.getReserveData(USDC).currentLiquidityRate > 15%),  // APY spike
  OnChainStateLeaf(AaveV3.getReserveData(USDC).availableLiquidity < 1M USDC) // liquidity drain
)
→ intent: withdraw from Aave yield position
```
This envelope triggers when Aave USDC simultaneously has a high yield rate AND low available liquidity — the pattern that precedes a potential bank run. No human monitoring required. No centralized keeper service required.

---

#### 3.8.7 Strategy Composition Pattern

A complete multi-stage strategy is expressed as a set of coordinated envelopes, each encumbering a fraction of the total position:

```typescript
// Cascade de-risking: 25% at $2000, 25% at $1800, 50% at $1500
// Three positions, each encumbered by its own envelope

const [pos25a, pos25b, pos50] = await sdk.splitPosition(ethPosition, [0.25, 0.25, 0.50]);

const envelope1 = await sdk.createEnvelope({
  positionCommitment: pos25a.hash,
  conditionTree: sdk.buildTree('ETH/USD < 2000'),
  triggerIntent: sdk.sellIntent(pos25a, USDC),
  keeperRewardBps: 30,
});

const envelope2 = await sdk.createEnvelope({
  positionCommitment: pos25b.hash,
  conditionTree: sdk.buildTree('ETH/USD < 1800'),
  triggerIntent: sdk.sellIntent(pos25b, USDC),
  keeperRewardBps: 40,
});

const envelope3 = await sdk.createEnvelope({
  positionCommitment: pos50.hash,
  conditionTree: sdk.buildTree('ETH/USD < 1500'),
  triggerIntent: sdk.sellIntent(pos50, USDC),
  keeperRewardBps: 50,
});

// All three registered. Full cascade strategy active.
// Agent can go offline. All three stages will fire permissionlessly.
```

`sdk.splitPosition()` creates N sub-positions from one commitment, each a valid vault commitment that can be individually encumbered. The kernel enforces that the sum of sub-positions equals the original — no value leakage.

---

#### 3.8.8 SDK: Natural Language to Condition Tree

```typescript
// Build from structured DSL
const tree = sdk.conditionTree.and(
  sdk.conditionTree.price('ETH/USD', 'LESS_THAN', 1800),
  sdk.conditionTree.volatility('ETH', '24h', 'GREATER_THAN', 0.80)
);

// Build from natural language (LLM-assisted parsing)
const tree2 = await sdk.conditionTree.parse(
  "sell if ETH drops below $1800 during high volatility, or if it falls below $1500 regardless"
);

// Validate against oracle allowlist before commitment
const validation = await sdk.conditionTree.validate(tree2);
// { valid: true, oraclesRequired: ['ETH/USD Chainlink', 'ETH 24h vol oracle'], estimatedGas: 42000 }

// Simulate against historical data
const simulation = await sdk.conditionTree.simulate(tree2, { lookbackDays: 180 });
// { triggerCount: 3, dates: [...], pricesAtTrigger: [...], wouldHaveProtected: '$12,400' }

// Commit (hash the tree, never reveal until trigger)
const envelope = await sdk.createEnvelope({ conditionTree: tree2, ... });
```

---

#### 3.8.9 Backward Compatibility

A single-condition envelope is a tree of depth 1 containing one `PriceLeaf`. The existing `Conditions` struct is serialized as a `PriceLeaf`. `conditionsHash = keccak256(abi.encode(LEAF_PRICE, conditions))`. All existing envelopes are valid trees with depth 1 — no migration, no breaking change.

---

### 3.9 ZK Constraint Compliance Proof

An agent can generate a zero-knowledge proof that all N of its executed intents complied with its capability constraints, without revealing any individual trade.

**Circuit public inputs:**
- `capabilityConstraintsHash` — the constraints the agent was bound by
- `N` — number of intents proved
- `nullifierSetRoot` — merkle root of the set of spent nullifiers being proved over

**Circuit private inputs:**
- The N intent preimages (adapter, amountIn, amountOut, deadline, etc.)
- The N execution receipts (amountOut achieved, oracle price at execution)

**What the circuit proves:**
- For all N intents: `amountIn ≤ maxSpendPerPeriod` (within respective period buckets)
- For all N intents: `amountOut / amountIn ≥ minReturnBps`
- For all N intents: `adapter ∈ allowedAdapters`
- The N nullifiers correspond to the `nullifierSetRoot` (verifiable against on-chain state)
- The nullifier set is a *subset* of the on-chain spent nullifier set — prover cannot cherry-pick

**Proof output:** A constant-size proof (PLONK or Groth16) that any verifier can check against on-chain state in one call. The proof is portable — it can be submitted to any protocol, wallet, or institution that wants to verify the agent's compliance history.

**SDK function:**
```typescript
const proof = await sdk.generateComplianceProof({
  agentKey: agent.address,
  capabilityHash: hashCapability(capability),
  fromBlock: deploymentBlock,
  toBlock: 'latest'
});
// proof.verify() → true/false
// proof.summary → { intentsProved: N, violationRate: 0, constraintsHash }
```

---

## 4. Contract Interfaces

### 4.1 SingletonVault

```solidity
interface ISingletonVault {
    /// @notice Deposit tokens and create a position commitment
    /// @param asset Token to deposit
    /// @param amount Amount to deposit
    /// @param salt User-chosen salt for commitment
    /// @return positionHash The commitment hash
    function deposit(
        address asset,
        uint256 amount,
        bytes32 salt
    ) external returns (bytes32 positionHash);

    /// @notice Withdraw by revealing position preimage
    /// @param position Full position struct (preimage)
    /// @param to Recipient address
    function withdraw(
        Position calldata position,
        address to
    ) external;

    /// @notice Called only by CapabilityKernel: release assets to executor
    /// @param positionHash Commitment to spend
    /// @param position Position preimage (verified against hash)
    /// @param to Executor address to send assets to
    function release(
        bytes32 positionHash,
        Position calldata position,
        address to
    ) external;

    /// @notice Called only by CapabilityKernel: store output position
    /// @param asset Output asset
    /// @param amount Output amount
    /// @param owner Position owner
    /// @param salt New salt for output commitment
    /// @return newPositionHash
    function commit(
        address asset,
        uint256 amount,
        address owner,
        bytes32 salt
    ) external returns (bytes32 newPositionHash);

    /// @notice Encumber a position (used by EnvelopeRegistry)
    function encumber(bytes32 positionHash) external;

    /// @notice Release encumbrance
    function unencumber(bytes32 positionHash) external;

    // --- View ---

    function positionExists(bytes32 positionHash) external view returns (bool);
    function isEncumbered(bytes32 positionHash) external view returns (bool);

    // --- Events ---

    event PositionCreated(bytes32 indexed positionHash, address indexed asset, uint256 amount);
    event PositionSpent(bytes32 indexed positionHash);
    event PositionEncumbered(bytes32 indexed positionHash);
}
```

---

### 4.2 CapabilityKernel

```solidity
interface ICapabilityKernel {
    /// @notice Execute a capability-authorized intent
    /// @param position Position preimage being spent
    /// @param capability Capability token granting authority
    /// @param intent Execution instruction
    /// @param capSig Issuer's signature over capability
    /// @param intentSig Grantee's signature over intent
    /// @return receiptHash Hash of execution receipt
    function executeIntent(
        Position calldata position,
        Capability calldata capability,
        Intent calldata intent,
        bytes calldata capSig,
        bytes calldata intentSig
    ) external returns (bytes32 receiptHash);

    /// @notice Check if a nullifier has been spent
    function isSpent(bytes32 nullifier) external view returns (bool);

    /// @notice Check if a capability nonce has been revoked
    function isRevoked(address issuer, bytes32 nonce) external view returns (bool);

    /// @notice Issuer revokes a capability by nonce
    function revokeCapability(bytes32 nonce) external;

    /// @notice Register an adapter (governance/owner controlled)
    function registerAdapter(address adapter) external;

    // --- Events ---

    event IntentExecuted(
        bytes32 indexed nullifier,
        bytes32 indexed positionIn,
        bytes32 indexed positionOut,
        address adapter,
        uint256 amountIn,
        uint256 amountOut,
        bytes32 receiptHash       // keccak256(nullifier, posIn, posOut, adapter, amountIn, amountOut, timestamp)
    );
    event IntentRejected(
        bytes32 indexed capabilityHash,
        address indexed grantee,
        bytes32 reason,           // keccak256 of human-readable error key e.g. keccak256("PERIOD_LIMIT_EXCEEDED")
        uint256 spentThisPeriod,
        uint256 periodLimit
    );
    event CapabilityRevoked(address indexed issuer, bytes32 indexed nonce);
}
```

---

### 4.3 IntentExecutor

The executor is deployed via CREATE2 per intent. It is not a persistent contract.

```solidity
interface IIntentExecutor {
    /// @notice Called once by kernel after deployment
    /// @param vault Singleton vault address
    /// @param adapter Adapter to call
    /// @param adapterData Encoded adapter parameters
    /// @param outputToken Expected output token
    /// @param minReturn Minimum acceptable output
    /// @param outputSalt Salt for output position commitment
    function execute(
        address vault,
        address adapter,
        bytes calldata adapterData,
        address outputToken,
        uint256 minReturn,
        bytes32 outputSalt
    ) external;
}
```

Executor holds no storage. It:
1. Receives asset transfer from vault
2. Approves adapter to spend the asset
3. Calls `adapter.execute(...)`
4. Verifies `amountOut >= minReturn`
5. Transfers output to vault
6. Vault calls `commit()` to create output position

---

### 4.4 Adapter Interface

```solidity
interface IAdapter {
    /// @notice Get expected output for given input
    function quote(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        bytes calldata data
    ) external view returns (uint256 amountOut);

    /// @notice Execute the protocol interaction
    /// @return amountOut Actual output amount
    function execute(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        bytes calldata data
    ) external returns (uint256 amountOut);

    /// @notice Validate parameters before execution
    function validate(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        bytes calldata data
    ) external view returns (bool valid, string memory reason);

    /// @notice Human-readable adapter name
    function name() external view returns (string memory);
}
```

**Adapter implementations for MVP:**
- `UniswapV3Adapter` — exact input swaps via V3 router
- `AaveV3Adapter` — supply, withdraw, borrow, repay

---

### 4.5 EnvelopeRegistry

```solidity
interface IEnvelopeRegistry {
    /// @notice Register a conditional execution envelope
    /// @param envelope Envelope struct
    /// @param capSig Issuer signature over capability
    /// @param intentSig Grantee signature over committed intent
    /// @return envelopeHash
    function register(
        Envelope calldata envelope,
        Capability calldata capability,
        bytes calldata capSig,
        bytes calldata intentSig
    ) external returns (bytes32 envelopeHash);

    /// @notice Trigger an envelope — called by keeper
    /// @param envelopeHash Hash of registered envelope
    /// @param conditions Revealed conditions preimage
    /// @param intent Revealed intent preimage
    function trigger(
        bytes32 envelopeHash,
        Conditions calldata conditions,
        Intent calldata intent
    ) external;

    /// @notice Cancel an envelope — called by issuer only
    function cancel(bytes32 envelopeHash) external;

    function envelopeExists(bytes32 envelopeHash) external view returns (bool);

    // --- Events ---

    event EnvelopeRegistered(bytes32 indexed envelopeHash, bytes32 indexed positionCommitment);
    event EnvelopeTriggered(bytes32 indexed envelopeHash, address indexed keeper);
    event EnvelopeCancelled(bytes32 indexed envelopeHash);
}
```

---

## 5. Execution Flows

### Flow 1: Deposit

```
User
 │
 ├── approve(vault, amount) on ERC-20 token
 └── vault.deposit(asset, amount, salt)
       │
       ├── transferFrom(user, vault, amount)
       ├── positionHash = keccak256(user, asset, amount, salt)
       ├── positions[positionHash] = true
       └── emit PositionCreated(positionHash, asset, amount)

Result: Position exists as commitment. No user account created.
```

---

### Flow 2: Create Agent + Delegate Capability

```
User (off-chain)
 │
 ├── generate or designate agentKey (AI agent's hot key)
 │
 └── sign Capability {
       issuer:       user.address,
       grantee:      agentKey,
       scope:        keccak256("vault.spend"),
       expiry:       now + 7 days,
       nonce:        random bytes32,
       constraints: {
           maxSpendPerPeriod: 1000 USDC,
           periodDuration:    86400,       // 1 day
           minReturnBps:      9800,        // 98% minimum return
           allowedAdapters:   [uniswapAdapter],
           allowedTokensIn:   [USDC],
           allowedTokensOut:  [ETH, WBTC]
       }
     }

Result: Capability token (off-chain EIP-712 signed struct).
        Agent key can now create intents within these constraints.
        Nothing touches chain.
```

---

### Flow 3: Execute Intent (Swap)

```
Agent (off-chain)
 │
 └── sign Intent {
       positionCommitment: positionHash,
       capabilityHash:     keccak256(capability),
       adapter:            uniswapV3Adapter,
       adapterData:        abi.encode(USDC, ETH, 1000e6, poolFee),
       minReturn:          0.38 ether,
       deadline:           now + 5 minutes,
       nonce:              random bytes32,
       outputToken:        ETH,
       returnTo:           vault
     }

Solver
 │
 └── kernel.executeIntent(position, capability, intent, capSig, intentSig)

CapabilityKernel
 │
 ├── VERIFY: capSig is valid signature by capability.issuer over capability
 ├── VERIFY: intentSig is valid signature by capability.grantee over intent
 ├── VERIFY: capability.expiry > block.timestamp
 ├── VERIFY: capability.scope == keccak256("vault.spend")
 ├── VERIFY: intent.adapter is in capability.constraints.allowedAdapters
 ├── VERIFY: intent.deadline > block.timestamp
 ├── VERIFY: nullifier = keccak256(intent.nonce, intent.positionCommitment) not spent
 ├── VERIFY: vault.positionExists(intent.positionCommitment)
 ├── VERIFY: vault.isEncumbered(intent.positionCommitment) == false
 ├── VERIFY: adapter.validate(tokenIn, tokenOut, amount, adapterData) == true
 │
 ├── nullifiers[nullifier] = true
 │
 ├── vault.release(positionCommitment, position, executorAddress)
 │     └── vault transfers 1000 USDC to executorAddress
 │
 ├── deploy IntentExecutor via CREATE2(salt = intent nonce)
 │
 └── executor.execute(vault, uniswapAdapter, adapterData, ETH, minReturn, outputSalt)
       │
       ├── approve(uniswapAdapter, 1000 USDC)
       ├── uniswapAdapter.execute(USDC, ETH, 1000e6, 0.38 ether, poolData)
       │     └── executes swap on Uniswap V3
       │     └── returns 0.392 ETH
       ├── VERIFY: 0.392 ether >= 0.38 ether (minReturn check)
       ├── transfer 0.392 ETH to vault
       └── vault.commit(ETH, 0.392 ether, user.address, outputSalt)
             └── newPositionHash stored
             └── emit PositionCreated(newPositionHash, ETH, 0.392e18)

Result: Input position nullified. Output position committed. Agent has no on-chain trace.
```

---

### Flow 4: Register Envelope (Stop-Loss)

```
Agent (off-chain)
 │
 ├── create Conditions {
 │     priceOracle:  chainlinkETHUSD,
 │     baseToken:    ETH,
 │     quoteToken:   USD,
 │     triggerPrice: 1800e8,   // $1800
 │     op:           LESS_THAN
 │   }
 │
 ├── create Intent to sell ETH position if triggered
 │     (signed by agent key, same structure as normal intent)
 │
 └── create Envelope {
       positionCommitment: ethPositionHash,
       conditionsHash:     keccak256(abi.encode(conditions)),
       intentCommitment:   keccak256(abi.encode(intent)),
       capabilityHash:     keccak256(abi.encode(capability)),
       expiry:             now + 30 days,
       keeperRewardBps:    50    // 0.5% to keeper
     }

Agent
 └── envelopeRegistry.register(envelope, capability, capSig, intentSig)
       │
       ├── verify capability authorizes envelope.manage scope
       ├── verify envelope.conditionsHash is properly formed
       ├── vault.encumber(positionCommitment)
       └── envelopes[envelopeHash] = envelope

Result: Position encumbered. Cannot be spent by other intents until envelope is
        cancelled or triggered.
```

---

### Flow 5: Trigger Envelope (Keeper Execution)

```
Keeper (any address)
 │
 ├── monitors Chainlink ETH/USD price
 ├── price drops to $1795
 │
 └── envelopeRegistry.trigger(envelopeHash, conditions, intent)
       │
       ├── VERIFY: keccak256(conditions) == envelope.conditionsHash
       ├── VERIFY: keccak256(intent) == envelope.intentCommitment
       ├── VERIFY: block.timestamp < envelope.expiry
       ├── VERIFY: conditions.priceOracle.price() LESS_THAN conditions.triggerPrice
       │
       ├── vault.unencumber(positionCommitment)
       ├── forward intent to CapabilityKernel.executeIntent(...)
       │     └── (same flow as Flow 3)
       │
       └── transfer keeperRewardBps of output to msg.sender (keeper)

Result: Stop-loss executed. Keeper rewarded. Agent was offline — didn't matter.
```

---

### Flow 6: Revoke Agent

```
User (off-chain or on-chain)
 │
 └── kernel.revokeCapability(capability.nonce)
       │
       └── revokedNonces[user][nonce] = true

Result: Any future intent submission referencing this capability will fail at
        kernel.executeIntent verification step.
        No contract migration. No guardian interaction.
        Any in-flight intent with this capability will fail.
        Agent key is now worthless without a valid capability.
```

---

## 6. EIP-712 Domain and Type Hashes

```solidity
// Domain
DOMAIN_TYPEHASH = keccak256(
    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
);

// Constraints
CONSTRAINTS_TYPEHASH = keccak256(
    "Constraints(uint256 maxSpendPerPeriod,uint256 periodDuration,uint256 minReturnBps,"
    "address[] allowedAdapters,address[] allowedTokensIn,address[] allowedTokensOut)"
);

// Capability
CAPABILITY_TYPEHASH = keccak256(
    "Capability(address issuer,address grantee,bytes32 scope,uint256 expiry,"
    "bytes32 nonce,Constraints constraints)"
    "Constraints(uint256 maxSpendPerPeriod,uint256 periodDuration,uint256 minReturnBps,"
    "address[] allowedAdapters,address[] allowedTokensIn,address[] allowedTokensOut)"
);

// Intent
INTENT_TYPEHASH = keccak256(
    "Intent(bytes32 positionCommitment,bytes32 capabilityHash,address adapter,"
    "bytes adapterData,uint256 minReturn,uint256 deadline,bytes32 nonce,"
    "address outputToken,address returnTo)"
);

// Envelope
ENVELOPE_TYPEHASH = keccak256(
    "Envelope(bytes32 positionCommitment,bytes32 conditionsHash,bytes32 intentCommitment,"
    "bytes32 capabilityHash,uint256 expiry,uint256 keeperRewardBps)"
);
```

---

## 7. Security Model

### 7.1 Threat: Compromised Agent Key

- Agent key is compromised
- Attacker creates and submits intents

**Mitigations:**
- Capability constraints bound maximum damage (maxSpendPerPeriod)
- User can revoke capability in one transaction: `kernel.revokeCapability(nonce)`
- Attacker cannot exceed capability constraints even with agent key
- Any in-flight intents from compromised key fail after revocation

**Compare to 4337 session key:** Session key compromise on a smart account requires an on-chain key rotation transaction, which must come from the master key or guardian — and there is a window between compromise and rotation where the attacker can drain up to the session scope.

---

### 7.2 Threat: Solver/Executor Misbehavior

- Solver submits valid intent but sandwiches the execution
- Solver delays execution past deadline

**Mitigations:**
- `intent.minReturn` is an absolute floor enforced on-chain by executor
- `intent.deadline` causes revert if exceeded
- Adapters enforce parameter bounds independently
- Multiple solvers can race to fill — censorship resistant

---

### 7.3 Threat: Vault Draining

- Attacker crafts capability + intent to drain vault

**Mitigations:**
- Capability must be signed by position owner
- Capability issuer must match position owner in commitment
- Kernel verifies issuer == position.owner
- Null capability (no valid signature) is rejected at verification step

---

### 7.4 Threat: Replay Attack

- Attacker resubmits a spent intent

**Mitigations:**
- Nullifier = `keccak256(nonce, positionCommitment)` stored permanently
- Once spent, position commitment is deleted from vault
- Both nullifier AND commitment must not exist — double protection

---

### 7.5 Threat: Envelope Manipulation

- Keeper submits false conditions to trigger envelope early

**Mitigations:**
- Conditions hash is committed at envelope registration
- Keeper must reveal exact preimage matching `conditionsHash`
- On-chain oracle check is performed after preimage verification
- Keeper cannot lie about oracle price — it's read on-chain at trigger time

---

### 7.6 Attack Surface Summary

| Component | State held | Attack surface |
|---|---|---|
| SingletonVault | Position commitments, encumbrances | Custody isolation critical — no cross-position leakage |
| CapabilityKernel | Nullifiers, revoked nonces | Signature verification correctness, EIP-712 domain separation |
| IntentExecutor | None (ephemeral) | Approval leak between creation and execution (CREATE2 frontrun) |
| Adapters | None | Parameter validation bypass, reentrance on output transfer |
| EnvelopeRegistry | Envelope commitments | Oracle manipulation, commitment preimage collision |

---

## 8. CREATE2 Executor Address Derivation

The executor address is deterministic and computed before deployment:

```solidity
bytes32 salt = keccak256(abi.encode(intent.nonce, intent.positionCommitment));
address executorAddress = address(
    uint160(uint256(keccak256(abi.encodePacked(
        bytes1(0xff),
        address(kernel),
        salt,
        keccak256(executorBytecode)
    ))))
);
```

This address is computed by the kernel before calling `vault.release(...)`. The vault sends assets to this address. The executor is then deployed to this exact address. No frontrun is possible because:
- The executor bytecode is fixed and public
- The salt includes the intent nonce which is in the signed intent
- Deploying to an address that already received funds is the intended behavior

---

## 9. Period Spending Limits

To enforce `maxSpendPerPeriod` from capability constraints, the kernel tracks per-capability spending:

```solidity
mapping(bytes32 capabilityHash => mapping(uint256 periodIndex => uint256 spent))
    public periodSpending;

uint256 periodIndex = block.timestamp / capability.constraints.periodDuration;
uint256 currentSpend = periodSpending[capabilityHash][periodIndex];

require(
    currentSpend + intent.position.amount <= capability.constraints.maxSpendPerPeriod,
    "PERIOD_LIMIT_EXCEEDED"
);

periodSpending[capabilityHash][periodIndex] += intent.position.amount;
```

Note: This is the only piece of per-capability state in the kernel. Everything else is global (nullifiers) or off-chain.

---

## 10. SDK Interface (TypeScript)

```typescript
// Create a capability token
const capability = await sdk.createCapability({
  grantee: agentKey.address,
  scope: "vault.spend",
  expiry: Date.now() / 1000 + 7 * 86400,
  constraints: {
    maxSpendPerPeriod: parseUnits("1000", 6),  // 1000 USDC
    periodDuration: 86400,
    minReturnBps: 9800,
    allowedAdapters: [UNISWAP_V3_ADAPTER],
    allowedTokensIn: [USDC],
    allowedTokensOut: [WETH],
  },
});
// Returns: { capability, signature } — sign with user wallet

// Agent creates intent
const intent = await sdk.createIntent({
  positionCommitment: position.hash,
  capabilityHash: hashCapability(capability),
  adapter: UNISWAP_V3_ADAPTER,
  adapterData: encodeUniswapSwap({ tokenIn: USDC, tokenOut: WETH, fee: 500 }),
  minReturn: parseEther("0.38"),
  deadline: Date.now() / 1000 + 300,
  outputToken: WETH,
  returnTo: VAULT_ADDRESS,
});
// Returns: { intent, signature } — sign with agent key

// Submit to solver network
await sdk.submitIntent({ intent, capability, intentSig, capSig });

// Create a stop-loss envelope
const envelope = await sdk.createEnvelope({
  positionCommitment: ethPosition.hash,
  conditions: {
    priceOracle: CHAINLINK_ETH_USD,
    baseToken: WETH,
    quoteToken: USDC,
    triggerPrice: parseUnits("1800", 8),
    op: "LESS_THAN",
  },
  triggerIntent: sellIntent,
  expiry: Date.now() / 1000 + 30 * 86400,
  keeperRewardBps: 50,
});
await sdk.registerEnvelope({ envelope, capability, capSig, intentSig });

// Revoke agent
await sdk.revokeCapability(capability.nonce);
// Single on-chain tx — agent is immediately disabled
```

---

## 11. MVP Scope

### Phase 1 — Single Chain, Single Operator (weeks 1–8)

**Contracts:**
- `SingletonVault` — deposit, withdraw, release, commit, encumber
- `CapabilityKernel` — executeIntent, revokeCapability, adapter registry
- `IntentExecutor` — ephemeral executor, CREATE2 factory
- `UniswapV3Adapter` — exact input swaps
- `AaveV3Adapter` — supply and withdraw

**Off-chain:**
- TypeScript SDK: capability creation, intent signing
- Single operator solver (you run it)
- Basic intent monitoring UI

**Not in Phase 1:**
- Solver market
- Envelopes
- Cross-chain

**Target:** 5 AI agent integrations, $1M TVL, one complete audit

---

### Phase 2 — Envelopes + Keeper Network (weeks 8–16)

**Contracts:**
- `EnvelopeRegistry` — register, trigger, cancel
- Chainlink oracle integration
- Keeper reward distribution

**Off-chain:**
- Keeper monitoring service (open to anyone)
- Envelope creation in SDK
- UI for stop-loss / rebalancing setup

**Target:** Demonstrate agent-liveness-independent execution. One major DeFi protocol integration.

---

### Phase 3 — Solver Market (weeks 16–24)

**Contracts:**
- Solver registry with stake
- Competitive fill mechanism
- Fee distribution

**Target:** 3+ independent solvers, protocol becomes self-sustaining.

---

### Phase 4 — Multi-Chain

**Contracts:**
- Cross-chain nullifier coordinator (Ethereum)
- Bridge adapters
- Chain-agnostic agent identity

**Target:** Same agent key, same capability token, execution on Base + Arbitrum + Ethereum.

---

## 12. Open Design Questions

These are unresolved decisions that need answers before implementation:

| # | Question | Options | Recommendation |
|---|---|---|---|
| 1 | Should position commitments include the owner address? | Yes (simpler revocation) / No (more private) | Yes for v1, remove for Aztec port |
| 2 | Executor: transfer-then-execute or approval pattern? | Transfer (simpler) / Approval (more flexible) | Transfer for v1 |
| 3 | Capability revocation: on-chain registry or merkle exclusion set? | Registry (simpler) / Merkle (scalable) | Registry for v1 |
| 4 | Period spending limits: per capability hash or per (issuer, grantee) pair? | Per hash (cleaner) / Per pair (more flexible) | Per hash |
| 5 | Envelope conditions: on-chain oracle only or off-chain attestation? | On-chain oracle (trustless) / Attestation (flexible) | On-chain oracle only for v1 |
| 6 | Should the vault support ERC-721 and ERC-1155? | Yes / No | No for v1, ERC-20 only |
| 7 | Solver permissioning at launch: whitelisted or open? | Whitelisted (safer) / Open (decentralized) | Whitelisted for v1 |
| 8 | Sub-capability chain depth limit: 4, 8, or unbounded? | 4 (low gas) / 8 (practical chains) / Unbounded (flexible, risky) | 8 for v1 |
| 9 | Period spend counter: root capability hash or per-chain level? | Root (prevents aggregation attacks) / Per-level (more flexible) | Root for v1 |
| 10 | IntentRejected event: on-chain or off-chain SDK only? | On-chain (auditable, gas ~3k) / Off-chain only (no gas, less auditable) | On-chain for v1 |

---

## 13. Deployment

### Contracts

```
SingletonVault.sol      — upgradeable proxy (UUPS), owner = multisig
CapabilityKernel.sol    — upgradeable proxy (UUPS), owner = multisig
EnvelopeRegistry.sol    — upgradeable proxy (UUPS), owner = multisig
IntentExecutorFactory.sol — not upgradeable (ephemeral, low risk)
UniswapV3Adapter.sol    — not upgradeable
AaveV3Adapter.sol       — not upgradeable
```

### Target Networks (Phase 1)

- Base (primary — low gas, AI agent developer concentration)
- Arbitrum (secondary — DeFi TVL)

### Addresses

All contracts share same address across chains via CREATE2 with salt = `keccak256("stateless-agent-protocol-v1")`.

---

## 14. Competitive Analysis

### 14.1 ERC-8004: Trustless Agents

**What it is:** Three on-chain registries for agent identity and trust. An Identity Registry (ERC-721 NFTs giving each agent a permanent on-chain handle), a Reputation Registry (feedback from completed tasks, scored off-chain), and a Validation Registry (crypto-economic, zkML, or TEE-based verification). Co-authored by MetaMask, Ethereum Foundation, Google, and Coinbase. Published August 2025.

**What it solves:** Agent discovery and trust across organizations. An agent marketplace problem.

**What it does not touch:** How agents are authorized to spend user assets. How capabilities are scoped. How positions are managed or held. Execution, custody, delegation, privacy — none of it.

**The philosophical conflict:**

ERC-8004 builds on the premise that agents should have persistent on-chain identities. This protocol builds on the opposite premise: agents should have zero on-chain presence until they act and leave no trace after.

ERC-8004's reputation system is backward-looking and gameable — establish track record on small tasks, exploit large ones. Capability constraints are forward-looking and cryptographically enforced regardless of reputation history. A `maxSpendPerPeriod` constraint cannot be bypassed by a high reputation score.

**Relationship:** This protocol can reference an 8004 agent ID in a capability's metadata without adopting its custody or authorization model. They target different layers. 8004 answers "can I trust this agent at all." This protocol answers "here are the exact constraints within which this agent is authorized, enforced on-chain."

---

### 14.2 ERC-8001: Agent Coordination Framework

**What it is:** Multi-party coordination for intents. An initiator posts an intent, participants post EIP-712 acceptance attestations, the intent becomes executable when all acceptances are present. Canonical lifecycle: None → Proposed → Ready → Executed/Cancelled/Expired. Published August 2025.

**What it deliberately omits** (from its own spec): privacy, reputation, threshold policies, bonding, cross-chain semantics.

**What it does not solve:** Single user delegating authority to a single AI agent. Asset custody. Capability scoping. Liveness-independent enforcement. The execution mechanics after "Ready" state are out of scope.

**Relationship:** This protocol is a superset. The single-agent execution flow is the primary case. Multi-agent coordination that 8001 describes could be built as an envelope variant where multiple capability proofs must be present before triggering. The custody, execution, and enforcement primitives that 8001 explicitly omits are what this protocol provides.

---

### 14.3 MetaMask Delegation Toolkit (ERC-7710 + ERC-7715)

This is the most direct architectural competitor.

**What it is:** A delegation framework built on ERC-7710. Three concepts: a DeleGator (smart account, ERC-4337 based, UUPS proxy, must be deployed), a Delegation (on-chain object with caveats, stored in a DelegationManager singleton, creating one costs gas), and Caveat Enforcers (arbitrary smart contract bytecode that enforces delegation restrictions).

| Dimension | MetaMask Delegation Toolkit | This Protocol |
|---|---|---|
| User must deploy a contract | Yes — DeleGator required | No |
| Delegation stored on-chain | Yes — DelegationManager | No — off-chain EIP-712 |
| Creating a delegation costs gas | Yes | No |
| Agent revocation | On-chain tx to DelegationManager | `revokeCapability(nonce)` — 1 tx |
| Constraint model | Caveat Enforcer contracts (arbitrary bytecode) | Declarative `Constraints` struct |
| Custody | Assets in DeleGator account (per-user) | Singleton vault, commitment-based |
| Per-user contract | Yes | No |
| Privacy | None | Commitment model, Aztec path |
| Conditional enforcement | Not natively | Envelopes |
| Ecosystem | MetaMask-specific | Universal |

**The caveat enforcer problem:** Caveat Enforcer contracts are arbitrary bytecode. Every new constraint type requires a new audited contract. Enforcement logic can have reentrancy bugs or logic errors. The audit surface scales with the number of caveat types deployed. This protocol's `Constraints` struct is a fixed-schema declarative object — verification is a set of bounded comparisons in the kernel, no arbitrary code execution.

**The account dependency problem:** MDT requires a DeleGator smart account per user. For 10,000 users that is 10,000 deployed contracts, each requiring a deployment transaction, each a separate attack surface, each requiring independent upgrades on vulnerability discovery. This protocol deploys zero per-user contracts.

**The EIP-7702 variant — full analysis:**

EIP-7702 allows an EOA to temporarily adopt smart contract code in the same transaction. MetaMask's `EIP7702StatelessDeleGator` uses this to give any EOA delegation capabilities without a deployment transaction. This is a real friction reduction over the standard DeleGator path.

What 7702 solves compared to standard MDT:
- Eliminates the account deployment transaction
- Any EOA gets delegation capabilities without migrating assets

What 7702 does not solve (and where the architectural gap persists):

| Problem | EIP-7702 MDT | This Protocol |
|---|---|---|
| Liveness-independent enforcement | No — EOA must be present to execute delegation code | Yes — envelopes fire without EOA or agent online |
| Commitment-based custody | No — EOA balance model unchanged | Yes — positions as discrete encumberable commitments |
| MEV protection for conditional execution | No | Yes — Flashbots Protect + threshold-encrypted adapterData |
| Multi-agent sub-capability chains | Partial — delegation can chain but constraint inheritance is not enforced | Yes — kernel enforces constraint subset at each link |
| Zero-footprint agent rotation | No — 7702 re-delegation requires the original EOA to transact | Yes — new capability issued off-chain; no on-chain transaction |
| Aztec portability | No — EOA balance model cannot map to private notes | Yes — commitment model is identical to Aztec note model |

The fundamental issue: 7702 is still account-centric. The EOA IS the custody object. An agent authorized via 7702 delegation is authorized to act on that account's behalf — if the account's assets are in the account, a compromised delegation path compromises the assets. This protocol separates custody (SingletonVault) from authorization (CapabilityKernel) entirely.

**The correct answer to "why not just use EIP-7702":** 7702 solves the consent problem (cheaper, frictionless authorization). It does not touch the enforcement problem, the liveness problem, or the custody isolation problem. Same as the MetaMask delegation analysis: it's the consent rail, not the enforcement rail.

---

### 14.4 Coinbase AgentKit + CDP Wallet

This is the most dangerous near-term competitive threat and is underanalyzed in most competitive frameworks.

**What Coinbase has:** AgentKit (developer framework with pre-built DeFi tool integrations), CDP Wallet (key management and custody), Base (L2 with the highest AI agent developer concentration), Coinbase Wallet (millions of end users), and distribution through the Coinbase exchange.

**What AgentKit ships today:** Session keys on ERC-4337 smart accounts, basic ERC-20 approval management, tool-calling APIs for common DeFi interactions. Authorization model: session keys with configurable scope.

**The threat scenario:** Coinbase adds conditional execution ("if price < X, execute Y") to AgentKit using CDP-managed keeper infrastructure, and ships it as a one-line SDK call. Suddenly every AgentKit developer has "envelope-like" functionality without migrating to a new protocol.

**Why this scenario doesn't win outright:**

| Dimension | Coinbase AgentKit + CDP | This Protocol |
|---|---|---|
| Custody model | CDP Wallet (centralized; Coinbase holds keys) | User-controlled singleton vault; non-custodial |
| Enforcement | CDP-run keeper (centralized; can be censored or shut down) | Permissionless keeper network; no single point of failure |
| Agent key compromise | Session key scope = maximum loss | Capability constraints = bounded loss regardless |
| MEV protection | Not specified | Flashbots Protect + threshold encryption |
| Multi-chain | Base-native; cross-chain through Coinbase Bridge | Native multi-chain via chain-agnostic nullifier design |
| Delegation chains | Not supported | Sub-capabilities with cryptographic constraint inheritance |
| Privacy path | None | Aztec migration via commitment model |
| Censorship resistance | CDP can freeze operations | `emergencyWithdraw` always available; keeper market permissionless |
| Open standard | Proprietary to Coinbase | ERC-authoring intent; conformance test suite |

**The structural issue with CDP enforcement:** Any keeper infrastructure Coinbase runs is a Coinbase business unit. It can be regulated, shut down, or rate-limited. A permissionless keeper market with economic incentives is censorship-resistant by construction. For institutional users and anyone outside the US regulatory perimeter, this difference is load-bearing.

**The acquisition risk:** Coinbase could acquire a team building the correct architecture and ship it within 6 months. This is the scenario that closes the window quickly. The mitigation is not architectural — it is distribution speed. Three framework integrations and a live keeper network before this scenario unfolds.

---

### 14.5 ERC-8126: AI Agent Registration and Verification

An agent self-registration standard with wallet verification, staking verification, and a unified 0-100 risk scoring system. Same category as ERC-8004 — agent identity and verification. Same fundamental problem: on-chain agent identities are traceable, gameable, and unnecessary for execution security. A risk score of 95/100 does not stop a compromised agent key from acting within its session scope. A `maxSpendPerPeriod` constraint does.

---

### 14.5 ERC-7857: AI Agents NFT with Private Metadata

Agent metadata as NFTs with private metadata via TEE or ZK proofs. Focus: representing agent ownership and identity as a transferable asset. Adjacent to identity, not to execution or custody. The "private metadata" use case protects agent configuration (endpoints, skills), not user positions.

---

### 14.6 ERC-7579: Modular Smart Accounts

Defines a standard module interface for smart accounts. A UCAN-inspired capability module built as a 7579 executor could replicate approximately 60% of the EVM-side functionality of this protocol within the existing smart account ecosystem. This is a real competitive risk for Phase 1. What it cannot replicate: commitment-based custody with no per-user contracts, liveness-independent enforcement (no envelope primitive), off-chain capability issuance where module state must live in the account, and Aztec portability since the account model cannot cleanly map to note commitments.

---

### 14.7 The Structural Gap All of Them Share

Every standard above has at least one of these failures:

**Account-centric custody:** MDT, ERC-7579, ERC-6900, ERC-4337 all tie custody to a smart account. Agent authority is bounded by account state.

**On-chain agent identity:** ERC-8004, ERC-8126, ERC-7857 all give agents on-chain presence. Permanent surveillance and attack surface.

**Online agent required for enforcement:** None have a liveness-independent enforcement primitive. If the agent is offline when a condition is met, nothing executes.

**No privacy path:** None model positions as commitments that can migrate to private note systems. All public by design.

**Single-concern scope:** Each standard solves one layer (identity OR coordination OR delegation OR intents) and explicitly defers the rest. This protocol solves the full execution stack as a coherent unit.

```
┌──────────────────────────────────────────────────────┐
│  Agent Identity / Discovery                           │
│  ERC-8004, ERC-8126, ERC-7857                        │
├──────────────────────────────────────────────────────┤
│  Multi-Agent Coordination                             │
│  ERC-8001                                            │
├──────────────────────────────────────────────────────┤
│  Delegation / Authorization                           │
│  ERC-7710 (MetaMask), ERC-7579 modules               │
├──────────────────────────────────────────────────────┤
│  Intent Execution                                     │
│  ERC-7521, ERC-7683                                  │
├──────────────────────────────────────────────────────┤
│  Custody                           ← GAP             │
├──────────────────────────────────────────────────────┤
│  Liveness-Independent Enforcement  ← GAP             │
├──────────────────────────────────────────────────────┤
│  Privacy Path                      ← GAP             │
└──────────────────────────────────────────────────────┘

This protocol:
  Capability Token    → Delegation layer
  SingletonVault      → Custody layer (fills gap)
  CapabilityKernel    → Authorization + execution verification
  Envelopes           → Enforcement layer (fills gap)
  Commitment model    → Privacy path (fills gap)
```

---

## 15. Differentiation Summary

| Property | This Protocol | MetaMask Toolkit | ERC-8004 | ERC-4337 | ERC-7683 |
|---|---|---|---|---|---|
| Agent on-chain identity | No | Yes (DeleGator) | Yes (ERC-721) | Yes (account) | No |
| Per-user contract | No | Yes | Yes | Yes | No |
| Delegation storage | Off-chain | On-chain | On-chain | On-chain | N/A |
| Delegation gas cost | Zero | Yes | Yes | Yes | N/A |
| Revocation | 1 tx | 1 on-chain tx | Registry update | Guardian/timelock | N/A |
| Constraint model | Declarative struct | Arbitrary bytecode | Reputation score | Session key scope | None |
| Custody model | Commitment-based | Account balance | N/A | Account balance | Filler-based |
| Liveness-independent exec | Yes (envelopes) | No | No | Via modules | No |
| Privacy path | Yes (Aztec) | No | No | No | No |
| AI agent threat model | Designed for it | Partial | Partial | Partial | No |
| Ecosystem dependency | None | MetaMask | None | 4337 bundlers | Filler network |
