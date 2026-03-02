# Atlas Protocol — Locked v1 Design Decisions
**Status: Locked for Phase 1 implementation**
**Source: SPEC.md §12 open questions + §11 MVP scope + §13 deployment**
**Date: February 2026**

Do not reopen these in code review. If a decision needs revisiting, update this file explicitly with a rationale before changing implementation. Changes to locked decisions require interface-level review — they are not local refactors.

---

## Decision 1 — Position Commitments Include `owner`

**Locked:** YES — position preimage is `keccak256(abi.encode(owner, asset, amount, salt))`.

**Rationale:** Simpler revocation — the kernel can verify `capability.issuer == position.owner` directly from the revealed preimage without additional indirection. The privacy cost (owner address in preimage) is acceptable on public EVM. Position transfers require reveal + recommit with new owner.

**Implementation implication:** `SingletonVault.deposit()` takes `(address asset, uint256 amount, bytes32 salt)` and derives `positionHash` using `msg.sender` as owner. The `Position` struct is `{ address owner, address asset, uint256 amount, bytes32 salt }`.

**Phase 3 note:** Owner field is removed when migrating to the ZK note model. Plan the struct layout so `owner` is the first field — easiest to drop or replace with a derived spending key later.

---

## Decision 2 — Executor Pattern: Transfer-Then-Execute

**Locked:** Transfer assets from vault to executor before calling the adapter. No approval pattern.

**Rationale:** Simpler execution flow. Executor receives assets, calls adapter, returns output to vault. No lingering approvals on the vault after execution. Executor is ephemeral (CREATE2) and holds no storage.

**Implementation implication:** `SingletonVault.release()` transfers `position.amount` of `position.asset` to the executor address before the executor is deployed. The executor address is pre-computed via CREATE2 — this is safe because the executor bytecode is fixed and the salt includes `intent.nonce`. See §8 of SPEC for derivation.

**No approval pattern means:** The vault never calls `approve()` on any token. The executor never needs to be approved. Any PR that adds `approve()` to the vault is a red flag.

---

## Decision 3 — Capability Revocation: On-Chain Registry

**Locked:** Revocation is a flat `mapping(address issuer => mapping(bytes32 nonce => bool))` in the CapabilityKernel. One `revokeCapability(bytes32 nonce)` transaction from the issuer. Merkle exclusion sets are Phase 4+.

**Rationale:** Simple, cheap, immediately auditable. The registry approach costs one storage write per revocation — acceptable for the expected revocation frequency at launch. Merkle exclusion sets provide no benefit until revocation volume is high enough to make the mapping expensive.

**Implementation implication:** `CapabilityKernel` stores `mapping(address => mapping(bytes32 => bool)) public revokedNonces`. `executeIntent` checks `revokedNonces[capability.issuer][capability.nonce]` before execution. Sub-capability chains check every hash in `lineage` against this mapping.

---

## Decision 4 — Period Spending: Tracked Against Root Capability Hash

**Locked:** Period spending is tracked against `keccak256(abi.encode(rootCapability))`, not against `(issuer, grantee)` pairs. All sub-capabilities in a delegation chain share the root's spending counter.

**Rationale:** Prevents aggregation attacks where an agent issues many sub-capabilities to bypass the root's `maxSpendPerPeriod`. A chain A→B→C cannot collectively exceed A's period limit regardless of what limits B and C were individually granted.

**Implementation implication:**
```solidity
mapping(bytes32 capabilityHash => mapping(uint256 periodIndex => uint256 spent)) public periodSpending;
uint256 periodIndex = block.timestamp / capability.constraints.periodDuration;
```
For sub-capabilities, the kernel must resolve the root capability hash from `lineage[0]` and check/update spending against that hash — not against the sub-capability hash.

---

## Decision 5 — Envelope Conditions: On-Chain Oracle Only

**Locked:** Condition evaluation reads on-chain oracle state only. No off-chain attestations, no signed price feeds that bypass on-chain verification. Allowlisted oracle selectors only (see §3.8.6 for initial allowlist).

**Rationale:** Off-chain attestations introduce a trusted party. On-chain oracle reads are trustless and verifiable by anyone. The allowlist prevents reentrancy and gas griefing during condition verification.

**Implementation implication:** `EnvelopeRegistry.trigger()` calls oracle view functions directly during the trigger transaction. The `OnChainStateLeaf.selector` must be in the protocol's allowlist mapping. Any oracle not on the allowlist causes an immediate revert — not a graceful failure.

---

## Decision 6 — Vault Supports ERC-20 Only

**Locked:** `SingletonVault` holds ERC-20 tokens only. No ERC-721, no ERC-1155, no native ETH.

**Rationale:** Simplifies the vault interface, custody model, and audit surface for Phase 1. NFT and native ETH support added in Phase 2+ once the core model is audited.

**Implementation implication:** `deposit()`, `release()`, and `commit()` all use `IERC20` transfers. Any token transfer in the vault uses `SafeERC20`. The `Position.asset` field is always an ERC-20 contract address. Validation: `require(asset != address(0))` and check `asset.code.length > 0` at deposit time.

---

## Decision 7 — Solver Permissioning: Whitelisted at Launch

**Locked:** Only whitelisted solver addresses can call `CapabilityKernel.executeIntent()` at launch. Whitelist is controlled by the protocol multisig. Open permissionless solving is Phase 3.

**Rationale:** Reduces MEV attack surface and simplifies the initial deployment. A whitelisted solver can be trusted to route through Flashbots Protect. An open solver market requires stake, slashing, and competitive fill mechanics that are out of Phase 1 scope.

**Implementation implication:** `CapabilityKernel` has `mapping(address => bool) public approvedSolvers`. `executeIntent()` begins with `require(approvedSolvers[msg.sender], "NOT_APPROVED_SOLVER")`. The multisig address can call `setSolver(address, bool)`.

**Phase 3 note:** When opening to permissionless solvers, the `approvedSolvers` check is removed and replaced with stake-based registration. The interface does not change — only the gate condition changes.

---

## Decision 8 — Sub-Capability Chain Depth: Maximum 8

**Locked:** `SubCapability.lineage` array length is capped at 8. The kernel reverts if `lineage.length > 8`.

**Rationale:** Bounds worst-case gas for lineage verification. Depth-8 covers all practical orchestrator→specialist→execution agent hierarchies. Unbounded depth would allow gas griefing through deep delegation chains.

**Implementation implication:** `CapabilityKernel.executeIntent()` checks `lineage.length <= MAX_CHAIN_DEPTH` where `MAX_CHAIN_DEPTH = 8` is an immutable constant. This check happens before any revocation lookups.

---

## Decision 9 — IntentRejected Event: On-Chain

**Locked:** `IntentRejected` is emitted on-chain when the kernel rejects an intent (constraint violation, revoked capability, expired deadline, etc.). Gas cost is ~3k additional per rejection.

**Rationale:** On-chain rejection events make the kernel's enforcement auditable without relying on SDK tooling or off-chain indexers. This is load-bearing for the ZK compliance proof (Circuit 1) — the compliance proof must account for rejections in the agent's history, and on-chain events are the canonical source.

**Implementation implication:**
```solidity
event IntentRejected(
    bytes32 indexed capabilityHash,
    address indexed grantee,
    bytes32 reason,           // keccak256 of error key e.g. keccak256("PERIOD_LIMIT_EXCEEDED")
    uint256 spentThisPeriod,
    uint256 periodLimit
);
```
Rejection paths use `emit IntentRejected(...)` before reverting. Do not use `revert` alone.

---

## Decision 10 — IntentExecutor / CREATE2 Factory: Superseded, Not Built

**Locked:** `IntentExecutor` and `IntentExecutorFactory` are **not built for Phase 1**. The CREATE2 ephemeral executor pattern described in SPEC.md §8 and DECISIONS.md Decision 2 is superseded by the kernel-direct model already implemented.

**Why the design changed:**

The original concern was leftover approvals. The SPEC's CREATE2 approach solved this by deploying an ephemeral contract per intent that holds no persistent state. The current implementation achieves the same guarantee more efficiently:

1. `vault.release()` transfers assets directly to the kernel (`address(this)`) within a single transaction.
2. The kernel does `IERC20.forceApprove(adapter, amount)` before calling the adapter.
3. The kernel does `IERC20.forceApprove(adapter, 0)` immediately after — zeroing the approval before any external call can observe it.
4. No approval is left after the transaction completes.

The CREATE2 deployment adds ~30k gas overhead per intent (deployment cost) and introduces a frontrun surface (CREATE2 preimage attack) that requires additional mitigations. The kernel-as-transient-executor eliminates both.

**Decision 2 amendment:** Decision 2's implementation implication is superseded. The vault releases to `address(kernel)`, not to a pre-computed executor address. The "no approval on vault" invariant still holds — the vault never approves anything; only the kernel does, and only transiently.

**What this means for the codebase:**
- `IntentExecutorFactory.sol` — do not create.
- `IntentExecutor.sol` — do not create.
- Any PR that introduces these contracts should be rejected unless Decision 10 is explicitly reopened with a written rationale.

**Implementation gap — Decision 7 (Solver Whitelist):** DECISIONS.md Decision 7 specifies `mapping(address => bool) public approvedSolvers` in `CapabilityKernel`. This is **not yet implemented**. The current kernel uses `intent.submitter` for per-intent MEV protection but has no protocol-level solver whitelist. This must be added before mainnet. Tracked as a pre-audit gap.

**Implementation gap — Decision 8 (Delegation Depth Cap):** DECISIONS.md Decision 8 specifies `lineage.length <= MAX_CHAIN_DEPTH (8)`. The current kernel enforces `delegationDepth == 0` (root-only, Phase 1). The full lineage cap enforcement belongs in Phase 2. The current guard is correct and sufficient for Phase 1.

**Decision 9 (IntentRejected event): CLOSED.** `emit IntentRejected(capabilityHash, grantee, reason, spentThisPeriod, periodLimit)` is now emitted before every revert in `executeIntent`. Twenty-two distinct reason codes (`REASON_*` public constants on the kernel) map to each rejection path. `spentThisPeriod` / `periodLimit` are non-zero only on `PERIOD_LIMIT_EXCEEDED`. The ZK compliance circuit (Phase 2, Circuit 1) can now consume this event.

---

## Phase 1 Scope — What Is and Is Not Being Built

**Built and tested (Phase 1 — current state):**
- `SingletonVault` ✓ — deposit, withdraw, release, encumber, unencumber (50 tests)
- `CapabilityKernel` ✓ — executeIntent, solver whitelist, revokeCapability, period spending, adapter registry (53 tests)
- `EnvelopeRegistry` ✓ — register, trigger, cancel, expire, keeper payment, rescueTokens (56 tests) — *built ahead of schedule; tested and locked*
- `UniswapV3Adapter` ✓ — built, **fork tests pending**
- `AaveV3Adapter` ✓ — built, **fork tests pending**
- `HashLib` ✓ — canonical EIP-712 hashing library
- `Deploy.s.sol`, `RegisterAdapters.s.sol` ✓ — deployment scripts

**Removed from Phase 1 (see Decision 10):**
- `IntentExecutorFactory` + `IntentExecutor` — superseded by kernel-direct execution model

**Pre-audit gaps (closed):**
- Solver whitelist (`approvedSolvers` mapping) — **DONE** Decision 7 implemented: `setSolver(address, bool)` + step-0 `SolverNotApproved` guard in `executeIntent`
- `IntentRejected` event — **DONE** Decision 9 implemented: emitted on every rejection path in `executeIntent`

**Pre-audit gaps (remaining):**
- UUPS proxies — see Decision 11 below
- `EnvelopeRegistry` token rescue — see Decision 11 below

**Explicitly NOT in Phase 1:**
- Sub-capabilities — root delegation only (depth 0); delegation chains in Phase 2
- Solver market — whitelisted solver only
- Cross-chain — single chain only
- ZK circuits — any circuit

Any PR that introduces cross-chain or ZK logic into Phase 1 contracts should be rejected. Keep Phase 1 contracts minimal and auditable.

---

## Decision 11 — Upgrade Pattern for Phase 1: Immutable Deployments

**Status: LOCKED**

**Decision:** Phase 1 contracts (`SingletonVault`, `CapabilityKernel`, `EnvelopeRegistry`) deploy as plain, non-upgradeable contracts. No UUPS proxies in Phase 1.

**Rationale:**

1. **Guarded beta.** Phase 1 is a controlled, permissioned deployment. The protocol owner controls the solver whitelist and can halt execution via `pause()`. If a critical bug is found, the owner pauses + redeploys a fixed version. TVL is bounded by the solver whitelist — no permissionless entry during this phase.

2. **Audit surface.** UUPS proxy patterns (OpenZeppelin `UUPSUpgradeable`, `initialize()`, `_authorizeUpgrade()`) add ~100 LOC of upgrade machinery to each contract. Every line of proxy code is additional audit surface. Removing it shrinks the audit scope by ~15% and eliminates a class of upgrade-privilege attacks entirely.

3. **Storage layout.** Non-upgradeable contracts have no storage layout constraints. Upgradeable contracts must carefully reserve storage slots across versions. Phase 1 storage layouts are not yet fully stabilized — locking upgrade proxy logic now would constrain Phase 2 schema changes.

4. **Redeployment = clean slate.** As documented in the EIP-712 Domain section, redeployment invalidates all existing capability tokens by changing the `verifyingContract` address. This is already a known, intentional consequence of redeployment. Users hold no long-lived state inside the contracts (positions are just commitments; caps and intents are off-chain). Migration cost is low.

**Phase 2 plan:** After the Phase 1 audit completes and token economics are confirmed, `CapabilityKernel` and `EnvelopeRegistry` will be wrapped in UUPS proxies with a 48-hour timelock on `_authorizeUpgrade()`. `SingletonVault` will remain non-upgradeable — its storage (position commitments) is user funds and must not be migrated.

**Amends Deployment Invariants below:** The "UUPS proxies" entry in Deployment Invariants is superseded by this decision.

---

## Decision 12 — EnvelopeRegistry Token Rescue

**Status: LOCKED**

**Decision:** Add an `ownerRescue(address token, address to, uint256 amount)` function to `EnvelopeRegistry`. Do NOT add this to `SingletonVault` or `CapabilityKernel`.

**Rationale:**

The `EnvelopeRegistry` can receive ERC-20 tokens in two ways:
- As keeper reward output, temporarily held before payment (expected, clears in same tx)
- Via direct transfer or adapter dust left in the contract (edge case)

If an adapter call reverts mid-execution after tokens were transferred to the registry but before they were forwarded, those tokens would be trapped permanently in a non-upgradeable contract with no rescue path. An owner-gated rescue function prevents permanent token loss.

`SingletonVault` and `CapabilityKernel` do NOT need this:
- `SingletonVault`: positions are tracked by commitment hash; no loose ERC-20 balance.
- `CapabilityKernel`: immediately forwards tokens to adapter or vault; holds nothing.

The rescue function is owner-only and emits a `TokensRescued` event. It is NOT callable on tokens that correspond to any active position commitment (guarded by checking `vault.positionExists` would be too expensive; instead it is owner-judged, with the responsibility documented).

---

## Deployment Invariants

**Networks:** Base (primary), Arbitrum (secondary).

**Upgrade pattern:** Phase 1 — plain immutable deployments (see Decision 11). Phase 2 — UUPS proxies with 48-hour timelock for `CapabilityKernel` and `EnvelopeRegistry`.

**Address determinism:** All contracts deploy via CREATE2 with salt `keccak256("atlas-protocol-v1")`. Same address on every chain. Any deployment script that does not use this salt produces non-canonical addresses.

**Post-deploy validation (required before any integration):**
- `vault.code.length > 0`
- `kernel.code.length > 0`
- `kernel.vault() == address(vault)`
- `uniswapAdapter.name()` returns non-empty string
- `aaveAdapter.name()` returns non-empty string

Do not announce or integrate until all five checks pass.

---

## EIP-712 Domain (Locked — Do Not Change Without Interface Review)

```solidity
DOMAIN_SEPARATOR = keccak256(abi.encode(
    keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
    keccak256("Atlas Protocol"),
    keccak256("1"),
    block.chainid,
    address(kernel)
));
```

The `verifyingContract` is the `CapabilityKernel` address. All EIP-712 signatures are scoped to the kernel. If the kernel is redeployed, all existing capability tokens are invalidated — this is intentional and desirable (redeployment = clean slate for authorization).

---

*This file is the implementation source of truth for Phase 1. SPEC.md is the design reference. Where they conflict, raise it explicitly — do not silently resolve in code.*
