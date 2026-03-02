/**
 * Phase 6 — Protocol Liquidation Engine
 *
 * Narrative: Aave (or any lending protocol) uses Atlas envelopes as a shared
 * liquidation keeper infrastructure instead of building their own keeper network.
 * A user's health factor degrades. Any Atlas keeper triggers liquidation automatically.
 * No Aave-specific keeper code. No per-protocol infrastructure maintenance.
 *
 * What this proves:
 *  - Atlas as DeFi infrastructure, not just a user-facing tool
 *  - "Moat 6" from STRATEGY.md: shared keeper substrate for all of DeFi
 *  - The pitch to Aave/MakerDAO: "register liquidations as Atlas envelopes"
 *  - Health-factor-oracle-conditional execution (different oracle type)
 */
import { useState, useCallback, useRef } from "react";
import { useAccount, useWalletClient, usePublicClient } from "wagmi";
import { encodeAbiParameters, parseUnits, toHex, formatUnits } from "viem";

import { ADDRESSES, ANVIL_CHAIN_ID } from "../contracts/addresses";
import {
  ERC20_ABI,
  VAULT_ABI,
  REGISTRY_ABI,
  MOCK_HEALTH_ORACLE_ABI,
  MOCK_AAVE_POOL_ABI,
} from "../contracts/abis";
import { StepCard } from "../components/StepCard";
import { TxButton }  from "../components/TxButton";
import { LogPanel }  from "../components/LogPanel";
import type { LogEntry } from "../components/LogPanel";

import {
  buildCapability,
  buildManageCapability,
  buildIntent,
  buildEnvelope,
  signCapability,
  signManageCapability,
  signIntent,
  randomSalt,
  hashEnvelope,
  ZERO_ADDRESS,
  ComparisonOp,
  LogicOp,
} from "@atlas-protocol/sdk";
import type { Position, Capability, Intent, Conditions } from "@atlas-protocol/sdk";

// ─── Constants ────────────────────────────────────────────────────────────────
const COLLATERAL_AMT  = parseUnits("2000", 6);  // $2,000 USDC collateral
const DEBT_AMT        = parseUnits("1500", 6);  // $1,500 USDC debt
const LIQ_THRESHOLD   = 105_000_000n;           // 1.05 in 8-dec Chainlink format
const INITIAL_HF      = 200_000_000n;           // 2.00 (healthy)
const CRASH_HF        = 99_000_000n;            // 0.99 (liquidatable)
const EXPECTED_RETURN = COLLATERAL_AMT - DEBT_AMT - (DEBT_AMT * 5n / 100n); // ~$425 USDC

interface LiqState {
  position?:    Position;
  envelopeHash?: `0x${string}`;
  spendCap?:    Capability;
  intent?:      Intent;
  capSig?:      `0x${string}`;
  intentSig?:   `0x${string}`;
  conditions?:  Conditions;
}

export function LiquidationScenario() {
  const { address }            = useAccount();
  const { data: walletClient } = useWalletClient();
  const publicClient           = usePublicClient();
  const logId = useRef(0);

  const [logs,      setLogs]     = useState<LogEntry[]>([]);
  const [step,      setStep]     = useState(0);
  const [busy,      setBusy]     = useState(false);
  const [triggered, setTriggered] = useState(false);
  const [hf,        setHf]       = useState(INITIAL_HF);
  const stateRef = useRef<LiqState>({});

  const log = useCallback((level: LogEntry["level"], message: string) => {
    setLogs(prev => [...prev, { id: ++logId.current, ts: Date.now(), level, message }]);
  }, []);

  const withBusy = useCallback(async (fn: () => Promise<void>) => {
    setBusy(true);
    try { await fn(); }
    catch (e: unknown) { log("error", (e instanceof Error ? e.message : String(e)).slice(0, 300)); }
    finally { setBusy(false); }
  }, [log]);

  const hfFmt   = (h: bigint) => (Number(h) / 1e8).toFixed(2);
  const hfColor = (h: bigint) => h >= LIQ_THRESHOLD ? "text-emerald-400" : "text-red-400";
  const statusFor = (s: number): "done" | "active" | "pending" =>
    step > s ? "done" : step === s ? "active" : "pending";

  // ── Step 0: Open Aave position ─────────────────────────────────────────────
  const openPosition = () => withBusy(async () => {
    if (!walletClient || !address || !publicClient) return;
    log("info", "Minting $2,000 USDC collateral…");
    await publicClient.waitForTransactionReceipt({ hash: await walletClient.writeContract({
      address: ADDRESSES.MockUSDC as `0x${string}`, abi: ERC20_ABI, functionName: "mint",
      args: [address, COLLATERAL_AMT],
    })});
    await publicClient.waitForTransactionReceipt({ hash: await walletClient.writeContract({
      address: ADDRESSES.MockUSDC as `0x${string}`, abi: ERC20_ABI, functionName: "approve",
      args: [ADDRESSES.SingletonVault as `0x${string}`, COLLATERAL_AMT],
    })});
    const salt = toHex(randomSalt());
    await publicClient.waitForTransactionReceipt({ hash: await walletClient.writeContract({
      address: ADDRESSES.SingletonVault as `0x${string}`, abi: VAULT_ABI, functionName: "deposit",
      args: [ADDRESSES.MockUSDC as `0x${string}`, COLLATERAL_AMT, salt as `0x${string}`],
    })});
    stateRef.current.position = { owner: address, asset: ADDRESSES.MockUSDC as `0x${string}`, amount: COLLATERAL_AMT, salt };
    log("info", "Recording $1,500 debt in MockAavePool…");
    await publicClient.waitForTransactionReceipt({ hash: await walletClient.writeContract({
      address: ADDRESSES.MockAavePool as `0x${string}`, abi: MOCK_AAVE_POOL_ABI,
      functionName: "openPosition", args: [address, COLLATERAL_AMT, DEBT_AMT],
    })});
    log("success", `Aave position opened | collateral: $2,000 | debt: $1,500 | HF: ${hfFmt(INITIAL_HF)}`);
    setStep(1);
  });

  // ── Step 1: Register liquidation envelope ─────────────────────────────────
  const registerLiquidation = () => withBusy(async () => {
    if (!walletClient || !address || !publicClient) return;
    const { position } = stateRef.current;
    if (!position) { log("error", "Open position first"); return; }
    const { timestamp: now } = await publicClient.getBlock({ blockTag: "latest" });

    const spendCap = buildCapability({
      issuer:  address,
      grantee: address,
      expiry:  now + 90n * 86400n,
      nonce:   toHex(randomSalt()),
      constraints: {
        maxSpendPerPeriod: COLLATERAL_AMT * 2n,
        periodDuration:    86400n,
        minReturnBps:      0n,
        allowedAdapters:   [ADDRESSES.LiquidationAdapter as `0x${string}`],
        allowedTokensIn:   [],
        allowedTokensOut:  [],
      },
    });
    const capSig = await signCapability(walletClient, spendCap, ADDRESSES.CapabilityKernel as `0x${string}`, ANVIL_CHAIN_ID);
    stateRef.current.spendCap = spendCap;
    stateRef.current.capSig   = capSig as `0x${string}`;
    log("info", "Capability signed");

    const adapterData = encodeAbiParameters(
      [{ type: "address" }, { type: "address" }, { type: "uint256" }],
      [ADDRESSES.MockAavePool as `0x${string}`, address, DEBT_AMT]
    );
    const intent = buildIntent({
      position,
      capability:  spendCap,
      adapter:     ADDRESSES.LiquidationAdapter as `0x${string}`,
      adapterData,
      minReturn:   EXPECTED_RETURN - parseUnits("10", 6),
      deadline:    now + 90n * 86400n,
      nonce:       toHex(randomSalt()),
      outputToken: ADDRESSES.MockUSDC as `0x${string}`,
      returnTo:    ZERO_ADDRESS,
      submitter:   ZERO_ADDRESS,
      solverFeeBps: 0,
    });
    const intentSig = await signIntent(walletClient, intent, ADDRESSES.CapabilityKernel as `0x${string}`, ANVIL_CHAIN_ID);
    stateRef.current.intent    = intent;
    stateRef.current.intentSig = intentSig as `0x${string}`;
    log("info", "Liquidation intent signed");

    const manageCap = buildManageCapability({
      issuer:  address,
      grantee: ADDRESSES.EnvelopeRegistry as `0x${string}`,
      expiry:  now + 30n * 86400n,
      nonce:   toHex(randomSalt()),
    });
    const manageCapSig = await signManageCapability(walletClient, manageCap, ADDRESSES.EnvelopeRegistry as `0x${string}`, ANVIL_CHAIN_ID);

    const conditions: Conditions = {
      priceOracle:           ADDRESSES.MockHealthOracle as `0x${string}`,
      baseToken:             ZERO_ADDRESS,
      quoteToken:            ZERO_ADDRESS,
      triggerPrice:          LIQ_THRESHOLD,
      op:                    ComparisonOp.LESS_THAN,
      secondaryOracle:       ZERO_ADDRESS,
      secondaryTriggerPrice: 0n,
      secondaryOp:           ComparisonOp.GREATER_THAN,
      logicOp:               LogicOp.AND,
    };
    stateRef.current.conditions = conditions;

    const envelope = buildEnvelope({
      position,
      conditions,
      intent,
      manageCapability: manageCap,
      expiry:           now + 30n * 86400n,
      keeperRewardBps:  10,
      minKeeperRewardWei: 0n,
    });
    stateRef.current.envelopeHash = hashEnvelope(envelope) as `0x${string}`;

    await publicClient.waitForTransactionReceipt({ hash: await walletClient.writeContract({
      address: ADDRESSES.EnvelopeRegistry as `0x${string}`,
      abi: REGISTRY_ABI,
      functionName: "register",
      args: [envelope as never, manageCap as never, manageCapSig, position as never],
    })});
    log("success", "Liquidation envelope registered | condition: HF < 1.05");
    setStep(2);
  });

  // ── Step 2: Push health factor below threshold ─────────────────────────────
  const simulateStress = () => withBusy(async () => {
    if (!walletClient || !publicClient) return;
    log("info", "Market stress: pushing health factor to 0.99…");
    await publicClient.waitForTransactionReceipt({ hash: await walletClient.writeContract({
      address: ADDRESSES.MockHealthOracle as `0x${string}`,
      abi: MOCK_HEALTH_ORACLE_ABI,
      functionName: "setHealthFactor",
      args: [CRASH_HF],
    })});
    setHf(CRASH_HF);
    log("success", `Health factor → ${hfFmt(CRASH_HF)} | liquidation condition TRUE`);
    setStep(3);
  });

  // ── Step 3: Keeper triggers liquidation ───────────────────────────────────
  const keeperLiquidate = () => withBusy(async () => {
    if (!walletClient || !publicClient) return;
    const { envelopeHash, conditions, position, intent, spendCap, capSig, intentSig } = stateRef.current;
    if (!envelopeHash || !conditions || !position || !intent || !spendCap || !capSig || !intentSig) {
      log("error", "Register envelope first"); return;
    }
    log("info", "Atlas keeper executes liquidation…");
    const rcpt = await publicClient.waitForTransactionReceipt({ hash: await walletClient.writeContract({
      address: ADDRESSES.EnvelopeRegistry as `0x${string}`,
      abi: REGISTRY_ABI,
      functionName: "trigger",
      args: [envelopeHash, conditions as never, position as never, intent as never, spendCap as never, capSig, intentSig],
    })});
    if (rcpt.status !== "success") { log("error", "Liquidation tx reverted"); return; }
    log("success", `LIQUIDATED | debt repaid: $1,500 | returned to user: ~${formatUnits(EXPECTED_RETURN, 6)} USDC`);
    log("info", "No Aave-specific keeper was running. The Atlas keeper network handled this.");
    setTriggered(true);
    setStep(4);
  });

  return (
    <div className="flex gap-6 w-full">
      <div className="flex-1 min-w-0 flex flex-col gap-4">

        <div className="rounded-xl border border-blue-700 bg-blue-950/20 p-5">
          <div className="flex items-center gap-3 mb-2">
            <span className="text-2xl">🏦</span>
            <div>
              <h2 className="text-lg font-bold text-blue-300">Protocol Liquidation Engine</h2>
              <p className="text-xs text-slate-400">Atlas as DeFi infrastructure — not just a user-facing stop-loss</p>
            </div>
          </div>
          <p className="text-sm text-slate-300 mt-2">
            Aave registers its liquidation conditions as Atlas envelopes. The Atlas keeper network fires liquidations.
            Aave doesn't need its own keeper infrastructure.
          </p>
          <div className={`mt-3 flex items-center gap-3 px-4 py-2.5 rounded-lg ${hf < LIQ_THRESHOLD ? "bg-red-950/50 border border-red-700" : "bg-emerald-950/30 border border-emerald-800"}`}>
            <span className="text-xl">{hf < LIQ_THRESHOLD ? "🚨" : "✅"}</span>
            <div>
              <span className="text-sm font-bold text-slate-200">Health Factor: </span>
              <span className={`font-mono font-bold text-sm ${hfColor(hf)}`}>{hfFmt(hf)}</span>
              <span className="text-xs text-slate-500 ml-2">| threshold: 1.05</span>
              {hf < LIQ_THRESHOLD && <span className="ml-2 text-xs text-red-400">⚡ LIQUIDATABLE</span>}
            </div>
          </div>
        </div>

        <StepCard step={0} title="Open Aave position" subtitle="Deposit $2,000 USDC collateral into Atlas vault, record $1,500 debt in MockAavePool. HF = 2.0" status={statusFor(0)}>
          <TxButton label="Open $2,000 / $1,500 Position" onClick={openPosition} disabled={step !== 0 || busy} />
        </StepCard>

        <StepCard step={1} title="Register liquidation envelope" subtitle="Condition: healthFactor < 1.05 | LiquidationAdapter pulls collateral, repays debt, returns ~$425 to vault" status={statusFor(1)}>
          <TxButton label="Register Liquidation Envelope" onClick={registerLiquidation} disabled={step !== 1 || busy} />
        </StepCard>

        {step >= 2 && !triggered && (
          <StepCard step={2} title="Market stress event" subtitle="Push health factor to 0.99 — below the 1.05 liquidation threshold" status={statusFor(2)}>
            <TxButton label="📉 Push HF to 0.99" onClick={simulateStress} disabled={step !== 2 || busy} variant="danger" />
          </StepCard>
        )}

        {step >= 3 && !triggered && (
          <StepCard step={3} title="Atlas keeper liquidates" subtitle="Any keeper triggers. LiquidationAdapter fires. Debt settled. Remaining collateral returns to vault." status={statusFor(3)}>
            <TxButton label="🔫 Keeper: Liquidate" onClick={keeperLiquidate} disabled={step !== 3 || busy} variant="keeper" />
          </StepCard>
        )}

        {triggered && (
          <div className="rounded-xl border border-blue-500 bg-blue-950/30 p-5 text-center">
            <div className="text-3xl mb-2">✅</div>
            <div className="text-blue-300 font-bold text-lg">Liquidation Executed</div>
            <div className="text-slate-300 text-sm mt-1">
              $1,500 debt repaid • ~{formatUnits(EXPECTED_RETURN, 6)} USDC returned to user vault
            </div>
            <div className="text-slate-400 text-xs mt-2">No Aave keeper. No Aave contract logic. Just Atlas envelopes.</div>
          </div>
        )}

        <LogPanel entries={logs} />
      </div>

      {/* Right panel */}
      <div className="w-80 flex-shrink-0 flex flex-col gap-4">
        <div className="rounded-xl border border-blue-700 bg-blue-950/20 p-4 text-xs">
          <h3 className="text-sm font-bold text-blue-300 mb-3">The B2B Pitch</h3>
          <p className="text-slate-400 mb-3">
            Every DeFi protocol with conditional execution currently maintains its own keeper infrastructure:
          </p>
          {[
            { name: "Aave",     need: "Liquidations at HF thresholds" },
            { name: "Uniswap",  need: "Limit order execution" },
            { name: "MakerDAO", need: "CDP automation, stability fees" },
            { name: "Compound", need: "Collateral top-ups, liquidations" },
          ].map(p => (
            <div key={p.name} className="flex items-start gap-2 mb-2 p-2 bg-slate-900/50 rounded">
              <span className="text-blue-400 font-bold">{p.name}</span>
              <span className="text-slate-500">{p.need}</span>
            </div>
          ))}
          <div className="mt-3 p-2 bg-blue-950/30 border border-blue-800 rounded">
            <strong className="text-blue-300">Atlas pitch:</strong>
            <p className="text-slate-400 mt-1">
              "Register your liquidation conditions as Atlas envelopes. Our keeper network handles execution.
              You get our reliability; we get your trigger volume."
            </p>
          </div>
        </div>

        <div className="rounded-xl border border-slate-700 bg-slate-900/50 p-4 text-xs text-slate-400">
          <div className="font-semibold text-slate-300 mb-2">Keeper flywheel</div>
          <div className="space-y-1 text-slate-500">
            <div>More protocols → more trigger volume</div>
            <div>→ More keeper revenue</div>
            <div>→ More keeper operators</div>
            <div>→ Better reliability SLA</div>
            <div>→ More protocols integrate</div>
          </div>
          <p className="mt-2">
            This network effect is impossible for any single protocol to bootstrap alone.
          </p>
        </div>
      </div>
    </div>
  );
}
