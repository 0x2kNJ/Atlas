/**
 * Deployed contract addresses for the local Anvil demo.
 *
 * These are deterministic CREATE addresses from the DeployClawloanDemo.s.sol
 * script using Anvil's default account 0 as the deployer.
 *
 * Re-run `forge script script/DeployClawloanDemo.s.sol --rpc-url http://127.0.0.1:8545 --broadcast ...`
 * if you restart Anvil — addresses reset on each fresh node unless you use --state.
 */
function envAddr(name: string, fallback: string): string {
  const value = import.meta.env[name];
  return typeof value === "string" && value.length > 0 ? value : fallback;
}

export const ADDRESSES = {
  // ── Core Atlas (nonces 0–10) ─────────────────────────────────────────────
  MockUSDC:              envAddr("VITE_ADDR_MOCK_USDC",               "0x5FbDB2315678afecb367f032d93F642f64180aa3"),
  MockClawloanPool:      envAddr("VITE_ADDR_MOCK_CLAWLOAN_POOL",      "0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512"),
  MockTimestampOracle:   envAddr("VITE_ADDR_MOCK_TIMESTAMP_ORACLE",   "0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9"),
  SingletonVault:        envAddr("VITE_ADDR_SINGLETON_VAULT",         "0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9"),
  CapabilityKernel:      envAddr("VITE_ADDR_CAPABILITY_KERNEL",       "0x5FC8d32690cc91D4c39d9d3abcBD16989F875707"),
  EnvelopeRegistry:      envAddr("VITE_ADDR_ENVELOPE_REGISTRY",       "0x0165878A594ca255338adfa4d48449f69242Eb8F"),
  ReceiptAccumulator:    envAddr("VITE_ADDR_RECEIPT_ACCUMULATOR",     "0xa513E6E4b8f2a923D98304ec87F64353C4D5C853"),
  CreditVerifier:        envAddr("VITE_ADDR_CREDIT_VERIFIER",         "0x8A791620dd6260079BF849Dc5567aDC3F2FdC318"),
  ClawloanRepayAdapter:  envAddr("VITE_ADDR_CLAWLOAN_REPAY_ADAPTER",  "0x610178dA211FEF7D417bC0e6FeD39F05609AD788"),
  // ── Phase 2 — Dead Man's Switch (nonce 11) ───────────────────────────────
  DirectTransferAdapter: envAddr("VITE_ADDR_DIRECT_TRANSFER_ADAPTER", "0xB7f8BC63BbcaD18155201308C8f3540b07f84F5e"),
  // ── Phase 3 — Sub-agent Orchestration (nonce 12) ─────────────────────────
  MockSubAgentHub:       envAddr("VITE_ADDR_MOCK_SUB_AGENT_HUB",      "0xA51c1fc2f0D1a1b8494Ed1FE312d7C3a78Ed91C0"),
  // ── Phase 4 — Stop-Loss / Protective Put (nonces 13–15) ──────────────────
  MockWETH:              envAddr("VITE_ADDR_MOCK_WETH",               "0x0DCd1Bf9A1b36cE34237eEaFef220932846BCD82"),
  MockPriceOracle:       envAddr("VITE_ADDR_MOCK_PRICE_ORACLE",       "0x9A676e781A523b5d0C0e43731313A708CB607508"),
  PriceSwapAdapter:      envAddr("VITE_ADDR_PRICE_SWAP_ADAPTER",      "0x0B306BF915C4d645ff596e518fAf3F9669b97016"),
  // ── Phase 5 — Protocol Liquidation Engine (nonces 16–18) ─────────────────
  MockHealthOracle:      envAddr("VITE_ADDR_MOCK_HEALTH_ORACLE",      "0x959922bE3CAee4b8Cd9a407cc3ac1C251C2007B1"),
  MockAavePool:          envAddr("VITE_ADDR_MOCK_AAVE_POOL",          "0x9A9f2CCfdE556A7E9Ff0848998Aa4a0CFD8863AE"),
  LiquidationAdapter:    envAddr("VITE_ADDR_LIQUIDATION_ADAPTER",     "0x68B1D87F95878fE05B998F19b66F4baba5De1aed"),
  // ── Phase 6 — ZK Credit Passport (nonce 19) ──────────────────────────────
  MockCreditGatedLender: envAddr("VITE_ADDR_MOCK_CREDIT_GATED_LENDER","0x3Aa5ebB10DC797CAC828524e59A333d0A371443c"),
  // ── Phase 7 — M-of-N Consensus (nonce 20) ────────────────────────────────
  MockConsensusHub:         envAddr("VITE_ADDR_MOCK_CONSENSUS_HUB",         "0xc6e7DF5E7b4f2A278906862b61205850344D4e7d"),
  // ── Capital Provider Pool (nonces 21–23) ─────────────────────────────────
  MockCapitalPool:          envAddr("VITE_ADDR_MOCK_CAPITAL_POOL",          "0x59b670e9fA9D0A427751Af201D676719a970857b"),
  UtilisationOracle:        envAddr("VITE_ADDR_UTILISATION_ORACLE",         "0x4ed7c70F96B99c776995fB64377f0d4aB3B0e1C1"),
  PoolPauseAdapter:         envAddr("VITE_ADDR_POOL_PAUSE_ADAPTER",         "0x322813Fd9A801c5507c9de605d63CEA4f2CE6c44"),
  // ── Phase 8 — Chained Strategy Graph (nonce 24) ───────────────────────────
  MockReverseSwapAdapter:   envAddr("VITE_ADDR_MOCK_REVERSE_SWAP_ADAPTER",  "0xa85233C63b9Ee964Add6F2cffe00Fd84eb32338f"),
} as const;

// Anvil hardcoded accounts 1–4 (used for M-of-N consensus and "publish the key" demos)
export const ANVIL_ACCOUNTS = [
  { address: "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266", privateKey: "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80" },
  { address: "0x70997970C51812dc3A010C7d01b50e0d17dc79C8", privateKey: "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d" },
  { address: "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC", privateKey: "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a" },
  { address: "0x90F79bf6EB2c4f870365E785982E1f101E93b906", privateKey: "0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6" },
  { address: "0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65", privateKey: "0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926b" },
] as const;

export const ANVIL_CHAIN_ID = 31337;
