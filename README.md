# Atlas Protocol

A stateless execution layer for AI agent finance. Agents pre-commit to DeFi
actions — loan repayments, treasury failsafes, stop-losses — that execute
permissionlessly by keepers even when the agent is completely offline.

The core invariant: **a valid capability + intent + nullifier produces a
deterministic, bounded, non-replayable execution. Nothing else does.**

---

## The Problem

| Scenario | Without Atlas | With Atlas |
|---|---|---|
| Agent goes offline at 3am | Position unmanaged | Envelope triggers via any keeper |
| Agent key compromised | Everything within session scope drained | Capability `maxSpendPerPeriod` caps loss to the period limit |
| Multi-agent delegation | Multiple accounts, no constraint inheritance | Sub-capabilities verified as strict subset of parent |
| Prove compliance without revealing trades | Not possible | ZK receipt chain → on-chain credit tier upgrade |

---

## Repository Structure

```
contracts/           — Solidity 0.8.24 (Foundry)
  Types.sol            Shared data structures: Position, Capability, Intent, Envelope
  HashLib.sol          EIP-712 type hashes — single source of truth for contracts + SDK
  SingletonVault.sol   Hash-commitment asset vault (no per-user balance mappings)
  CapabilityKernel.sol 18-step verification + execution coordinator
  EnvelopeRegistry.sol Oracle-gated conditional execution store
  ReceiptAccumulatorSHA256.sol  Per-capability receipt log (ZK anchor, SHA-256 variant)
  CreditVerifier.sol   ZK-proof-gated credit tier assignment
  adapters/
    ClawloanRepayAdapter.sol   Repay Clawloan debt, return surplus
    DirectTransferAdapter.sol  Treasury failsafe: transfer to pre-committed beneficiary
    UniswapV3Adapter.sol       Uniswap V3 single-hop and multi-hop swaps
    AaveV3Adapter.sol          Aave V3 supply / withdraw
    demo/                      Scenario adapters (liquidation, stop-loss, pool-pause, etc.)
  verifiers/
    BiniusCircuit1Verifier.sol  Active: trusted-attester wrapper for Binius64 proofs
    HonkCircuit1Verifier.sol    Archived: alternative Noir/Barretenberg verifier
  interfaces/          IAdapter, ICircuit1Verifier, IReceiptAccumulator, IEnvelopeRegistry
  oracles/             UtilisationOracle (Chainlink-compatible pool utilisation feed)

sdk/                 — TypeScript SDK (@atlas-protocol/sdk)
  src/
    types.ts           TypeScript mirrors of all Solidity structs
    eip712.ts          Off-chain EIP-712 hashing matching HashLib.sol exactly
    builders.ts        buildCapability, buildIntent, buildEnvelope helpers
    signing.ts         signCapability, signManageCapability, signIntent
    position.ts        hashPosition, randomSalt, hashNullifier
    adapters.ts        Adapter data encoding (clawloan, uniswap, aave)

ui/                  — React 19 + Vite 7 + Tailwind CSS 4
  src/
    App.tsx            Scenario router + Clawloan demo flow (Phase 1)
    lib/
      triggerEnvelope.ts  Keeper trigger logic (shared between manual + auto-simulate)
      creditProof.ts      Binius64 proof generation + on-chain attestation submission
    scenarios/         15+ scenario components (DMS, orchestration, stop-loss, etc.)
    components/        Shared UI: StepCard, TxButton, LogPanel, KeeperNetworkPanel, etc.
    hooks/             useChainState — wagmi multi-read polling hook
    contracts/         addresses.ts + abis.ts (all contract interfaces)
  proof-server.mjs     Node.js HTTP server wrapping the Rust prover binary

Binius/
  binius64-compliance/ Active Rust prover: compliance circuit + service binary
  binius64/            Vendored Binius64 framework (path dependency)
  binius-research/     Earlier research / archived circuits (see README inside)
  binius-verifier/     Solidity Binius64 verifier (under development, not yet deployed)

circuits/circuit1/   Archived: Noir/Barretenberg alternative ZK stack (superseded by Binius64)
test/                Foundry tests
  mocks/             14 mock contracts
  fork/              Fork tests against Arbitrum mainnet state
script/              Foundry deployment scripts
```

---

## Execution Flow

An agent pre-signs a repayment, goes offline, and a keeper executes it later.

```
Agent (off-chain)
  sign Capability  ──── EIP-712, zero gas — bounds what can be spent
  sign Intent      ──── EIP-712, zero gas — exact execution parameters
  call register()  ──── position becomes encumbered in SingletonVault

EnvelopeRegistry
  stores keccak256(Envelope)  ──── only the hash lives on-chain
  calls vault.encumber()      ──── agent cannot withdraw while registered

[ any keeper, once oracle condition is met ]
  call trigger(hash, conditions, intent, ...)
    EnvelopeRegistry: verify conditions hash, forward to CapabilityKernel
    CapabilityKernel: 18-step verification (signatures, scope, expiry,
                      nullifier, deadline, token constraints, spending)
    adapter.execute()  ──── loan repaid / funds transferred / position closed

SingletonVault
  commit output as new position  ──── surplus returned to agent
  ReceiptAccumulator.record()    ──── receipt anchored for ZK proof

[ later, any time ]
  prove receipt chain with Binius64 (~173ms)
  CreditVerifier.submitProof()  ──── tier upgraded, borrow limit increases
```

---

## Demo Scenarios

All scenarios run on a local Anvil node. Start Anvil, deploy, run the UI.

| URL | Scenario | What it demonstrates |
|---|---|---|
| `/` | **Clawloan Credit** | Liveness-independent repayment + ZK credit tier upgrade |
| `/?scenario=dms` | **Dead Man's Switch** | Beneficiary-committed treasury failsafe |
| `/?scenario=orchestration` | **Sub-agent Fleet** | Hierarchical budget isolation across 2 agents |
| `/?role=keeper` | **Keeper Mode** | Third-party execution from a separate wallet tab |
| `/?scenario=stoploss` | Stop-Loss | Price-triggered position exit |
| `/?scenario=liquidation` | Liquidation | Keeper-triggered collateral seizure |
| `/?scenario=sg-chained` | Chained Strategy | Multi-step strategy graph |

### Phase 1 — Clawloan Credit

1. Agent mints USDC (simulating task earnings)
2. Borrows from Clawloan — unsecured, credit-based
3. Deposits earnings into Atlas vault
4. Signs repayment intent, registers envelope, **goes offline**
5. Keeper triggers at deadline — loan repaid, surplus returned, receipt emitted
6. Agent submits Binius64 ZK proof — credit tier upgraded from NEW → BRONZE

### Phase 2 — Dead Man's Switch

Agent pre-signs: "transfer $2,000 to DAO multisig if I miss a heartbeat for 24h."
Periodically cancels and re-registers with a fresh deadline. If the agent goes
dark, any keeper triggers the transfer. The beneficiary address is committed in
the EIP-712 intent hash and cannot be redirected by an attacker.

### Phase 3 — Sub-agent Fleet

Orchestrator deploys two sub-agents (Alpha: yield, Beta: arb) each with a
$1,500 allocation from a $3,000 budget. Each runs an independent Clawloan
credit cycle. `MockSubAgentHub` enforces per-agent budget caps at the
application layer (Phase 2 will enforce via `parentCapabilityHash` on-chain).

---

## Local Setup

### Prerequisites

- [Foundry](https://getfoundry.sh/) — `forge`, `anvil`, `cast`
- Node.js ≥ 18
- Rust (for the Binius64 proof server)
- Git submodules (OpenZeppelin)

### 1. Initialize git submodules

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

### 4. Deploy the demo stack

Use only this script — running `Deploy.s.sol` would shift deployer nonces and
change all contract addresses.

```bash
forge script script/DeployClawloanDemo.s.sol \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
```

### 5. Build the SDK

```bash
cd sdk && npm install && npm run build
```

### 6. Start the proof server

The proof server wraps the Binius64 Rust binary and exposes `POST /api/prove`.
Build the Rust prover first:

```bash
cd Binius/binius64-compliance && cargo build --release
```

Then start the server (from the `ui/` directory):

```bash
cd ui && node proof-server.mjs
```

The server listens on `http://localhost:3001`.

### 7. Start the UI

```bash
cd ui && npm install && npm run dev
```

Open `http://localhost:5173`. Connect MetaMask to `localhost:8545`, chain ID
`31337`. The UI auto-airdrops 10 ETH to your wallet on first connect.

---

## Running Tests

```bash
# All Foundry unit + integration tests
forge test -v

# SDK hash parity tests (requires Anvil + deployed contracts)
cd sdk && npm test

# Fork tests (requires ARBITRUM_RPC_URL in .env)
forge test --match-path "test/fork/*" -v
```

---

## Deployed Addresses

These addresses are deterministic from Anvil account 0, nonce 0. They are
always the same on a fresh Anvil instance after running `DeployClawloanDemo.s.sol`.

```
MockUSDC                  0x5FbDB2315678afecb367f032d93F642f64180aa3
MockClawloanPool          0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512
MockTimestampOracle       0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9
SingletonVault            0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9
CapabilityKernel          0x5FC8d32690cc91D4c39d9d3abcBD16989F875707
EnvelopeRegistry          0x0165878A594ca255338adfa4d48449f69242Eb8F
ReceiptAccumulatorSHA256  0xa513E6E4b8f2a923D98304ec87F64353C4D5C853
CreditVerifier            0x8A791620dd6260079BF849Dc5567aDC3F2FdC318
ClawloanRepayAdapter      0x610178dA211FEF7D417bC0e6FeD39F05609AD788
DirectTransferAdapter     0xB7f8BC63BbcaD18155201308C8f3540b07f84F5e
```

Override at runtime via `VITE_ADDR_*` env vars (see `.env.example`).

---

## Architecture Notes

### EIP-712 dual-domain design

`CapabilityKernel` and `EnvelopeRegistry` have separate EIP-712 domains. A
capability signed for the kernel cannot be replayed against the registry and
vice versa. `HashLib.sol` is the single source of truth for all type hashes —
both the SDK (`eip712.ts`) and the contracts import from it.

### Position model

Positions are stored as `keccak256(abi.encode(Position))` — no per-user balance
mappings. This means depositing identical parameters twice produces a collision;
the `salt` field exists precisely to prevent this. `randomSalt()` in the SDK
generates a random `bytes32`.

### ZK stack

| Component | Technology | Status |
|---|---|---|
| Prover | Binius64 (Rust) | Active — ~173ms prove, ~47ms verify |
| EVM verification | Trusted-attester ECDSA (`BiniusCircuit1Verifier`) | Active (interim) |
| EVM verification | Direct on-chain Binius64 verifier | In development (`Binius/binius-verifier/`) |
| Alternative prover | Noir + Barretenberg UltraHonk | Archived (`circuits/circuit1/`, `HonkCircuit1Verifier.sol`) |

The compliance circuit proves a SHA-256 rolling hash chain of execution receipts
(up to 64 steps). Public inputs: `(capability_hash, final_root)`. The
`final_root` is verified against `ReceiptAccumulatorSHA256.adapterRootAtIndex()`
before `CreditVerifier` accepts the proof.

### Security fixes included

| ID | Fix |
|---|---|
| L-3 | `EnvelopeRegistry.register()` verifies position ownership via preimage reveal |
| M-1 | Chainlink round-completeness check in `EnvelopeRegistry.trigger()` |
| H-2 | 2-day timelock on `CreditVerifier` verifier address upgrades |
| H-3 | Per-adapter rolling roots in `ReceiptAccumulatorSHA256` |

---

## Further Reading

| Document | Contents |
|---|---|
| `SPEC.md` | Formal protocol specification — data types, interfaces, execution flows, security model |
| `ZK_ARCHITECTURE.md` | Circuit design — hash function choice, public input layout, EVM verification strategy |
| `AUDIT_PREP.md` | Threat model and audit readiness notes |
| `DECISIONS.md` | All architectural decisions with trade-offs recorded |
| `EXTENSIONS.md` | Phase-shift extensions: options protocol, strategy graphs, sustained conditions |
| `WHITEPAPER.md` | Narrative overview and motivation |
| `sdk/README.md` | SDK API reference |
