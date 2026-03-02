# Atlas Protocol — ZK Circuit Architecture
**Status: Phase 2 Design — Locked**
**Stack: Noir + Barretenberg (bb) + Solidity UltraHonk verifiers + EVM (Base primary, Arbitrum secondary)**
**Date: February 2026**

This document is the canonical ZK design reference for Atlas Protocol Phase 2+. It locks the five cross-cutting decisions that every circuit depends on, then specifies all seven circuits. Read the decisions before reading any circuit.

DECISIONS.md supersedes SPEC.md where they conflict. This document supersedes the ZK sections of both for implementation purposes.

---

## Axis Lock Rule (Enforced)

The following are six independent axes. **Only one changes at a time.**

| Axis | Current State |
|---|---|
| Noir version | Pinned — see `zk/toolchain.json` |
| bb version | Pinned — see `zk/toolchain.json` |
| Proving scheme | UltraHonk (fixed per circuit) |
| Circuit logic | Per-circuit source in `zk/circuits/` |
| Verifier contract | One per circuit, in `contracts/verifiers/` |
| Public input layout | Locked per circuit in this document |

Any PR touching more than one axis must be broken into a sequenced migration plan with a gate between each step (pin → parse → prove+verify).

---

## Locked Decisions

### Decision ZK-1 — Hash Function: Dual-Hash Bridge (Option B)

**LOCKED: Poseidon2 in circuits, keccak256 on-chain. No migration of on-chain commitments.**

**Reasoning:**

keccak256 costs ~10,000–15,000 constraints per hash in a Noir circuit (via the `std::hash::keccak256` gadget). The compliance proof (Circuit 1) for N=100 intents requires hashing each intent preimage to derive its nullifier. At 10k constraints per hash × 100 intents = 1M constraints from hashing alone — before any constraint logic. This is not a practical circuit.

Poseidon2 costs ~100 constraints per hash and is field-native, making it the correct hash function for ZK computation. keccak256 remains on-chain because:
1. All Phase 1 position commitments (`positionHash = keccak256(abi.encode(position))`) are already deployed
2. All EIP-712 digests are keccak256-based and cannot change without re-signing
3. Re-auditing the vault's commitment model is unnecessary risk before the audit is complete

**The bridge pattern:**

Each circuit that references on-chain keccak256 values does one of two things:
- Takes the keccak256 hash as a **public input** (verified by the on-chain verifier against the mapping) and works with Poseidon2 internally
- Takes the preimage as a **private input**, computes keccak256 once at the circuit boundary (one hash = one budget item), then uses Poseidon2 for all internal chaining

This is the only acceptable architecture. A circuit that keccak256-hashes N preimages internally is a constraint budget catastrophe and will be rejected at code review.

**Axis migration plan:**
- Axis 1 (Phase 2): Add Poseidon2 to circuit layer only. Gate: `bb gates` passes, one proof verifies on-chain. No on-chain changes.
- Axis 2 (Phase 3, if needed): Dual-hash bridge verifier — accepts both keccak256 commitments (existing) and Poseidon2 commitments (new positions). Gate: existing keccak256 positions still resolve correctly.
- Axis 3 (Phase 4+, optional): Full Poseidon2 on-chain commitments. Requires vault migration, re-audit. Do not schedule until Phase 3 is stable.

---

### Decision ZK-2 — Nullifier Membership: Off-Chain Merkle Tree, On-Chain Root (Option A)

**LOCKED: Merkle tree over spent nullifiers. Root published on-chain periodically. Off-chain indexer maintains the tree.**

The on-chain `spentNullifiers` is a flat mapping — there is no native Merkle structure. Building Circuit 1 requires a way to prove N nullifiers are in the spent set without N individual on-chain reads inside the circuit.

**Architecture:**
1. An off-chain indexer (Atlas relayer or any indexer) processes `IntentExecuted` events and builds a Merkle tree of all spent nullifiers.
2. The tree root is committed to a new `NullifierRegistry` contract — owner-callable, or callable by any address (just stores the root of whatever tree was submitted, no validation). This is a 50-line contract.
3. At proof generation time, the prover fetches the current Merkle root and generates per-nullifier inclusion proofs.
4. The circuit proves: "I know N (nullifier, Merkle proof) pairs that are all valid inclusions in root R." Public input: the root R. The on-chain verifier checks that R matches the published `NullifierRegistry.currentRoot`.

**Trust assumption:** The indexer cannot fabricate nullifiers (they must match `IntentExecuted` events), but a malicious indexer could *omit* recent nullifiers. The verifier must only accept roots that are at least K blocks old (K = finality depth). This guards against a prover fabricating compliance by using a stale root that omits their own violations.

**Merkle tree parameters:**
- Leaf: `keccak256(nullifier)` (single-element leaf, standard practice)
- Height: 20 levels → 1M leaf capacity (sufficient for years of intent execution)
- Off-chain tree library: use existing `merkle-trees` or write a minimal one; no exotic structures needed
- Gas cost to update root on-chain: ~22k (one SSTORE)

---

### Decision ZK-3 — Oracle Freshness: Pull Pattern (Option A)

**LOCKED: The on-chain verifier re-reads oracle state at proof verification time. Proofs are not committed to a specific block's oracle value.**

For Circuit 3 (Condition Tree Proof): the oracle value is a public input that the verifier reads from the oracle contract at the time `verify()` is called. The circuit proves "given oracle value V, the condition tree evaluates to true." The verifier passes the current oracle value — not a historical one.

**Implication:** If a stop-loss keeper generates a proof when ETH < $1800 and submits the transaction, but the price recovers before block inclusion, the proof will fail verification (the verifier reads the new price, which no longer satisfies the condition). This is **the correct behavior** — if the condition is no longer true, the envelope should not trigger. The keeper simply retries when the price falls again.

**What this prevents:** A keeper cannot generate a proof while conditions are met, hold it, and submit it hours later when conditions have changed. The proof is only valid in the block where the oracle reading satisfies the committed condition.

**Anti-pattern to reject:** Do not add a `blockNumber` commitment to the circuit to make proofs "expire." The pull pattern already achieves this without circuit complexity.

---

### Decision ZK-4 — Incremental Compliance Proving: Batch Proving (Phase 2), Checkpoint Proofs (Phase 3)

**LOCKED: Option A for Phase 2 (batch proving over fixed time windows). Option C for Phase 3 (checkpoint proofs with Barretenberg recursion).**

IVC/Nova folding (Option B) is not production-ready in Barretenberg today. Do not schedule it until Aztec publishes a stable Noir/Honk recursion API, estimated 6–12 months. Building on unstable tooling violates the axis lock rule.

**Phase 2 — Batch proving:**
- Agent proves compliance for a fixed window: "I complied with cap C for all intents executed in [T_start, T_end]."
- Windows can be quarters, months, or arbitrary ranges.
- Multiple window proofs are composed manually by the verifier (check Q1 proof + Q2 proof + Q3 proof).
- Simple, works today, no recursion.

**Phase 3 — Checkpoint proofs:**
- Use Barretenberg's UltraHonk recursion (`std::verify_proof`) to compose proofs.
- Agent maintains a checkpoint: "proven_up_to_nullifier_N with root R_k." When new intents execute, they prove incremental compliance from N→M, producing a new checkpoint. The new checkpoint embeds the old proof's verification inside the circuit.
- More complex but O(incremental) proving time per new intent batch.

---

### Decision ZK-5 — Circuit 3 (Condition Tree Proof): Build Only for Composite Strategies (Option B)

**LOCKED: Build the condition tree proof circuit only for envelopes with `CompositeNode` roots. Skip for single-leaf (simple price threshold) envelopes.**

**Reasoning:** A simple `LESS_THAN(ETH/USD, 1800)` envelope has a strategy that is trivially brute-forceable: there are only a few plausible ETH price thresholds (round numbers near current price). The privacy gain from ZK is negligible. The hash-commitment model already provides meaningful privacy for single-leaf strategies — the threshold is not revealed until trigger time.

Complex multi-condition strategies (e.g., `AND(price_threshold, volatility_spike, liquidity_drain)`) have exponentially more possible combinations and genuinely benefit from permanent strategy privacy.

The circuit handles `CompositeNode` roots only. Single-leaf envelopes use the existing plaintext reveal path. The on-chain verifier checks `conditionsHash` structure and routes to the appropriate path.

---

## Circuit Specifications

### Circuit 1: ZK Compliance Proof

**Priority: Phase 2 — Build first. Highest value in the protocol.**

**What ZK buys here:** Computation compression (replace O(N) on-chain verifications with O(1) proof) + compliance credentials (portable proof of historical behavior without revealing individual trades).

**What ZK does NOT buy:** Privacy of amounts or counterparties (visible at deposit/execution on public EVM).

---

**Proof statement:**
> The prover knows N intent preimages {(positionCommitment_i, adapter_i, amountIn_i, amountOut_i, nonce_i, periodIndex_i)} and N Merkle inclusion proofs, such that:
> 1. Each nullifier_i = Poseidon2(nonce_i, positionCommitment_i) is a valid inclusion in the nullifier Merkle tree at root R.
> 2. For each intent: amountOut_i ≥ (amountIn_i × minReturnBps) / 10000.
> 3. For each intent: adapter_i is a member of allowedAdapters (committed in constraintsHash).
> 4. For each period P: Σ{amountIn_i | periodIndex_i == P} ≤ maxSpendPerPeriod.
> 5. All N intents reference capability with hash capabilityHash (public input).

**Public inputs (verified on-chain by verifier contract):**
```
capabilityConstraintsHash   // keccak256(abi.encode(constraints)) — matches on-chain capability
N                           // number of intents proven
nullifierSetRoot            // Merkle root from NullifierRegistry (fetched at proof verification time)
T_start, T_end              // time range this proof covers (unix timestamps)
```

**Private inputs (known only to prover, never on-chain):**
```
N intent preimages:
  positionCommitment_i  // bytes32 (keccak256 of position, taken as opaque hash — bridge boundary)
  adapter_i             // address
  amountIn_i            // uint256
  amountOut_i           // uint256
  nonce_i               // bytes32
  periodIndex_i         // uint256 (block.timestamp / periodDuration at execution time)

N Merkle inclusion proofs:
  nullifier_i           // Poseidon2(nonce_i, positionCommitment_i)
  path_i[20]            // Merkle path (20 siblings for height-20 tree)
  pathIndices_i[20]     // 0 = left, 1 = right

constraintsPreimage:
  maxSpendPerPeriod, periodDuration, minReturnBps
  allowedAdapters[]     // as Poseidon2-hashed set (or flat list if |allowedAdapters| ≤ 8)
```

**Noir circuit structure:**
```noir
// Pseudocode — actual Noir code goes in zk/circuits/compliance/src/main.nr
fn main(
    // Public
    capability_constraints_hash: pub Field,
    n: pub u64,
    nullifier_set_root: pub Field,
    t_start: pub u64,
    t_end: pub u64,

    // Private
    intents: [IntentWitness; MAX_N],    // fixed-size array (Noir requires fixed sizes)
    merkle_proofs: [MerklePath; MAX_N],
    constraints: ConstraintsWitness,
) {
    // 1. Recompute constraints hash and assert == capability_constraints_hash
    assert(poseidon2_hash(constraints) == capability_constraints_hash);

    // 2. For each intent:
    for i in 0..MAX_N {
        if i < n {
            // a. Compute nullifier at bridge boundary
            let nullifier = poseidon2([intents[i].nonce, intents[i].position_commitment]);

            // b. Verify Merkle inclusion
            assert(merkle_root(nullifier, merkle_proofs[i]) == nullifier_set_root);

            // c. minReturn check: amountOut * 10000 >= amountIn * minReturnBps
            //    (multiply to avoid division — avoids precision loss)
            assert(intents[i].amount_out * 10000 >= intents[i].amount_in * constraints.min_return_bps);

            // d. Adapter allowlist: set membership check
            assert(is_member(intents[i].adapter, constraints.allowed_adapters));

            // e. Time range gate
            assert(intents[i].period_index * constraints.period_duration >= t_start);
            assert(intents[i].period_index * constraints.period_duration <= t_end);
        }
    }

    // 3. Period spending accumulation
    // Group intents by period_index, sum amountIn, assert <= maxSpendPerPeriod
    // (Implemented as a sorted pass + running sum — O(N) constraints)
    check_period_limits(intents, n, constraints.max_spend_per_period, constraints.period_duration);
}
```

**Key design notes:**
- `MAX_N` must be a compile-time constant in Noir. Use padding: intents beyond index `n` are zero-filled and gated with `if i < n`. This means you need one circuit per `MAX_N` (e.g., 100, 500, 1000). In practice, deploy three circuit sizes and let the agent choose.
- The `positionCommitment` is taken as an opaque `Field` at the bridge boundary — the circuit does not re-derive it from the position preimage. This keeps keccak256 out of the circuit. The Merkle tree uses `Poseidon2(nonce, positionCommitment)` as the leaf.
- The adapter allowlist is encoded as a sorted array of at most 8 addresses (the constraint limit from SPEC). Membership is a linear scan — 8 comparisons per intent, acceptable.
- Period accumulation: sort intents by `periodIndex` (off-circuit, prover does this before witness generation), then do a linear scan accumulating per-period spend. Sorting off-circuit means no sorting constraints inside the circuit.

**Constraint estimate:**
- Poseidon2 per nullifier: ~100 constraints × N
- Merkle inclusion per nullifier: ~100 constraints × 20 levels × N = 2,000 × N
- minReturn check: ~10 constraints × N
- Adapter membership (8-element): ~8 constraints × N
- Period accumulation: ~20 constraints × N
- **Total per intent: ~2,138 constraints**
- N=100: ~214,000 constraints
- N=500: ~1,070,000 constraints
- N=1,000: ~2,140,000 constraints

For N=100 this is very practical. For N=1,000 proving time on commodity hardware (~3GHz, 16GB) is 30–120 seconds depending on hardware — acceptable for a batch compliance proof.

**Proof system:** UltraHonk (Barretenberg). Transparent setup (no ceremony). Proof size ~5–6KB. Verification gas on Base: ~300–500k gas.

**Verifier contract:** `contracts/verifiers/ComplianceVerifier.sol` — generated by `bb write_vk` + `bb contract`. Registered in `VerifierRegistry` with circuit ID `CIRCUIT_COMPLIANCE_V1`.

**Build recommendation: A — Build as specified.**
Circuit 1 is the protocol's single most valuable ZK component. It converts the entire agent authorization model from "trust me" to "here is a constant-size proof of compliance for all N historical actions." Build this first.

---

### Circuit 2: Sub-Capability Chain Verification

**Priority: Phase 2 — Build alongside Circuit 1.**

**What ZK buys here:** Delegation privacy (the full A→B→C chain is not revealed in calldata) + computation compression (replace O(depth) on-chain storage reads with O(1) proof).

---

**Proof statement:**
> The prover knows a delegation chain of depth ≤ 8 from root issuer to terminal grantee, where each level's constraints are a valid subset of its parent's, every capability hash in the chain is currently non-revoked (proven against a published non-revocation root), and the effective (most-restrictive) constraints of the chain hash to `effectiveConstraintsHash`.

**Public inputs:**
```
rootCapabilityHash          // keccak256 of root capability — must be valid on-chain
terminalGrantee             // address — must match intent.signer verified by kernel
effectiveConstraintsHash    // Poseidon2 of the intersection of all constraint sets
nonRevocationRoot           // Merkle root of the non-revocation set (published by NullifierRegistry or separate contract)
```

**Private inputs:**
```
chain[8]: CapabilityWitness  // full capability preimage for each level (zero-padded for depth < 8)
chain_sigs[8]: Signature     // ECDSA signature from each level's issuer
revocation_proofs[8]: MerklePath  // non-membership proof in revocation set
```

**Key design challenge — Non-membership proofs:**
The revocation registry is `mapping(address => mapping(bytes32 => bool))`. To prove a capability hash is NOT in the revocation registry inside a ZK circuit, you need a non-membership proof in a Merkle accumulator over the revoked nonces. This requires a separate `RevocationAccumulator` contract maintained by an indexer — same architecture as the NullifierRegistry.

Until Phase 3, an acceptable simplification: **do not prove non-revocation inside the circuit.** Instead, take non-revocation as an oracle input — the on-chain verifier calls `kernel.isRevoked(issuer, nonce)` for the root capability only (the most critical link). Inner chain links can have a freshness window (e.g., "chain is valid if no link was revoked in the last K blocks"). This degrades the privacy guarantee slightly but is practical for Phase 2.

**Constraint estimate:**
- Per level: ECDSA verification (~3,000 constraints) + constraint subset check (~50 constraints) + Poseidon2 hash (~100 constraints)
- Depth 8: ~25,200 constraints total
- Very fast proving time (<1 second on commodity hardware).

**Proof system:** UltraHonk. Small circuit, fast proof.

**Build recommendation: B — Build simplified version.**
Build without the non-revocation proof inside the circuit for Phase 2. The on-chain verifier checks the root capability's revocation status directly (one storage read). Inner chain links are covered by the circuit's signature verification (a revoked capability's signature would still verify — the prover could cheat on non-revocation for inner links). Accept this limitation in Phase 2, add the full RevocationAccumulator + non-membership proof in Phase 3.

---

### Circuit 3: Condition Tree Proof

**Priority: Phase 3 — Composite strategies only (Decision ZK-5).**

**What ZK buys here:** Permanent strategy privacy for multi-condition envelopes. The oracle *values* are public (Chainlink prices are on-chain). The *strategy structure* (thresholds, boolean logic, combination) is permanently hidden.

---

**Proof statement (composite envelopes only):**
> The prover knows a condition tree whose root hash is `conditionsHash`, composed of `CompositeNode`s and at most K `PriceLeaf`/`TimeLeaf`/`OnChainStateLeaf` nodes, such that evaluating each leaf against the oracle values V[] (public inputs) and computing the boolean tree produces `true`.

**Public inputs:**
```
conditionsHash              // bytes32 — must match on-chain envelope.conditionsHash
oracle_values[K]            // uint256[] — current values for each oracle in the tree (re-read at verification time, Decision ZK-3)
oracle_addresses[K]         // address[] — identifies which oracles the verifier should query
```

**Private inputs:**
```
tree: ConditionTreeWitness  // full tree structure (node types, thresholds, boolean operators)
```

**Oracle freshness enforcement (Decision ZK-3 — pull pattern):**
The Solidity verifier:
1. For each `(oracle_address, oracle_value)` pair in public inputs: calls `AggregatorV3Interface(oracle_address).latestRoundData()` and asserts the returned value equals `oracle_value`.
2. Asserts each oracle's `updatedAt` is within `MAX_ORACLE_AGE` (3600 seconds) of `block.timestamp`.
3. Calls the ZK verifier: `zkVerifier.verify(proof, [conditionsHash, oracle_values..., oracle_addresses...])`.

This is the critical ordering: oracle reads first, ZK verify second. The proof generation uses oracle values at submission time; if they change before inclusion, verification fails.

**Constraint estimate (depth-4 composite tree, 4 leaves):**
- Poseidon2 for each node hash: ~100 constraints × 7 nodes = 700
- Comparison operations per leaf: ~20 constraints × 4 leaves = 80
- Boolean evaluation: ~10 constraints × 3 composite nodes = 30
- **Total: ~810 constraints** — trivially small circuit.

**Proof system:** UltraHonk.

**Build recommendation: B — Build for composite strategies only.**
Skip for single-leaf envelopes. The routing logic is in the `EnvelopeRegistry.trigger()` function: if `conditionsHash` equals `keccak256(abi.encode(simpleCondition))`, use the existing plaintext reveal path. If it's a Merkle root with a `CompositeNode` at the root, require the ZK proof.

---

### Circuit 4: M-of-N Threshold Aggregation

**Priority: Phase 3 for M≤20 ECDSA. BLS for swarm model (M>20).**

**What ZK buys here:** Calldata compression (replace O(M) signatures + Merkle proofs with one constant-size proof) + privacy (individual signers' identities are not revealed, only that M of the N approved set signed).

---

**ECDSA in Noir — honest assessment:**

Noir's standard library (`noir_stdlib::ecdsa_secp256k1`) handles ECDSA secp256k1 verification. Each ECDSA verification costs approximately **3,000–5,000 constraints** in UltraHonk (Barretenberg backend). At M=5: ~15,000–25,000 constraints (fast). At M=20: ~60,000–100,000 constraints (still practical, ~2–5 second prove time). At M=60: ~180,000–300,000 constraints (10–30 seconds, borderline for keeper latency).

**For the swarm model (T-of-100+): use BLS aggregation, not ZK.**

BLS signature aggregation is O(1) verification regardless of M. It does not require ZK. The cost: agents must register BLS keys alongside their Ethereum keys. For Atlas, swarm agents are purpose-built AI systems, not end users — key registration is a configuration step, not a UX burden. The correct architecture for the swarm model is BLS-based, full stop. ZK-aggregated ECDSA at M=60 is theoretically possible but the proving latency makes it impractical for on-chain execution flows.

**Hybrid recommendation:**
- M≤20: ECDSA in Noir circuit (Phase 3)
- M>20 (swarm): BLS native aggregation (Phase 4, requires BLS key infrastructure)

---

**Proof statement (M≤20 ECDSA):**
> The prover knows M distinct ECDSA signatures over `intentHash`, from M distinct keys, each a member of the approved signer set committed as `approvedSignerRoot`, all produced within `signatureWindowSecs` of each other.

**Public inputs:**
```
intentHash
approvedSignerRoot    // Merkle root of approved agent key set (address[])
requiredSignatures    // M (threshold)
signatureWindowSecs
```

**Private inputs:**
```
signers[M]: address
signatures[M]: ECDSASignature    // (r, s, v)
timestamps[M]: uint256           // timestamp embedded in or alongside each signature
merkle_proofs[M]: MerklePath     // proving signer_i ∈ approvedSignerRoot
```

**Constraint estimate:** M × 5,000 (ECDSA) + M × 2,000 (Merkle) = M × 7,000. At M=10: ~70,000 constraints.

**Build recommendation: B — Build for M≤20.**

---

### Circuit 5: Position Split/Merge Integrity

**Priority: Phase 4+ (likely skip).**

**What ZK buys here:** Move the sum check off-chain (computation compression). The privacy argument is weak — amounts are visible at deposit and at each sub-position's eventual execution.

**Proof statement:**
> The prover knows the preimage of `inputPositionHash` (owner, asset, amount, salt) and N output position preimages, such that the N output amounts sum to the input amount and each output commitment is correctly formed.

**Constraint estimate:** N Poseidon2 hashes + N addition checks = ~200 × N constraints. Very cheap.

**Build recommendation: C — Skip it.** The on-chain sum check is a single `require` statement. Moving it into a ZK circuit saves no meaningful gas (the calldata for N output positions must be submitted regardless) and provides no privacy benefit (amounts visible at endpoints). Defer indefinitely unless a specific use case requiring amount-private splits emerges. The circuit is trivial to implement when needed — it is not a blocking dependency for any other circuit.

---

### Circuit 6: Proof of Reserves

**Priority: Phase 3 — Build for institutional use.**

**What ZK buys here:** Prove total AUM ≥ X without revealing individual position sizes or counts. High value for funds and DAOs running on Atlas.

---

**Proof statement:**
> The prover knows N position preimages {(owner, asset, amount, salt)}, each corresponding to a valid commitment in the vault's on-chain `positions` mapping (proven via Merkle inclusion in a published PositionsMerkleTree), all belonging to the same fund (matching `fundCapabilityHash`), whose total value sums to at least `minimumTotalValue`.

**Public inputs:**
```
minimumTotalValue     // lower bound being proven
assetAddress          // single-asset proof (multi-asset requires price oracle inputs)
fundCapabilityHash    // identifies the fund; verifier checks on-chain
positionsMerkleRoot   // published by PositionsIndexer, same architecture as NullifierRegistry
```

**Private inputs:**
```
positions[N]: PositionWitness   // (owner, asset, amount, salt) preimages
merkle_proofs[N]: MerklePath    // proving each positionHash ∈ positionsMerkleRoot
```

**Range proof requirement:**
Each `amount` must be non-negative (trivially true for uint256 in Solidity, but in the Noir field F_p with p ≈ 2^254, values must be range-checked to fit within 128 bits to prevent overflow in summation). Use `std::range_constraint(amount, 128)` — costs ~128 constraints per position.

**Sum as lower bound vs exact value:**
The proof statement uses ≥ `minimumTotalValue` (lower bound), not = exact value. This is the correct design for proof of reserves — you want to prove "we hold at least X" not "we hold exactly X." The latter reveals exact AUM which may be sensitive. The lower bound can be periodically updated with new proofs at higher thresholds as AUM grows.

**Constraint estimate:**
- Per position: Poseidon2 commitment (~200 constraints) + Merkle inclusion (~2,000 constraints) + range check (~128 constraints) = ~2,328
- N=100 positions: ~232,800 constraints (fast)
- N=1,000 positions: ~2,328,000 constraints (practical, ~60–120 seconds proving time)

**Proof system:** UltraHonk.

**Build recommendation: A — Build as specified.** Proof of reserves is a genuine product differentiator for institutional Atlas adoption. The circuit is straightforward — it is Circuit 1's Merkle inclusion machinery applied to positions rather than nullifiers.

---

### Circuit 7: Private Treasury Constraint Audit

**Priority: Phase 3 — Build as a parameterized variant of Circuit 1.**

**What ZK buys here:** DAOs using Atlas for treasury management can prove constitutional compliance (max spend, allowed protocols, circuit-breaker conditions) without publishing individual transaction details.

---

This is Circuit 1 with four additional constraint types:

**Additional constraints beyond Circuit 1:**
1. **Portfolio weight limits** — requires knowing total portfolio value at each execution step. This must be provided as a private input: historical oracle prices at each intent's timestamp. The circuit then computes portfolio weight as `assetValue / totalValue` and asserts it falls within `[minWeight, maxWeight]`. This requires N price oracle readings as private inputs — opaque `uint256` values provided off-chain by the prover.

2. **Per-transaction spend limit as % of total treasury** — same as above: requires total treasury value as private input at each execution time. Same oracle-reading private inputs.

3. **Allowed adapter list specific to treasury** — identical to Circuit 1's adapter allowlist check. Just a different allowlist encoded in `constraintsHash`.

4. **Circuit-breaker condition** — most complex. The constraint: "if at any intent in the window the portfolio drawdown exceeded 30%, all subsequent intents in the window must have been conversions to stable assets." This requires:
   - High-water mark tracking across the N intents (running max of portfolio value)
   - Per-intent drawdown check against the running max
   - After drawdown crossing: assert adapter ∈ stableConversionAdapters for all remaining intents
   - This adds ~50 constraints per intent for the drawdown tracking.

**Public inputs:**
```
constitutuionalConstraintsHash  // hash of the full treasury constitution (weight limits, circuit-breaker rules)
N
nullifierSetRoot
T_start, T_end
stableAdapterSetRoot           // Merkle root of approved stable-conversion adapters
```

**Private inputs:**
```
(all Circuit 1 private inputs, plus:)
historical_portfolio_values[N]  // total portfolio value in USD at each intent's timestamp
historical_prices[N][K]         // price of each held asset at each intent's timestamp
```

**Constraint estimate:** Circuit 1 + ~100 constraints per intent for drawdown tracking ≈ 10% overhead on Circuit 1. At N=100: ~235,000 constraints.

**Build recommendation: A — Build as a circuit parameter, not a new circuit.** Implement as Circuit 1 with an optional `treasury_mode` flag and additional private inputs. The base constraint system is identical — only the additional constraint types differ. This avoids a separate circuit deployment, separate SRS, and separate ceremony.

---

## Proving Stack

### Proof System: UltraHonk for All Circuits

UltraHonk (Barretenberg) is the correct choice for all Atlas circuits:
- **Transparent setup** — no circuit-specific trusted ceremony required. Uses the universal Barretenberg SRS (derived from BLS12-381 pairing). Eliminates the ceremony coordination problem.
- **Fixed proof size** — ~5–6KB across all circuits regardless of circuit size. Constant calldata cost.
- **Production-ready in Barretenberg** — Aztec ships production code on UltraHonk. It is not experimental.
- **Verification gas on Base** — ~300–500k gas per proof. Acceptable as a rare operation (compliance proofs, PoR proofs).

Do NOT use Groth16 for Atlas. The per-circuit MPC ceremony is a coordination and trust burden for every new circuit added. Atlas will have 5+ circuits at full build-out. Groth16 is the wrong choice for a protocol that will evolve.

Do NOT use PLONK. UltraHonk strictly dominates PLONK on proof size, proving time, and setup requirements with the current Barretenberg backend.

### Verifier Deployment: Registry Pattern

```
contracts/
  verifiers/
    VerifierRegistry.sol          // owner-controlled registry: circuitId → verifierAddress
    ComplianceVerifier.sol        // Circuit 1 — generated by bb
    DelegationVerifier.sol        // Circuit 2 — generated by bb
    ConditionTreeVerifier.sol     // Circuit 3 — generated by bb
    ThresholdVerifier.sol         // Circuit 4 — generated by bb
    ReservesVerifier.sol          // Circuit 6 — generated by bb
```

Each verifier contract is generated by `bb write_vk` + `bb contract` from the pinned circuit artifact. New circuits are registered via `VerifierRegistry.setVerifier(circuitId, address)` — owner-controlled, timelocked in Phase 3.

The calling contracts (`CapabilityKernel`, `EnvelopeRegistry`) call `IVerifier(registry.getVerifier(CIRCUIT_ID)).verify(proof, publicInputs)`. They never hard-code verifier addresses.

### Auxiliary Contracts Required

```
contracts/
  zk/
    NullifierRegistry.sol         // stores current spent-nullifier Merkle root (Decision ZK-2)
    RevocationAccumulator.sol     // Phase 3 — stores revocation accumulator root
    PositionsRegistry.sol         // Phase 3 — stores current positions Merkle root (Circuit 6)
```

These are all ~50-line contracts with one storage slot each. They are maintained by the Atlas indexer service.

### Proving Service Architecture

| Circuit | Who proves | When | Latency requirement |
|---|---|---|---|
| Circuit 1 (Compliance) | Agent service (server-side) | On-demand (before audit, user request) | None — batch operation |
| Circuit 2 (Delegation) | Agent service (server-side) | Per intent submission | <5 seconds to stay in tx |
| Circuit 3 (Condition tree) | Keeper | At trigger time | <2 seconds (must fit in tx lifetime) |
| Circuit 4 (M-of-N) | Last-to-sign aggregator | After M sigs collected | <5 seconds |
| Circuit 6 (PoR) | Fund operator | Periodically (daily/weekly) | None — batch operation |

**Circuit 3 latency concern:** Condition tree proofs for composite strategies must be generated by the keeper who submits `trigger()`. At ~810 constraints, proving time is under 100ms on commodity hardware — well within tx lifetime. This is why Circuit 3 is designed with a small, fixed circuit size rather than an unbounded tree depth.

**Circuit 2 latency concern:** Delegation chain proofs at ~25,000 constraints prove in under 1 second. Acceptable for intent submission flow.

---

## Phased Build Plan

### Phase 2 (Weeks 1–12 after Phase 1 audit)

**Build: Circuit 1 + Circuit 2 + NullifierRegistry + VerifierRegistry**

| Deliverable | Dependency |
|---|---|
| `NullifierRegistry.sol` | None |
| `VerifierRegistry.sol` + `IVerifier` interface | None |
| `zk/circuits/compliance/` (Circuit 1, MAX_N=100) | NullifierRegistry |
| `contracts/verifiers/ComplianceVerifier.sol` | Circuit 1 artifact |
| Circuit 1 integration: `CapabilityKernel` checks compliance proof on demand | ComplianceVerifier |
| `zk/circuits/delegation/` (Circuit 2, simplified — no inner non-revocation) | None |
| `contracts/verifiers/DelegationVerifier.sol` | Circuit 2 artifact |
| Circuit 2 integration: `CapabilityKernel` accepts delegation proof as alternative to inline chain | DelegationVerifier |

**Gate between each deliverable:** pin → parse → prove+verify closure (one real proof verifies against the deployed verifier).

### Phase 3 (Weeks 12–24)

**Build: Circuit 3 + Circuit 4 + Circuit 6 + checkpoint proving + full non-revocation**

| Deliverable | Dependency |
|---|---|
| `RevocationAccumulator.sol` | Phase 2 infrastructure |
| Circuit 2 v2 — add full non-revocation proofs | RevocationAccumulator |
| `PositionsRegistry.sol` | None |
| `zk/circuits/reserves/` (Circuit 6) | PositionsRegistry |
| `zk/circuits/condition_tree/` (Circuit 3, composite only) | Phase 2 infrastructure |
| `zk/circuits/threshold/` (Circuit 4, M≤20) | None |
| Checkpoint proof composition (Circuit 1 v2) | Barretenberg recursion stability |

### Phase 4+ (Post Phase 3)

- Circuit 7 (Treasury audit) — parameterize Circuit 1
- BLS swarm aggregation (M>20) — separate infrastructure
- Full IVC incremental compliance — when Barretenberg stabilizes
- Circuit 5 (Position split) — build only if a specific use case emerges; skip until then

---

## Two Circuits to Build First

**Circuit 1 (Compliance Proof) first, Circuit 2 (Delegation Chain) second.**

**Why Circuit 1 first:**
It is the protocol's core ZK value proposition. It converts the agent authorization model from trust-based to proof-based. It is the circuit that will be referenced in the whitepaper, in investor conversations, and in user-facing product features ("generate your compliance report"). Nothing else matters if this circuit doesn't exist. Build it, get one proof verifying on-chain against a deployed verifier, and the entire ZK architecture becomes real rather than hypothetical.

**Why Circuit 2 second:**
It removes the biggest practical limitation of Phase 1 (full delegation chain in calldata) and unblocks the multi-agent orchestration use cases that drive institutional adoption. It is small, fast to prove, and directly improves the core execution flow rather than being an optional compliance feature.

Circuits 3, 4, 6 are valuable but are features. Circuits 1 and 2 are architecture.

---

## ZK Engineering Operating Rules (Atlas-Specific)

These are non-negotiable. They apply to every line of ZK code in this project.

1. **A circuit does not exist until one real proof verifies against the exact deployed verifier.**
2. **No keccak256 inside circuits.** keccak256 only at the circuit boundary (public input or single hash of an opaque commitment). All internal hashing uses Poseidon2.
3. **Every circuit has a stated MAX_N.** Fixed-size arrays. Padding gated by a counter. No dynamic loops.
4. **Toolchain version is pinned in `zk/toolchain.json` and printed on every CI run.** If versions aren't printed, the run is not trusted.
5. **One axis changes per PR.** Noir version OR bb version OR circuit logic OR verifier contract OR public input layout. Never two at once.
6. **The `zk/` directory has its own CI gate** that runs pin → parse → prove+verify on the smoke circuit before any deployment step.
7. **Verifier addresses are never hardcoded.** Everything goes through `VerifierRegistry`.
8. **Proof size and public input count are never hardcoded in client code.** Treat proofs as opaque bytes. Public input count is read from the registry.
