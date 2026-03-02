# Atlas × Clawloan — Demo UI

React + Wagmi frontend that demonstrates the full Atlas Protocol lifecycle against a local Anvil node.

## Prerequisites

1. Anvil running at `http://127.0.0.1:8545`
2. Contracts deployed via `DeployClawloanDemo.s.sol` (see root `README.md`)
3. SDK built: `cd ../sdk && npm run build`

## Run

```bash
npm install
npm run dev
```

Open `http://localhost:5173`. Connect MetaMask to `localhost:8545` / chain ID `31337`.

## Demo steps

| Step | Action | What happens on-chain |
|---|---|---|
| 0 | Get Test USDC | Calls `MockERC20.mint` for 15 USDC |
| 1 | Borrow from Clawloan | `MockClawloanPool.borrow(botId=1, 10 USDC)` |
| 2 | Deposit Earnings | `ERC20.approve` + `SingletonVault.deposit` with random salt |
| 3 | Register Envelope | Signs vault.spend cap + intent + manage cap (3× EIP-712), calls `EnvelopeRegistry.register` |
| 4 | Trigger | Warps time past loan deadline, calls `EnvelopeRegistry.trigger` |
| 5 | Submit Credit Proof | Calls `CreditVerifier.submitProof` with mock ZK proof |

After trigger: debt repaid to pool, surplus committed as new vault position, receipt recorded.

## Key implementation notes

### Live debt cap (App.tsx `registerEnvelope`)

At registration time, the adapter data is built with `clawloanRepayLive(pool, botId, liveDebtNow)` where `liveDebtNow` is read directly from the chain (not from the 2-second-lagged wagmi polled state). This ensures the `debtCap` always matches the actual debt — avoiding `ClawloanRepayAdapter: live debt exceeds cap`.

### Double-borrow prevention (App.tsx `borrow`)

Before submitting a borrow transaction, the code does a live `readContract` for `getDebt(botId)`. If debt > 0, it throws with a clear message before touching the wallet. This prevents the 2-second polling window from allowing a second borrow before the first is repaid.

### Error handling

All transactions use `simulateContract` before submitting. If simulation fails, the revert reason (including decoded custom errors from `abis.ts`) is shown in the log panel before any wallet prompt.

## Environment

Contract addresses are read from `src/contracts/addresses.ts`. Each address can be overridden via `VITE_ADDR_*` environment variables (see `.env.example`).

```bash
# .env.example
VITE_ADDR_MOCK_USDC=0x...
VITE_ADDR_SINGLETON_VAULT=0x...
# etc.
```
