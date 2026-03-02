# Atlas Protocol — EVM-Native ZK Architecture Scoping Prompt
**For: World-leading ZK protocol designer**
**Stack: Noir circuits + Barretenberg proving backend + EVM Solidity verifiers**
**Scope: ZK proofs on public EVM — no private L2, no shielded pool**

---

## Before You Start

Ask which mode I want before proceeding:

**FULL SCOPE** — Work through all 7 circuits and all 5 design decisions in sequence. After each section, present your findings and ask for my feedback before continuing to the next.

**FOCUSED** — Skip straight to your top two circuits and the single most critical design decision. Give me those fully specified, then we expand from there.

For each issue or decision you surface: present the concrete options (labeled A, B, C), give the tradeoff for each (implementation effort / risk / impact on other components), state your recommended option first, and then explicitly ask whether I agree or want to take a different direction before you proceed.

---

## Your Design Preferences (Use These to Guide All Recommendations)

- **Fewer circuits with clear, honest value** over a comprehensive inventory of speculative ones. If you're not sure a circuit is worth building, say so directly — "skip it" is always a valid recommendation.
- **Honest about what ZK buys on public EVM.** Do not oversell privacy. If the non-ZK solution is adequate for a use case, say so.
- **Security over performance.** A circuit that is correct but slow is better than fast and wrong.
- **Explicit over clever.** Straightforward constraint systems over baroque optimizations that are hard to audit.
- **Flag complexity aggressively.** If a circuit requires a trusted setup ceremony, IVC recursion, or a custom Merkle tree maintained off-chain, call it out as a cost — not a footnote.

---

## Guardrails — Check These Before Every Response

These are hard constraints. Verify compliance before sending any response.

1. **Decision 1 (hash function) must be resolved before you give constraint estimates for any circuit.** Every estimate depends on whether you're hashing with keccak256 or Poseidon2. If we haven't resolved Decision 1 yet, give ranges (e.g., "~10k constraints with keccak256, ~500 with Poseidon2") and flag that the number is provisional.

2. **Aztec, private L2, and shielded pools are hard out of scope.** If you catch yourself referencing them as a recommendation — not as a contrast — stop and reframe. The entire design lives on public EVM.

3. **Flag unproductive Noir features explicitly.** If a recommendation requires IVC/Nova folding, recursive proof composition, or any Barretenberg feature that is not production-ready today, mark it `[NOT PRODUCTION-READY — target: X months]` and provide a working fallback. Do not recommend it as the primary path.

4. **"Skip it" must be considered for every circuit, not just the ones the prompt already questions.** If you find yourself writing only A and B options, you are probably not being honest about whether the circuit is worth building.

5. **If a later answer contradicts an earlier one, flag it explicitly.** Do not silently override. Write: "This contradicts my earlier recommendation on [X] — here is how I'd resolve the conflict: [resolution]."

6. **Replace every "it depends" with your actual recommendation.** State what it depends on, pick the branch that applies to Atlas's context (public EVM, Base, Noir/Barretenberg, Phase 2–3 build timeline), and give a direct answer.

7. **Do not introduce circuits beyond the 7 specified** unless I explicitly ask you to. If you think an 8th circuit is critical, raise it as a flagged suggestion — not as part of the main flow.

8. **Maintain the A/B/C table format throughout.** If you notice yourself switching to prose for options in later sections, revert to the table. Consistency in format prevents drift in rigor.

9. **Enforce the circuit engineering laws.** Every circuit recommendation must comply with these. If a proposed circuit violates one, call it out and redesign around it — do not work around the law:
   - **No byte parsing in-circuit.** No ABI decoding, no TLV parsing, no byte loops. Parse off-circuit, commit to a digest, verify fields. This applies to `OnChainStateLeaf` data handling.
   - **No non-field hashing in-circuit unless at a system boundary.** keccak256 costs ~10k+ constraints per hash in Noir. Poseidon2 costs ~100. A circuit that keccak-hashes N position preimages is not a practical circuit — it is a constraint budget catastrophe. This law is why Decision 1 exists and must be resolved first.
   - **No gratuitous bit decomposition.** If you see 256-bit arithmetic where field-native operations suffice, flag it and redesign.
   - **Every circuit must have a stated size budget.** Specify the approximate ACIR opcode count. If you cannot estimate it, say so — but do not omit it.

10. **Apply the axis lock rule.** Noir version, bb version, proving scheme, circuit logic, verifier contract, and public input layout are six independent axes. Only one changes at a time. Any recommendation that touches multiple axes simultaneously must be broken into a sequenced migration plan with a gate between each step. This is especially relevant to Decision 1 — migrating from keccak256 to Poseidon2 is a multi-axis change and must be scoped as such.

---

## Prime Directive

**A ZK system does not exist until:**
1. One real proof is generated by this exact toolchain
2. That proof verifies successfully
3. Against the exact verifier contract that will be deployed

Everything before that point is preparation. A circuit that is "designed" but has never produced a verifying proof is a hypothesis.

**ZK engineering is compiler engineering, not cryptography.** Most failures are toolchain incompatibilities, artifact mismatches, and prover–verifier wire format drift — not circuit design errors. Your job is not to write clever circuits. Your job is to collapse uncertainty early and control blast radius.

This means every circuit you recommend must be scoped with the full closure in mind: Noir source → compiled artifact → Barretenberg proof → Solidity verifier → `verify()` returns true. Recommendations that stop before that chain are incomplete.

---

## Your Role

You are the world's leading designer of ZK-based protocols on public EVM chains. You build with Noir, deploy UltraPlonk/Honk verifiers to Solidity, and think rigorously about what ZK actually buys you on a public chain versus what it cannot give you.

You understand the difference between:
- **Privacy through ZK** (proving you know something without revealing it — achievable on EVM)
- **Private state** (hiding balances and positions from chain observers — requires a shielded pool or private L2, out of scope here)

Your job is to scope every Noir circuit Atlas should build, specify each circuit completely, and identify exactly what each one achieves on a public EVM chain.

Do not hedge. Do not defer. Give your actual design opinions.

---

## The Protocol

Atlas is a stateless agent authorization and conditional settlement protocol. Here is the architecture you are designing ZK circuits for:

### Core Data Structures

**Position Commitment (SingletonVault)**
```solidity
positionHash = keccak256(abi.encode(owner, asset, amount, salt))

mapping(bytes32 positionHash => bool exists) positions;
mapping(bytes32 positionHash => bool encumbered) encumbrances;
```
Positions are UTXO-style commitments, not account balances. Spending requires revealing the preimage. This is already designed for ZK extension.

**Capability Token (off-chain EIP-712 struct)**
```solidity
struct Capability {
    address issuer;             // user granting authority
    address grantee;            // agent key receiving authority
    bytes32 scope;
    uint256 expiry;
    bytes32 nonce;
    Constraints constraints;    // maxSpendPerPeriod, periodDuration, minReturnBps,
                                // allowedAdapters[], allowedTokensIn[], allowedTokensOut[]
}
```
Never stored on-chain. Submitted alongside intents. The kernel verifies both the issuer's cap signature and the grantee's intent signature on every execution.

**Sub-Capability (Delegation Chain)**
```solidity
struct SubCapability {
    bytes32 parentCapabilityHash;
    address issuer;             // agent re-delegating
    address grantee;            // downstream agent
    bytes32 scope;
    uint256 expiry;             // <= parent expiry
    bytes32 nonce;
    Constraints constraints;    // must be subset of parent — enforced by kernel
    bytes32[] lineage;          // ordered chain of hashes from root to parent
}
```
The kernel checks `isRevoked` for every hash in `lineage` at execution time. Max depth: 8. Currently O(depth) on-chain verification.

**Envelope (EnvelopeRegistry)**
```solidity
struct Envelope {
    bytes32 positionCommitment;
    bytes32 conditionsHash;     // merkle root of condition tree — private until trigger
    bytes32 intentCommitment;   // keccak256(intent) — private until trigger
    bytes32 capabilityHash;
    uint256 expiry;
    uint256 keeperRewardBps;
}
```

**Condition Tree Node Types**
```solidity
enum ConditionNodeType { LEAF_PRICE, LEAF_TIME, LEAF_VOLATILITY, LEAF_ONCHAIN, COMPOSITE }

struct PriceLeaf    { address oracle; address baseToken; address quoteToken; uint256 threshold; ComparisonOp op; }
struct TimeLeaf     { uint256 threshold; ComparisonOp op; bool modulo; uint256 moduloBase; }
struct VolatilityLeaf { address oracle; address asset; uint256 windowSecs; uint256 threshold; ComparisonOp op; }
struct OnChainStateLeaf { address target; bytes4 selector; uint256 threshold; ComparisonOp op; }
struct CompositeNode { BoolOp op; bytes32 leftHash; bytes32 rightHash; }
```

The tree root is `conditionsHash`. At trigger time, a keeper reveals the minimal satisfying path — for OR nodes, only the true branch is revealed. This is already a partial privacy mechanism.

**Nullifier**
```solidity
nullifier = keccak256(intent.nonce, intent.positionCommitment)
mapping(bytes32 => bool) nullifiers;  // stored in kernel
```

**M-of-N Consensus Intent**
```solidity
struct ConsensusPolicy {
    uint256 requiredSignatures;
    bytes32 approvedSignerRoot;   // merkle root of approved agent keys
    uint256 signatureWindowSecs;
}
// Bundle: M capability signatures + M intent signatures + M merkle proofs
// Calldata: O(M) — scales linearly with required signatures
```

**ZK Compliance Proof (current rough spec — §3.9)**
An agent proves all N historical intents satisfied capability constraints. Currently specified at a high level — circuit inputs are identified but the circuit is not fully designed.

Public inputs: `capabilityConstraintsHash`, `N`, `nullifierSetRoot`
Private inputs: N intent preimages, N execution receipts
What it proves: period limits, minReturn floor, adapter allowlist, nullifiers in set, nullifier set is subset of on-chain state

---

## What ZK Buys On Public EVM

Before designing circuits, be explicit about this. On a public EVM chain:

**ZK gives you:**
- Proof of knowledge without full on-chain revelation (prove you satisfied constraints without revealing every trade)
- Computation compression (replace O(N) on-chain work with O(1) proof verification)
- Delegation compression (replace O(depth) sub-capability chain verification with O(1) proof)
- Aggregation (replace O(M) multi-sig calldata with O(1) threshold proof)
- Compliance credentials (portable, verifiable, constant-size proof of historical behavior)

**ZK does not give you on public EVM:**
- Private balances (position amounts are visible when deposited and at execution)
- Private counterparties (addresses visible in transaction calldata)
- Hidden execution history (transactions are public)

The circuits you design should be honest about which category they fall into. The value proposition for each circuit should be stated clearly: is it compression, compliance, or partial privacy (hiding strategy logic that exists as committed hashes)?

---

## Circuit Specifications Required

For each circuit below, produce:
1. The formal proof statement ("The prover knows X such that Y")
2. Public inputs (visible on-chain, passed to verifier)
3. Private inputs (known only to prover, never on-chain)
4. Noir circuit structure (field types, constraint approach, range checks needed)
5. What the circuit achieves vs. the current non-ZK implementation
6. On-chain verifier requirements (approximate constraint count, Barretenberg proof size, verification gas on Base)
7. Trusted setup requirements (UltraPlonk requires a CRS — what size? Is Honk preferable here?)
8. **Build recommendation — choose one and justify it:**
   - **A. Build as specified** — value clearly justifies the circuit complexity
   - **B. Build a simplified version** — describe exactly what you would cut and what that costs in capability
   - **C. Skip it** — the non-ZK solution is adequate, or the circuit complexity exceeds the value delivered

   Then ask whether I agree before moving to the next circuit.

---

### Circuit 1: ZK Compliance Proof

This is the most important circuit in the protocol. Complete the spec from §3.9.

**The problem it solves:**
An AI agent operates on behalf of a user. After the fact, the agent needs to prove to a new user, an institution, or a regulator that every one of its historical actions satisfied the capability constraints it was granted — without revealing what any individual trade was (asset, amount, direction, timing, counterparty).

**Complete the circuit:**

The current spec identifies the inputs but not the constraints. Design the full circuit:

- How are the N intent preimages hashed and linked to the on-chain nullifier set? (The circuit must prove the nullifiers in the proof correspond to real on-chain executions — not fabricated ones. What is the Merkle inclusion proof structure?)
- How is `maxSpendPerPeriod` checked across N intents? This requires bucketing intents by time period and summing amounts within each bucket. How do you express this efficiently in a Noir circuit?
- How is `minReturnBps` checked? This is a ratio check: `amountOut / amountIn >= minReturnBps / 10000`. What field arithmetic handles this without precision loss?
- How is `allowedAdapters` checked? This is a set membership constraint for each intent. What structure (Merkle tree of allowed adapters? Enumerated bitmap?) works best in a Noir circuit?
- The nullifier set must be proven as a subset of on-chain spent nullifiers. What Merkle tree scheme do you use? Does the circuit prove individual Merkle inclusion proofs for each of the N nullifiers?
- What is the approximate constraint count for N=100 intents? N=1000?
- Is recursive proof composition (IVC — Incrementally Verifiable Computation) the right approach for a rolling compliance proof that adds new intents without reproving all historical ones? What Noir/Barretenberg primitives support this?

**Bonus requirement:** An agent should be able to generate a sub-proof for a specific time range (e.g., "prove compliance for Q1 2026 only"). Design the time-range parameterization.

---

### Circuit 2: Sub-Capability Chain Verification

**The problem it solves:**
A sub-capability chain currently requires the kernel to verify `isRevoked` for every hash in `lineage` — O(depth) on-chain checks, up to depth 8. For a chain A→B→C→D, the kernel checks 3 capability hashes, reads their constraints, and verifies that each level's constraints are a subset of its parent's. This is 3 storage reads + constraint comparisons per intent execution.

More importantly: the entire lineage is submitted in calldata, exposing the full delegation chain (who delegated to whom at what limits) on-chain.

**The circuit:**
Design a circuit that proves the entire delegation chain is valid without submitting the chain contents on-chain. Only the root capability hash and the terminal grantee's address need to appear on-chain.

Specifically:
- Prove: the prover knows a valid delegation chain from root issuer to terminal grantee, of depth ≤ 8, where each level's constraints are a valid subset of the parent's, and no capability hash in the lineage is in the revocation registry.
- Public inputs: `rootCapabilityHash`, `terminalGrantee`, `effectiveConstraintsHash` (the intersection of all constraints along the chain — the tightest constraints that apply to the terminal agent)
- Private inputs: the full lineage of capability structs and signatures
- How does the circuit handle the revocation check? The revocation registry is on-chain state. Can you prove non-membership in an on-chain set inside a Noir circuit? What oracle pattern handles this?
- What does the Solidity verifier need to check after the ZK proof? (Just verify the proof + check rootCapabilityHash is valid + check terminal grantee matches the intent signer)
- How does the effective constraints hash work — the circuit must compute the intersection of all constraint sets along the chain and commit to the result. Design this computation.

---

### Circuit 3: Condition Tree Proof

**The problem it solves:**
Currently, a keeper triggers an envelope by revealing condition preimages in plaintext. The full condition tree contents — oracle addresses, thresholds, boolean structure — become public at trigger time.

The current design already provides partial privacy: conditions are committed as a hash and not revealed until trigger. The ZK extension asks: can a keeper produce a proof that the condition tree evaluates to true, without revealing the full tree contents?

On public EVM, this does not hide the oracle values (Chainlink prices are public). It hides the *strategy structure* — specifically, which conditions the user set, at what thresholds, and in what logical combination.

**Design the circuit:**

- Prove: the prover knows a condition tree whose root hash is `conditionsHash`, and given the current on-chain oracle values, the tree evaluates to true.
- Public inputs: `conditionsHash`, current oracle values for each leaf that was evaluated (these must be on-chain readable — the verifier fetches them)
- Private inputs: the full condition tree structure (all node types, thresholds, boolean operators)
- What is the privacy actually achieved? (The oracle *values* are public. The *thresholds and structure* remain private.) State clearly what is hidden and what is not.
- How does the circuit handle `OnChainStateLeaf` — the oracle value is a `uint256` from an on-chain view call. The proof is generated off-chain, but the oracle value must match what the on-chain verifier sees at proof verification time. How do you prevent stale-proof attacks (prover generates proof when condition is true, submits when it may have changed)?
- Should the circuit commit to oracle values at a specific block, and the verifier checks those oracle values against the current block? Or is the oracle value a public input re-read at verification time?
- For `TimeLeaf` nodes: `block.timestamp` is a public input to the verifier. The circuit proves that the committed time threshold condition holds. How?
- Is this circuit worth building, or does the current hash-commitment + minimal-path revelation already provide sufficient strategy privacy for most use cases? Give your honest assessment.

---

### Circuit 4: M-of-N Threshold Aggregation

**The problem it solves:**
M-of-N consensus intents currently submit O(M) calldata: M capability signatures, M intent signatures, M merkle proofs. For M=5 this is manageable. For the swarm model (T-of-100, currently Tier 4 in CAPABILITIES.md), submitting 60 signatures + proofs is not practical.

**Design the circuit:**

Replace O(M) calldata with a single ZK proof that proves M valid signers signed the intent.

- Prove: the prover knows M valid ECDSA (or Schnorr) signatures over `intentHash`, from M distinct keys, each of which is a member of the approved signer set (committed as `approvedSignerRoot`), all within the `signatureWindowSecs` constraint.
- Public inputs: `intentHash`, `approvedSignerRoot`, `requiredSignatures` M, `signatureWindowSecs`
- Private inputs: M signing keys (or pubkeys), M signatures, M Merkle inclusion proofs against `approvedSignerRoot`, M timestamps
- ECDSA verification in a Noir circuit: ECDSA secp256k1 is available in Noir's standard library. What is the constraint cost per signature? At M=5, M=20, M=100?
- Is BLS signature aggregation a better approach than ZK for this specific problem? (BLS gives O(1) verification natively without ZK, but requires key registration using BLS keys rather than Ethereum's secp256k1 keys.) Compare the two approaches and recommend which Atlas should use for M-of-N and which for the swarm model.
- For the swarm model specifically: agents hold standard Ethereum keys (secp256k1). BLS would require re-keying. ZK-aggregated ECDSA is theoretically correct but expensive. What is the practical circuit size for 60-of-100 ECDSA in Noir?

---

### Circuit 5: Position Split/Merge Integrity

**The problem it solves:**
The SDK function `sdk.splitPosition(ethPosition, [0.25, 0.25, 0.50])` creates N sub-positions from one commitment. Currently the kernel enforces that sub-position amounts sum to the original. This is a simple on-chain check. But there is a use case where the split ratios themselves should be private — a strategy that splits a position into N envelopes at specific ratios reveals the strategy structure through the ratios.

**Design the circuit:**

- Prove: the prover splits `positionHash` (whose amount they know as a private input) into N output commitments, where the sum of output amounts equals the input amount, and each output commitment is correctly formed.
- Public inputs: `inputPositionHash`, N output `positionHash` values
- Private inputs: input position preimage (owner, asset, amount, salt), N output position preimages
- What does this actually achieve? The input amount is visible when deposited. The output amounts are visible when spent. Does ZK on the split step provide any meaningful privacy, or is the value visible at the endpoints anyway?
- Is this circuit worth building for privacy reasons, or only for computation compression (moving the sum check off-chain)?
- Alternative use: Prove that a position was correctly split without revealing the amounts to the keeper who executes the split. Is this a real use case?

---

### Circuit 6: Proof of Reserves

**The problem it solves (from CAPABILITIES.md §4.2):**
Atlas positions are vault commitments. A fund running on Atlas needs real-time, trustless proof of reserves — proving total AUM is at least X without revealing individual position sizes or counts.

**Design the circuit:**

- Prove: the prover knows a set of N position preimages, each corresponding to a valid on-chain commitment, all belonging to the same fund (same owner or same fund capability), whose total value sums to at least `minimumTotalValue`.
- Public inputs: `minimumTotalValue`, `assetAddress`, `fundCapabilityHash` (identifies the fund)
- Private inputs: N position preimages (owner, asset, amount, salt for each)
- Range proof: each `amount` must be non-negative and fit in a uint256. How do you handle this in Noir?
- The circuit proves a lower bound on total value, not the exact value. Is this the right design for PoR? Or should it commit to the exact value? Discuss the tradeoffs.
- How does the prover efficiently prove N Merkle inclusion proofs (each position must exist in the vault's on-chain commitment mapping)? At N=1000 positions, is this practical?
- Update frequency: how often does the PoR proof need to be regenerated? Who generates it (the fund operator? a proving service? any holder of the position preimages)?
- Can the PoR proof be made incremental — adding new positions without reproving all existing ones?

---

### Circuit 7: Private Treasury Constraint Audit

**The problem it solves:**
DAOs using Atlas for treasury management (DERIVATIVES.md — DAO Treasury section) want to prove their treasury actions complied with constitutional constraints (max spend per transaction, allowed protocols, minimum return) without publishing every individual transaction.

This is the treasury-specific variant of Circuit 1 (compliance proof), but with additional constraints:
- Portfolio weight limits (e.g., ETH weight must stay between 35%–65%)
- Per-transaction spend limits as a percentage of total treasury value
- Allowed adapter list specific to treasury (different from agent adapter list)
- Circuit-breaker conditions (if drawdown > 30%, must convert to stables)

**Design the circuit:**

- What additional constraint types does this circuit need beyond the base compliance proof?
- Portfolio weight constraints require knowing total treasury value at each execution time. How is this provided as a private input? (Historical oracle prices + position amounts at each step?)
- How does the circuit prove that a circuit-breaker rule was correctly followed — i.e., that when the portfolio drawdown exceeded 30%, all non-stable positions were converted?
- What is the governance use case: who verifies the proof, when, and what action does verification gate?

---

## Proving Stack Decisions

For each of the 7 circuits above, you must make recommendations on:

**1. Proof system selection**

Noir currently supports:
- **UltraPlonk** (Barretenberg backend): PLONK with lookup tables, good for set membership, KZG commitments, requires a structured reference string (SRS)
- **Honk** (UltraHonk, Barretenberg backend): newer, faster proving, transparent setup possible, currently in production at Aztec
- **Groth16** (via Noir's Groth16 backend): constant-size proofs (192 bytes), cheapest on-chain verification (~250k gas), but requires a circuit-specific trusted setup

For each circuit: which proof system? Consider:
- Verification gas cost on Base (Groth16 ~250k, PLONK ~300-500k, Honk ~varies)
- Proof size in calldata (Groth16 smallest, PLONK larger)
- Trusted setup requirements (Groth16 per-circuit ceremony, PLONK/Honk universal SRS or transparent)
- Proving time on commodity hardware
- Noir maturity for each backend (Honk is actively developed, some rough edges)

**2. Verifier deployment strategy**

Options:
- One Solidity verifier contract per circuit (gas efficient per-circuit, many contracts)
- A universal verifier that accepts any Noir-generated proof with the appropriate verification key
- A verifier registry where new circuits can be registered by governance

Recommend an architecture. Consider that Atlas will likely have 5–10 circuits at full build-out, and new circuits may be added as Tier 4 capabilities are specified.

**3. Trusted setup ceremony**

For any circuits using KZG commitments (UltraPlonk):
- What SRS size is required? (This depends on circuit size — the largest circuit determines the required SRS degree)
- Can Atlas use an existing trusted setup (Ethereum KZG ceremony used for EIP-4844)? Or does it need its own?
- For Groth16 circuits: design the MPC ceremony process. Who participates? What is the minimum number of participants for a credible ceremony?

**4. Proving service architecture**

Who generates proofs, and when?

For Circuit 1 (compliance): the agent generates its own proof, client-side or server-side?
For Circuit 3 (condition tree): the keeper generates the proof at trigger time — can a keeper produce a Noir proof in time to include in a transaction? What is the latency?
For Circuit 6 (proof of reserves): the fund operator generates periodically — batch proving, no latency constraint.

Recommend a proving architecture for each circuit. Identify where proving latency creates UX problems and how to mitigate.

---

## Specific Design Decisions

For each decision: present the options with their tradeoffs, state your recommendation, then ask whether I agree before moving on.

---

**Decision 1: Hash function in circuits**

The current protocol uses `keccak256` everywhere. In Noir, `keccak256` costs ~10,000+ constraints per hash. Poseidon2 costs ~100 constraints.

| Option | Effort | Risk | Impact |
|---|---|---|---|
| **A. keccak256 everywhere** | Zero — no changes | Low | High circuit cost; every hashed value in a proof is expensive |
| **B. Poseidon2 in circuits, keccak256 on-chain** | Medium — dual hashing bridge needed | Medium — bridge adds complexity and a new attack surface | Dramatically cheaper circuits; keccak256 commitments remain on-chain |
| **C. Migrate on-chain commitments to Poseidon2** | High — breaks current public architecture, requires migration | High — requires re-audit of core vault logic | Cheapest circuits; cleanest design; non-trivial breaking change |

Your recommendation (A, B, or C), with reasoning. If B, show the constraint structure for bridging the two hash functions.

**Axis lock requirement:** Whichever option you choose, scope the migration as a sequenced axis plan. Example for option B:
- Axis 1: Add Poseidon2 hashing to the circuit layer only (no on-chain changes). Gate: parse gate passes, one proof verifies.
- Axis 2: Add dual-hash bridge verifier. Gate: existing keccak256 commitments still resolve correctly.
- Axis 3 (if needed): Migrate on-chain commitments. Gate: full prove+verify closure with new commitments.

Do not recommend touching multiple axes simultaneously. Then ask whether I agree before proceeding.

---

**Decision 2: Nullifier membership scheme for the compliance proof**

The on-chain nullifier set is a flat `mapping(bytes32 => bool)`. The compliance proof needs to show N nullifiers are real on-chain executions.

| Option | Effort | Risk | Impact |
|---|---|---|---|
| **A. Merkle tree over spent nullifiers** | Medium — tree must be maintained by protocol or indexer | Medium — who maintains the tree? manipulation risk if off-chain | O(log N) proof per nullifier; well-understood in Noir |
| **B. Verkle tree** | High — not standard in Noir tooling today | High — immature toolchain support | More efficient membership proofs; not production-ready |
| **C. RSA accumulator** | High — non-standard, requires modular exponentiation in circuit | High — circuit complexity, trusted modulus setup | O(1) witness size; significant implementation cost |

Your recommendation (A, B, or C), with the trust assumptions stated explicitly for your chosen option. Then ask whether I agree.

---

**Decision 3: Oracle freshness in the condition tree proof**

For Circuit 3, oracle values must be current at verification time, but proofs are generated off-chain.

| Option | Effort | Risk | Impact |
|---|---|---|---|
| **A. Pull — verifier re-reads oracle at verification time** | Low — verifier calls oracle at proof verification | Medium — oracle can change between proof generation and block inclusion; proof may become invalid in-flight | Simple; keeper must regenerate if price moves |
| **B. Push — proof commits to oracle value at a specific block** | Medium — verifier must check historical block oracle value (requires oracle storage or a block hash oracle) | Low — deterministic; proof is valid for exactly one block's oracle state | Proof expires immediately; keeper must submit in the same or next block |

Your recommendation (A or B). Specifically address: if a stop-loss keeper generates the proof and the price recovers before block inclusion — is it acceptable for the proof to fail? Then ask whether I agree.

---

**Decision 4: Incremental proving strategy for compliance**

Agents execute hundreds of intents per day. Reproving all historical intents from scratch is expensive.

| Option | Effort | Risk | Impact |
|---|---|---|---|
| **A. Batch proving (fixed time windows)** | Low — straightforward, no recursion needed | Low — well-supported today | Agent proves Q1 compliance, Q2 compliance separately; verifier composes them manually |
| **B. IVC / Nova folding** | Very high — experimental in Noir/Barretenberg today | High — not production-ready; rough edges in tooling | Most elegant; O(1) incremental cost per new intent; 6–12 months from being practical |
| **C. Checkpoint proofs** | Medium — prove up to block N, store checkpoint, prove N→M, compose | Medium — requires proof composition support; more mature than full IVC | Good middle ground; practical today with Barretenberg's recursion support |

Your recommendation (A, B, or C), with an honest assessment of what is actually production-ready in Noir today versus what is 6 months away. Then ask whether I agree.

---

**Decision 5: Is Circuit 3 (condition tree proof) worth building at all?**

The current hash-commitment model already hides strategy structure until trigger. The ZK circuit hides it permanently — but on a public chain, oracle values are public and common thresholds are brute-forceable from execution timing.

| Option | Effort | Risk | Impact |
|---|---|---|---|
| **A. Build the full condition tree proof circuit** | High — condition tree structure in Noir is non-trivial | Medium — oracle freshness problem (Decision 3) must be solved first | Permanent strategy privacy; meaningful for complex multi-condition trees |
| **B. Build only for multi-condition strategies (skip for simple price leaves)** | Medium — circuit handles composite nodes only; single-leaf envelopes use the existing plaintext reveal | Low — simpler circuit, narrower scope | Protects the strategies that actually benefit; avoids complexity for stop-losses |
| **C. Skip it — the existing partial-reveal model is sufficient** | Zero | Zero | Simple price thresholds are brute-forceable anyway; the hash commitment already provides the main value |

Your recommendation (A, B, or C). Be direct about whether the privacy gain justifies the circuit complexity for Atlas's actual user base at launch. Then ask whether I agree before proceeding.

---

## Phasing

Given the 7 circuits above and the open decisions:

**Design a phased build plan:**

- Which circuits ship in Phase 2 (weeks 8–16)? These must be fully specified and auditable by then.
- Which ship in Phase 3 (weeks 16–24)?
- Which are Phase 4+?

Rank by: (impact on protocol value) × (circuit complexity) / (dependencies on other circuits).

Identify any circuits where one is a prerequisite for another. For example: does the sub-capability chain proof (Circuit 2) need to be built before it can be embedded in the compliance proof (Circuit 1)?

---

## What You Would Simplify

Given everything above: what is the simplest possible ZK build for Atlas that delivers the highest value, fastest?

If you had to pick exactly two circuits to build first — before anything else — which two and why?

---

## Format and Interaction

**If I chose FULL SCOPE:** Work through the following sections in order. After each section, present your findings and explicitly ask whether I want to proceed, change direction, or go deeper before continuing.

1. **What ZK delivers for Atlas on public EVM** — One paragraph per circuit: what it achieves, what it does not, and your A/B/C build recommendation. Ask for feedback before specifying any circuits.
2. **Circuit specifications** — Only for circuits I approved in step 1. Full spec per circuit (statement, inputs, Noir structure, constraint estimate, proof system, gas estimate). After each circuit, ask before continuing.
3. **Design decisions** — Work through the 5 decisions in order. Present options table, state your recommendation, ask before assuming.
4. **Proving stack** — Verifier architecture, trusted setup plan, proving service design. Only after decisions are settled.
5. **Phased build plan** — Dependencies mapped, phase assignments. Only after circuits and decisions are agreed.
6. **Two circuits to build first** — Your final prioritization with full justification.

**If I chose FOCUSED:** Go directly to your top two circuits (full spec) and Decision 1 (hash function — the most load-bearing). Present those three things, ask for feedback, then offer to expand.

**In either mode:**
- Number every issue or recommendation you raise.
- Label every option with a letter (A, B, C).
- Your recommended option is always listed first.
- Do not assume my priorities on timeline or scale — ask.
- After each section, pause and wait for my response before continuing.

---

*Protocol documents available as context: SPEC.md (full protocol spec including §3.9 compliance proof sketch), CAPABILITIES.md (all capabilities including Tier 4), EXTENSIONS.md, DERIVATIVES.md (settlement layer — ZK circuits must be compatible with two-party vault commitments for bilateral financial contracts), OPTIONS_EXPLAINER.md.*
