# Atlas Protocol — Demo UI

React 19 + Vite 7 + Tailwind CSS 4 frontend demonstrating the full Atlas
Protocol lifecycle against a local Anvil node.

## Prerequisites

1. Anvil running at `http://127.0.0.1:8545`
2. Contracts deployed via `DeployClawloanDemo.s.sol` (see root `README.md`)
3. SDK built: `cd ../sdk && npm run build`
4. Proof server running: `node proof-server.mjs` (requires `binius64-compliance` compiled)

## Run

```bash
npm install
npm run dev
```

Open `http://localhost:5173`. Connect MetaMask to `localhost:8545`, chain ID `31337`.
The UI auto-airdrops 10 ETH to your wallet on first connect via `anvil_setBalance`.

## Demo Scenarios

| URL | Scenario |
|---|---|
| `/` | Clawloan Credit — liveness-independent repayment + ZK credit tier |
| `/?scenario=dms` | Dead Man's Switch — treasury failsafe on heartbeat timeout |
| `/?scenario=orchestration` | Sub-agent Fleet — hierarchical budget isolation |
| `/?role=keeper` | Keeper Mode — trigger envelopes from a separate wallet |

## Source Structure

```
src/
  App.tsx            — Scenario router + Clawloan (Phase 1) demo flow
  lib/
    triggerEnvelope.ts — Keeper trigger logic: warp time, simulate, broadcast
    creditProof.ts     — Binius64 proof generation + on-chain attestation
  scenarios/         — One component per scenario (DMS, orchestration, stoploss, etc.)
  components/        — Shared components: StepCard, TxButton, LogPanel, etc.
  hooks/
    useChainState.ts — wagmi multi-read hook: wallet balance, vault state, credit tier
  contracts/
    addresses.ts     — Deployed addresses (overrideable via VITE_ADDR_* env vars)
    abis.ts          — Full viem ABIs including all custom errors
proof-server.mjs     — Node.js HTTP server: POST /api/prove → Rust prover binary
```

## Clawloan Demo Steps

| Step | Action | On-chain call |
|---|---|---|
| 0 | Mint test USDC | `MockERC20.mint(address, 1000e6)` |
| 1 | Borrow from Clawloan | `MockClawloanPool.borrow(botId=1, 500e6)` |
| 2 | Deposit earnings | `ERC20.approve` + `SingletonVault.deposit(token, amount, salt)` |
| 3 | Register envelope | 3× EIP-712 sign, `EnvelopeRegistry.register(envelope, manageCap, sig, position)` |
| 4 | Trigger (keeper) | Warp Anvil time, `EnvelopeRegistry.trigger(hash, conditions, ...)` |
| 5 | Submit credit proof | `CreditVerifier.submitProof(capHash, n, adapter, 0, proof)` |

After trigger: debt repaid to pool, surplus committed as a new vault position,
receipt recorded in `ReceiptAccumulatorSHA256`.

## Implementation Notes

**Live debt cap** — At registration time, `adapterData` is built with
`clawloanRepayLive(pool, botId, liveDebt)` where `liveDebt` is a fresh
on-chain read, not the 2-second-lagged wagmi poll. This ensures the adapter's
`debtCap` always matches the actual debt at registration.

**Simulate-before-send** — All state-changing calls run `publicClient.simulateContract`
first. If simulation fails, the decoded custom error (from `abis.ts`) appears
in the log panel before any wallet prompt, making debug cycles fast.

**Time warping** — The trigger and auto-simulate paths warp Anvil using
`evm_setNextBlockTimestamp` to `max(latestBlock.timestamp + 1, deadline + 1)`,
which is safe for repeated calls even after the chain tip has advanced past
the deadline. All deadline calculations use `publicClient.getBlock("latest").timestamp`,
not `Date.now()`, so they remain correct after any prior time warp.

**Keeper Mode** — Open `/?role=keeper` in a second browser tab. The keeper
tab reads envelope data from localStorage (written by the agent tab after
`register`) and can trigger from a completely separate wallet.

## Environment

Override deployed contract addresses via `VITE_ADDR_*` env vars. See
`.env.example` in the repo root for the full list.
