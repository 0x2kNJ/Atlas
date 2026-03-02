# Atlas Protocol — Audit Preparation Checklist
**Status: Pre-Audit**
**Target: Phase 1 contracts only**
**Date: February 2026**

This document is the briefing package for an external auditor. It describes what is in scope, what the known gaps are, what the threat model is, and what the auditor should look hardest at. It also tracks pre-audit tasks that must be completed before audit engagement begins.

---

## Scope

| Contract | Lines (approx) | Role |
|---|---|---|
| `SingletonVault.sol` | ~300 | Asset custody — deposit, withdraw, encumber, release |
| `CapabilityKernel.sol` | ~420 | Core logic — intent verification (18 steps), period spending, nullifiers |
| `EnvelopeRegistry.sol` | ~390 | Conditional execution — register, trigger, cancel, expire |
| `HashLib.sol` | ~80 | EIP-712 type hashes and struct hashing (shared library) |
| `Types.sol` | ~60 | Shared data structures |
| `UniswapV3Adapter.sol` | ~220 | Adapter — exact input swaps via Uniswap V3 |
| `AaveV3Adapter.sol` | ~250 | Adapter — supply and withdraw via Aave V3 |

**Out of scope for this audit:**
- `script/` — deployment scripts (no protocol logic)
- `test/` — test suite
- Sub-capability delegation chains (Phase 2 feature, not implemented)
- ZK circuits (Phase 3)
- Cross-chain execution (Phase 4)

---

## Architecture Summary (for auditor context)

The protocol uses a UTXO-inspired commitment model. Assets never move without a valid capability token + intent authorising the movement. No ERC-4337, no AA wallet dependency.

**Key invariants:**
1. A position can only be released if a valid capability+intent pair is verified by the kernel — including EIP-712 signatures from the position owner (capability) and the authorised agent (intent).
2. A nullifier is marked spent atomically with the position release — double-spend is impossible.
3. An encumbered position cannot be released by the kernel until it is unencumbered by the registry.
4. The kernel never holds token balances after a transaction completes (no persistent custody).
5. No adapter is ever pre-approved; approvals are set transiently within `executeIntent` and zeroed before the call returns.

**Data flow for a single intent execution:**
```
alice signs Capability  →  bob signs Intent  →  solver calls kernel.executeIntent()
  kernel verifies sig (alice)  →  kernel verifies sig (bob)  →  kernel checks 18 conditions
  →  vault.release(position, kernel)  →  kernel approves adapter  →  adapter.execute()
  →  kernel zeros approval  →  kernel calls vault.depositFor(output)  →  receipt emitted
```

---

## Known Pre-Audit Gaps — STATUS: ALL CLOSED

All implementation gaps have been resolved. The protocol is now implementation-complete for Phase 1. See DECISIONS.md for locked decisions.

### Gap 1 — Solver Whitelist (Decision 7) — **CLOSED**

**Implemented:** `mapping(address solver => bool approved) public approvedSolvers` in `CapabilityKernel`. `setSolver(address, bool)` admin function added. Step 0 guard `SolverNotApproved` is the first check in `executeIntent` — even before signature verification, so failed whitelistchecks are cheap.

**Tests added:** `test_revert_step0_solverNotApproved`, `test_setSolver_approveAndRevoke`.

---

### Gap 2 — IntentRejected Event (Decision 9) — **CLOSED**

**Implemented:** `event IntentRejected(bytes32 indexed capabilityHash, address indexed grantee, bytes32 reason, uint256 spentThisPeriod, uint256 periodLimit)` emitted before every `revert` in `executeIntent` (22 distinct paths). Twenty-two `REASON_*` public constants on the kernel identify each reason — the ZK compliance circuit can match on these. `spentThisPeriod` / `periodLimit` are non-zero only on `PERIOD_LIMIT_EXCEEDED`.

**Tests added:** `test_revert_emitsIntentRejected`.

---

### Gap 3 — UUPS vs Immutable — **CLOSED (Decision 11)**

**Decision locked:** Phase 1 deploys as plain immutable contracts (see Decision 11 in DECISIONS.md). Rationale: guarded beta with `pause()` + solver whitelist, UUPS overhead increases audit surface, storage layout not yet stable. Phase 2 will add UUPS with 48-hour timelock for `CapabilityKernel` and `EnvelopeRegistry`.

---

### Gap 4 — EnvelopeRegistry Token Rescue — **CLOSED (Decision 12)**

**Implemented:** `rescueTokens(address token, address to, uint256 amount) external onlyOwner` added to `EnvelopeRegistry`. Emits `TokensRescued`. Guards against zero-amount calls. Used to recover tokens stuck in the contract due to partial execution or accidental transfers.

---

## Threat Model — Areas to Look Hardest At

### 1. EIP-712 Signature Replay and Domain Confusion

**What to check:**
- Can a capability signed for the kernel be replayed on the registry (different domain) or vice versa?
- Does the `HashLib.CAPABILITY_TYPEHASH` match exactly what wallets will sign? Specifically: does the type string include all fields in the correct order, including nested structs?
- Can a `delegationDepth != 0` capability ever sneak through the Phase 1 guard?

**Relevant code:** `HashLib.sol`, `CapabilityKernel.executeIntent()` steps 1–4, `EnvelopeRegistry.register()`.

---

### 2. Nullifier Mechanics

**What to check:**
- Is `spentNullifiers[nullifier] = true` set before or after the external `vault.release()` call?
- Can a re-entered `executeIntent` call observe `nullifier = false` before the first call marks it spent?
- Is the nullifier derivation `keccak256(intent.nonce, intent.positionCommitment)` collision-resistant? What if two intents share the same nonce but reference different positions?

**Relevant code:** `CapabilityKernel.executeIntent()` steps 11 and the nullifier assignment at line ~272.

**Note:** `executeIntent` is `nonReentrant`. Verify the reentrancy guard wraps the entire function including `vault.release()`.

---

### 3. Position Encumbrance Race

**What to check:**
- Can a keeper and a direct solver both observe the same position as unencumbered and race to spend it?
- If `EnvelopeRegistry.trigger()` calls `vault.unencumber()` and then `kernel.executeIntent()`, is there any window where the position is visible as unencumbered but not yet spent?
- Can two envelopes reference the same position? (The second `register()` should succeed but `encumber()` should already revert on the second call.)

**Relevant code:** `SingletonVault.encumber/unencumber`, `EnvelopeRegistry.trigger()` lines ~280–295.

---

### 4. Oracle Manipulation in EnvelopeRegistry

**What to check:**
- Can a keeper manipulate the oracle reading between their transaction submission and execution?
- Is `MAX_ORACLE_AGE = 3600` sufficient staleness protection for the chains Atlas targets (Base, Arbitrum)?
- What happens if the oracle returns `answer = 0`? The `OracleInvalidAnswer` check catches `answer <= 0`, but is `uint256(answer)` used correctly downstream?
- Can a malicious oracle contract cause reentrancy during `latestRoundData()`?

**Relevant code:** `EnvelopeRegistry._assertConditionMet()`.

---

### 5. Keeper Fee Extraction Path

**What to check:**
- In `EnvelopeRegistry.trigger()`, the keeper reward is the balance delta of `intent.outputToken` in the registry contract. Can a re-entrant call during `kernel.executeIntent()` inflate this balance artificially?
- Is it possible for the registry to receive output tokens through a path other than the solver fee (e.g. if the registry is also a token holder), incorrectly inflating the keeper payout?

**Relevant code:** `EnvelopeRegistry.trigger()` lines ~290–297.

---

### 6. Adapter Trust Boundary

**What to check:**
- The adapter calls `IERC20(tokenIn).safeTransferFrom(kernel, adapter, amountIn)`. The kernel approves the adapter for exactly `amountIn` then zeroes it. Can the adapter drain more than `amountIn` if it calls transferFrom multiple times?
- Is the adapter's `execute()` function `nonReentrant`? It is not — the kernel is `nonReentrant`, which prevents re-entering the kernel, but the adapter itself could call back into an unrelated contract.
- Can a malicious adapter registered by the owner be used to drain the vault?

**Relevant code:** `CapabilityKernel.executeIntent()` lines ~278–288, `UniswapV3Adapter.execute()`, `AaveV3Adapter.execute()`.

---

### 7. Period Spending Accounting

**What to check:**
- Period spending is tracked per `capabilityHash`. If the same capability is used across multiple period resets, does the spending counter correctly reset each period?
- What happens when `periodDuration = 0` in constraints? The period index `block.timestamp / 0` would divide by zero. Is this guarded?
- Can an agent construct two capabilities with the same hash but different constraints to bypass the period limit?

**Relevant code:** `CapabilityKernel.executeIntent()` step 18 (period spending is now inlined, not in a separate `_updatePeriodSpending`). Guard: `if (maxSpendPerPeriod > 0 && periodDuration > 0)` — neither zero case proceeds to the division.

---

### 8. Fee-on-Transfer Token Handling

**What to check:**
- `SingletonVault.deposit()` measures the balance delta to handle fee-on-transfer tokens. Does `release()` use the stored amount or re-measure?
- If a fee-on-transfer token is used as `outputToken`, the kernel calls `vault.depositFor(netAmountOut)` but the vault receives `netAmountOut * (1 - fee)`. Does the `depositFor` balance delta guard catch this correctly?

**Relevant code:** `SingletonVault.deposit()`, `SingletonVault.depositFor()`, `CapabilityKernel.executeIntent()`.

---

## Storage Layout (for proxy compatibility review)

### SingletonVault

| Slot | Variable | Type |
|---|---|---|
| 0 | `_owner` (Ownable) | `address` |
| 1 | `_pendingOwner` + `_paused` | `address` + `bool` |
| 2 | `positions` | `mapping(bytes32 => bool)` |
| 3 | `encumbered` | `mapping(bytes32 => bool)` |
| 4 | `tokenAllowlist` | `mapping(address => bool)` |
| 5 | `kernel` | `address` |
| 6 | `envelopeRegistry` + `allowlistEnabled` | `address` + `bool` |

### CapabilityKernel

| Slot | Variable | Type |
|---|---|---|
| 0 | `_nameFallback` (EIP712) | `string` |
| 1 | `_versionFallback` (EIP712) | `string` |
| 2 | `_owner` | `address` |
| 3 | `_pendingOwner` + `_paused` | `address` + `bool` |
| 4 | `spentNullifiers` | `mapping(bytes32 => bool)` |
| 5 | `revokedNonces` | `mapping(address => mapping(bytes32 => bool))` |
| 6 | `adapterRegistry` | `mapping(address => bool)` |
| 7 | `periodSpending` | `mapping(bytes32 => mapping(uint256 => uint256))` |
| 8 | `approvedSolvers` | `mapping(address => bool)` |

---

## Test Coverage Summary

| Contract | Tests | Coverage (lines) | Notable gaps |
|---|---|---|---|
| `SingletonVault` | 50 unit + fuzz | 93.8% | — |
| `CapabilityKernel` | 53 unit + fuzz | 97.1% | — |
| `EnvelopeRegistry` | 56 unit + fuzz | 94.3%+ | — |
| `UniswapV3Adapter` | 15 fork tests (skipped if no RPC) | fork-only | — |
| `AaveV3Adapter` | 16 fork tests (skipped if no RPC) | fork-only | — |

**Total: 159 unit/fuzz tests passing. 0 failing.**

**Coverage run:**
```bash
forge coverage --no-match-path "test/fork/**" --ir-minimum
```
Core contracts (`SingletonVault`, `CapabilityKernel`, `EnvelopeRegistry`, `HashLib`) all above 93% line coverage excluding fork-only adapter code.

**To run all tests:**
```bash
forge test                                                     # unit + fuzz (154 passing)
ARBITRUM_RPC_URL=<url> forge test --match-path "test/fork/*"   # fork tests
```

**Gas highlights (from `forge test --gas-report`):**

| Function | Avg gas | Max gas | Notes |
|---|---|---|---|
| `executeIntent` | 67,533 | 275,375 | Max includes period spend + constraint checks |
| `register` (EnvelopeRegistry) | 213,256 | 220,226 | Includes vault encumber |
| `trigger` (EnvelopeRegistry) | 65,930 | 338,683 | Max includes full kernel execution path |
| `deposit` (SingletonVault) | 87,812 | 90,245 | — |

---

## Pre-Audit Task List

- [x] **Gap 1**: Implement `approvedSolvers` whitelist in `CapabilityKernel` (Decision 7) — **DONE**
- [x] **Gap 2**: Implement `IntentRejected` event emission (Decision 9) — **DONE**
- [x] **Gap 3**: Decide: UUPS proxies vs immutable deployment for Phase 1 — **DONE** (Decision 11: immutable for Phase 1)
- [x] **Gap 4**: `EnvelopeRegistry` token rescue — **DONE** (`rescueTokens()` added, Decision 12)
- [x] Confirm `periodDuration = 0` is guarded against division by zero — **CONFIRMED**: guard `if (maxSpendPerPeriod > 0 && periodDuration > 0)` in step 18
- [x] **FIXED** — EIP-712 `address[]` encoding in `HashLib.hashConstraints` was using `abi.encodePacked` (20-byte per address, wrong) — replaced with `_hashAddressArray` which pads each element to 32 bytes as the EIP-712 spec requires
- [x] Run `forge test --gas-report` — `executeIntent` avg 67k gas, max 275k gas — within acceptable bounds
- [x] Run `forge coverage --ir-minimum` — CapabilityKernel 97.1%, EnvelopeRegistry 94.3%, SingletonVault 93.8%, HashLib 100%
- [x] Run Slither static analysis — **DONE** (slither-analyzer 0.11.5). 22 findings → fixed 5 → 17 remaining, all informational/accepted. Fixed findings:
  - `uninitialized-local` — explicit `bool found = false` in `_checkTokenConstraintsOrReject`
  - `missing-zero-check` — `ZeroAddress` guard added to `SingletonVault.setKernel` and `setEnvelopeRegistry`
  - `events-maths` — `ProtocolMinKeeperRewardUpdated` event added to `setProtocolMinKeeperRewardWei`
  Accepted remaining findings:
  - `incorrect-equality` — `actualAmount == 0` is intentional (fee-on-transfer deposit guard)
  - `unused-return` — oracle/quoter fields explicitly unused (destructured with `None`)
  - `timestamp` — expiry/deadline checks; granularity is hours/days, miner manipulation (±15s) not material
  - `cyclomatic-complexity` — 25 in `executeIntent` by spec (18 verification steps + execution)
  - `missing-inheritance` — interface sync deferred to Phase 2 cleanup
  - `naming-convention` — `IAToken.UNDERLYING_ASSET_ADDRESS` is Aave's canonical interface name
- [x] Add unit test for `rescueTokens` in `EnvelopeRegistry` — **DONE** (5 tests: happy path, event, zero-amount revert, onlyOwner guard, partial rescue)
- [x] Final read-through of all contracts against SPEC.md and DECISIONS.md — **DONE**. One gap found and fixed:
  - `SingletonVault.deposit()` lacked the explicit `asset != address(0)` guard required by Decision 6. Added `if (asset == address(0)) revert ZeroAddress()` as the first check.
  - All other SPEC/DECISIONS invariants confirmed in implementation. `IntentExecutor` superseded (Decision 10). Period spending inlined (step 18). Solver whitelist at step 0. EIP-712 domain correct. Adapter approval transient (forceApprove + zero). Nullifier marked before vault.release(). UTXO commitment model intact.

---

## Contact / Handoff Notes

- `SPEC.md` — full design spec with rationale for every design decision
- `DECISIONS.md` — locked implementation decisions; supersedes SPEC where they conflict
- `WHITEPAPER.md` — protocol overview for context
- All contracts compile with Solc 0.8.24, `via_ir = true`, `optimizer_runs = 200`

*This document is updated before audit engagement. Do not submit to auditor until all Pre-Audit Task List items are checked off.*
