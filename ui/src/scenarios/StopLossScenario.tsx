/**
 * Phase 4 — Stop-Loss / Protective Put
 *
 * An AI agent holds 1 WETH and pre-commits: "if ETH drops below $1,800, sell for USDC."
 * The agent goes offline. The oracle is pushed to $1,700. A keeper triggers.
 * WETH → USDC automatically — no agent key needed at execution time.
 *
 * Proves: price-oracle-conditional execution, cross-token swap via Atlas,
 * and the options thesis (this IS a put option with no counterparty).
 */
import { useState, useCallback, useRef } from "react";
import { useAccount, useWalletClient, usePublicClient } from "wagmi";
import { parseUnits, toHex, formatUnits } from "viem";

import { ADDRESSES, ANVIL_CHAIN_ID } from "../contracts/addresses";
import {
  ERC20_ABI,
  VAULT_ABI,
  REGISTRY_ABI,
  MOCK_PRICE_ORACLE_ABI,
} from "../contracts/abis";
import { LogPanel } from "../components/LogPanel";
import type { LogEntry } from "../components/LogPanel";
import { StepCard } from "../components/StepCard";
import { TxButton }  from "../components/TxButton";

import {
  buildCapability,
  buildManageCapability,
  buildIntent,
  buildEnvelope,
  signCapability,
  signIntent,
  signManageCapability,
  randomSalt,
  hashEnvelope,
  ZERO_ADDRESS,
  ComparisonOp,
  LogicOp,
} from "@atlas-protocol/sdk";
import type { Position, Conditions } from "@atlas-protocol/sdk";

const WETH_DEPOSIT    = parseUnits("1", 18);
const STRIKE_PRICE    = 1800n * 10n ** 8n;
const CRASH_PRICE_NUM = 1700;
const MIN_USDC_RETURN = parseUnits("1600", 6);
const CAP_DURATION    = 90n * 86400n;
const ENV_DURATION    = 30n * 86400n;

const priceFmt = (p: number) => `$${p.toLocaleString()}`;

interface SLState {
  position?:   Position;
  envelope?:   unknown;
  envelopeHash?: `0x${string}`;
  conditions?: Conditions;
  spendCap?:   unknown;
  intent?:     unknown;
  capSig?:     `0x${string}`;
  intentSig?:  `0x${string}`;
}

export function StopLossScenario() {
  const { address }         = useAccount();
  const { data: walletClient } = useWalletClient();
  const publicClient           = usePublicClient();
  const logId = useRef(0);

  const [logs,     setLogs]    = useState<LogEntry[]>([]);
  const [step,     setStep]    = useState(0);
  const [busy,     setBusy]    = useState(false);
  const [oraclePrice, setOraclePrice] = useState(2500);
  const [triggered, setTriggered] = useState(false);
  const [usdcOut,  setUsdcOut] = useState(0n);
  const state = useRef<SLState>({});

  const log = useCallback((level: LogEntry["level"], msg: string) => {
    setLogs(p => [...p, { id: ++logId.current, ts: Date.now(), level, message: msg }]);
  }, []);

  const withBusy = useCallback(async (fn: () => Promise<void>) => {
    setBusy(true);
    try { await fn(); }
    catch (e: unknown) { log("error", (e instanceof Error ? e.message : String(e)).slice(0, 300)); }
    finally { setBusy(false); }
  }, [log]);

  // ── Step 0: Mint 2 WETH ──────────────────────────────────────────────────
  const mintWETH = () => withBusy(async () => {
    if (!walletClient || !address) return;
    log("info", "Minting 2 WETH…");
    await publicClient!.waitForTransactionReceipt({ hash: await walletClient.writeContract({
      address: ADDRESSES.MockWETH as `0x${string}`,
      abi: ERC20_ABI,
      functionName: "mint",
      args: [address, parseUnits("2", 18)],
    })});
    log("success", "2 WETH minted");
    setStep(1);
  });

  // ── Step 1: Deposit 1 WETH ────────────────────────────────────────────────
  const depositWETH = () => withBusy(async () => {
    if (!walletClient || !address) return;
    await publicClient!.waitForTransactionReceipt({ hash: await walletClient.writeContract({
      address: ADDRESSES.MockWETH as `0x${string}`,
      abi: ERC20_ABI,
      functionName: "approve",
      args: [ADDRESSES.SingletonVault as `0x${string}`, WETH_DEPOSIT],
    })});
    const salt = toHex(randomSalt());
    await publicClient!.waitForTransactionReceipt({ hash: await walletClient.writeContract({
      address: ADDRESSES.SingletonVault as `0x${string}`,
      abi: VAULT_ABI,
      functionName: "deposit",
      args: [ADDRESSES.MockWETH as `0x${string}`, WETH_DEPOSIT, salt as `0x${string}`],
    })});
    state.current.position = { owner: address, asset: ADDRESSES.MockWETH as `0x${string}`, amount: WETH_DEPOSIT, salt };
    log("success", `1 WETH deposited into vault`);
    setStep(2);
  });

  // ── Step 2: Register stop-loss envelope ──────────────────────────────────
  const registerStopLoss = () => withBusy(async () => {
    if (!walletClient || !address || !state.current.position) return;
    const pos = state.current.position;
    const { timestamp: now } = await publicClient!.getBlock({ blockTag: "latest" });

    log("info", "Signing capability (1/3)…");
    const capNonce = randomSalt();
    const spendCap = buildCapability({
      issuer:  address,
      grantee: address,
      expiry:  now + CAP_DURATION,
      nonce:   toHex(capNonce),
      constraints: {
        maxSpendPerPeriod: WETH_DEPOSIT * 2n,
        periodDuration:    86400n,
        minReturnBps:      0n,
        allowedAdapters:   [ADDRESSES.PriceSwapAdapter as `0x${string}`],
        allowedTokensIn:   [ADDRESSES.MockWETH as `0x${string}`],
        allowedTokensOut:  [ADDRESSES.MockUSDC as `0x${string}`],
      },
    });
    const capSig = await signCapability(walletClient, spendCap, ADDRESSES.CapabilityKernel as `0x${string}`, ANVIL_CHAIN_ID);

    log("info", "Signing intent (2/3)…");
    const intent = buildIntent({
      position:    pos,
      capability:  spendCap,
      adapter:     ADDRESSES.PriceSwapAdapter as `0x${string}`,
      adapterData: "0x",
      minReturn:   MIN_USDC_RETURN,
      deadline:    now + CAP_DURATION,
      nonce:       toHex(randomSalt()),
      outputToken: ADDRESSES.MockUSDC as `0x${string}`,
      returnTo:    ZERO_ADDRESS,
      submitter:   ADDRESSES.EnvelopeRegistry as `0x${string}`,
      solverFeeBps: 0,
    });
    const intentSig = await signIntent(walletClient, intent, ADDRESSES.CapabilityKernel as `0x${string}`, ANVIL_CHAIN_ID);

    log("info", "Signing manage capability (3/3)…");
    const manageCap = buildManageCapability({
      issuer:  address,
      grantee: address,
      expiry:  now + ENV_DURATION,
      nonce:   toHex(randomSalt()),
    });
    const manageCapSig = await signManageCapability(walletClient, manageCap, ADDRESSES.EnvelopeRegistry as `0x${string}`, ANVIL_CHAIN_ID);

    const conditions: Conditions = {
      priceOracle:           ADDRESSES.MockPriceOracle as `0x${string}`,
      baseToken:             ZERO_ADDRESS,
      quoteToken:            ZERO_ADDRESS,
      triggerPrice:          STRIKE_PRICE,
      op:                    ComparisonOp.LESS_THAN,
      secondaryOracle:       ZERO_ADDRESS,
      secondaryTriggerPrice: 0n,
      secondaryOp:           ComparisonOp.LESS_THAN,
      logicOp:               LogicOp.AND,
    };
    const envelope = buildEnvelope({
      position:          pos,
      conditions,
      intent,
      manageCapability:  manageCap,
      expiry:            now + ENV_DURATION,
      keeperRewardBps:   10,
      minKeeperRewardWei: 0n,
    });
    state.current = { ...state.current, envelope, conditions, spendCap, intent, capSig: capSig as `0x${string}`, intentSig: intentSig as `0x${string}` };

    log("info", "Registering stop-loss envelope…");
    await publicClient!.simulateContract({
      address: ADDRESSES.EnvelopeRegistry as `0x${string}`,
      abi: REGISTRY_ABI,
      functionName: "register",
      args: [envelope as never, manageCap as never, manageCapSig, pos as never],
      account: address,
    });
    await publicClient!.waitForTransactionReceipt({ hash: await walletClient.writeContract({
      address: ADDRESSES.EnvelopeRegistry as `0x${string}`,
      abi: REGISTRY_ABI,
      functionName: "register",
      args: [envelope as never, manageCap as never, manageCapSig, pos as never],
    })});
    state.current.envelopeHash = hashEnvelope(envelope) as `0x${string}`;
    log("success", `Envelope armed ✓ — stop-loss at $1,800`);
    setStep(3);
  });

  // ── Step 3: Simulate market crash ─────────────────────────────────────────
  const simulateCrash = () => withBusy(async () => {
    if (!walletClient) return;
    log("info", `Pushing oracle to $${CRASH_PRICE_NUM}…`);
    await publicClient!.waitForTransactionReceipt({ hash: await walletClient.writeContract({
      address: ADDRESSES.MockPriceOracle as `0x${string}`,
      abi: MOCK_PRICE_ORACLE_ABI,
      functionName: "setPrice",
      args: [BigInt(CRASH_PRICE_NUM) * 10n ** 8n],
    })});
    setOraclePrice(CRASH_PRICE_NUM);
    log("success", `Oracle: $${CRASH_PRICE_NUM} | condition TRUE (${CRASH_PRICE_NUM} < 1800)`);
    setStep(4);
  });

  // ── Step 4: Keeper trigger ────────────────────────────────────────────────
  const keeperTrigger = () => withBusy(async () => {
    if (!walletClient) return;
    const { envelopeHash, conditions, position, spendCap, intent, capSig, intentSig } = state.current;
    if (!envelopeHash || !conditions || !position || !spendCap || !intent || !capSig || !intentSig) return;
    log("info", "Keeper triggers stop-loss envelope…");
    await publicClient!.waitForTransactionReceipt({ hash: await walletClient.writeContract({
      address: ADDRESSES.EnvelopeRegistry as `0x${string}`,
      abi: REGISTRY_ABI,
      functionName: "trigger",
      args: [envelopeHash, conditions as never, position as never, intent as never, spendCap as never, capSig, intentSig],
    })});
    const out = (parseUnits("1", 18) * BigInt(CRASH_PRICE_NUM * 1e8)) / BigInt(1e20);
    setUsdcOut(out);
    log("success", `Executed ✓ | 1 WETH → ${formatUnits(out, 6)} USDC | agent was offline`);
    setTriggered(true);
    setStep(5);
  });

  const statusFor = (s: number): "done" | "active" | "pending" =>
    step > s ? "done" : step === s ? "active" : "pending";

  return (
    <div className="flex gap-6 w-full">
      <div className="flex-1 min-w-0 flex flex-col gap-4">
        {/* Hero */}
        <div className="rounded-xl border border-orange-700 bg-orange-950/20 p-5">
          <div className="flex items-center gap-3 mb-2">
            <span className="text-2xl">🛡️</span>
            <div>
              <h2 className="text-lg font-bold text-orange-300">Stop-Loss / Protective Put</h2>
              <p className="text-xs text-slate-400">Price-triggered WETH→USDC swap • No counterparty • No liquidity pool</p>
            </div>
          </div>
          <p className="text-sm text-slate-300 mt-2">
            Agent pre-commits: <code className="text-orange-300 text-xs">"if ETH/USD &lt; $1,800 → swap 1 WETH for USDC"</code>.
            Keeper triggers permissionlessly when oracle crosses the strike. No agent key needed at execution.
          </p>
          <div className={`mt-3 flex items-center gap-3 px-4 py-2.5 rounded-lg border ${oraclePrice < 1800 ? "border-red-700 bg-red-950/30" : "border-emerald-800 bg-emerald-950/20"}`}>
            <span className="text-xl">{oraclePrice < 1800 ? "📉" : "📈"}</span>
            <div>
              <span className="text-sm font-bold text-slate-200">Oracle: {priceFmt(oraclePrice)}</span>
              <span className="text-xs text-slate-500 ml-2">| Strike: $1,800</span>
              {oraclePrice < 1800 && <span className="ml-2 text-xs text-red-400">⚡ TRIGGER CONDITION MET</span>}
            </div>
          </div>
        </div>

        <StepCard step={0} title="Mint WETH" subtitle="Get 2 mockWETH representing the agent's position" status={statusFor(0)}>
          <TxButton label="Mint 2 WETH" onClick={mintWETH} disabled={step !== 0 || busy} />
        </StepCard>

        <StepCard step={1} title="Deposit 1 WETH into Atlas vault" subtitle="Position committed as hash. Cannot be withdrawn while encumbered." status={statusFor(1)}>
          <TxButton label="Deposit 1 WETH" onClick={depositWETH} disabled={step !== 1 || busy} />
        </StepCard>

        <StepCard step={2} title="Register stop-loss envelope" subtitle="Signs 3 EIP-712 messages: vault.spend capability, swap intent, manage capability" status={statusFor(2)}>
          <ul className="text-xs text-slate-500 space-y-1 mb-3 ml-2">
            <li>Capability: WETH→USDC only, via PriceSwapAdapter</li>
            <li>Intent: swap 1 WETH, min $1,600 USDC floor</li>
            <li>Condition: ETH/USD &lt; $1,800 (MockPriceOracle, LESS_THAN)</li>
          </ul>
          <TxButton label="Sign + Register Stop-Loss" onClick={registerStopLoss} disabled={step !== 2 || busy} />
        </StepCard>

        {step >= 3 && !triggered && (
          <StepCard step={3} title="Simulate market crash" subtitle="Push oracle to $1,700 — the stop-loss condition becomes TRUE" status={statusFor(3)}>
            <TxButton label="Crash ETH to $1,700" onClick={simulateCrash} disabled={step !== 3 || busy} />
          </StepCard>
        )}

        {step >= 4 && !triggered && (
          <StepCard step={4} title="Keeper triggers stop-loss" subtitle="Any address can trigger. No agent key needed. WETH → USDC via PriceSwapAdapter." status={statusFor(4)}>
            <TxButton label="Trigger as Keeper" onClick={keeperTrigger} disabled={step !== 4 || busy} />
          </StepCard>
        )}

        {triggered && (
          <div className="rounded-xl border border-orange-500 bg-orange-950/30 p-5 text-center">
            <div className="text-3xl mb-2">✅</div>
            <div className="text-orange-300 font-bold text-lg">Stop-Loss Executed</div>
            <div className="text-sm text-slate-300 mt-1">1 WETH → <span className="text-orange-300 font-mono font-bold">{formatUnits(usdcOut, 6)} USDC</span></div>
            <div className="text-xs text-slate-500 mt-2">ETH dropped 32%. Agent was offline the entire time. No agent key needed for execution.</div>
          </div>
        )}

        <LogPanel entries={logs} />
      </div>

      {/* Right panel */}
      <div className="w-80 flex-shrink-0 flex flex-col gap-4">
        <div className="rounded-xl border border-orange-700 bg-orange-950/20 p-4 text-xs">
          <h3 className="text-sm font-bold text-orange-300 mb-3">The Options Thesis</h3>
          <p className="text-slate-400 mb-3">This IS a put option, expressed as an Atlas envelope:</p>
          <div className="space-y-1.5">
            {[
              ["Strike price",   "$1,800  (triggerPrice)"],
              ["Expiry",         "30 days (envelope.expiry)"],
              ["Exercise",       "Automatic via keeper"],
              ["Settlement",     "minReturn floor + vault commit"],
              ["Counterparty",   "None — self-collateralised"],
              ["Liquidity pool", "Not required"],
            ].map(([k, v]) => (
              <div key={k} className="flex justify-between gap-2">
                <span className="text-slate-500">{k}</span>
                <span className="text-slate-300 font-mono text-right">{v}</span>
              </div>
            ))}
          </div>
        </div>
        <div className="rounded-xl border border-slate-700 bg-slate-900/50 p-4 text-xs text-slate-400">
          <div className="font-semibold text-slate-300 mb-2">Security properties</div>
          <ul className="space-y-1">
            <li>✓ minReturn = $1,600 USDC — kernel enforced hard floor</li>
            <li>✓ Oracle reads at trigger time — keeper cannot manipulate</li>
            <li>✓ No agent key needed for execution</li>
            <li>✓ Position encumbered — agent cannot double-spend</li>
            <li>✓ Beneficiary baked into EIP-712 intent hash</li>
          </ul>
        </div>
      </div>
    </div>
  );
}
