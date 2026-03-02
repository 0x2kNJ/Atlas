/**
 * Strategy Graph — Liquidation Shield + Instant Refinance
 *
 * An agent pre-commits a 2-stage refinance pipeline triggered by health:
 *   Stage 1: ETH/USD < $1,500 (LTV stress) → emergency exit — sell WETH for USDC
 *            (represents "repay the over-leveraged tranche to avoid liquidation")
 *   Stage 2: ETH/USD > $1,200 → re-open at safer LTV — buy WETH back with portion of USDC
 *            (re-enters at lower allocation, safer debt ratio)
 *
 * The key: Stage 2 opens INSTANTLY after Stage 1's liquidation-shield exit.
 * No gap where capital sits idle waiting for the agent to come back online.
 * The refinance is pre-committed cryptographically, not dependent on speed.
 *
 * In a production system, Stage 1 would call a repay adapter; Stage 2 would
 * open a new vault position with lower LTV parameters. Here we demonstrate
 * the chaining and instant re-entry logic using PriceSwapAdapter + ReverseSwapAdapter.
 */
import { useState, useCallback, useRef } from "react";
import { useAccount, useWalletClient, usePublicClient } from "wagmi";
import { parseUnits, formatEther } from "viem";

import { ADDRESSES, ANVIL_CHAIN_ID } from "../../contracts/addresses";
import { ERC20_ABI, VAULT_ABI, REGISTRY_ABI, MOCK_PRICE_ORACLE_ABI } from "../../contracts/abis";
import { LogPanel }  from "../../components/LogPanel";
import type { LogEntry } from "../../components/LogPanel";
import { StepCard }  from "../../components/StepCard";
import { TxButton }  from "../../components/TxButton";
import { computePositionHash, computeOutputSalt } from "../../utils/graphUtils";
import { SigningProgress } from "../../components/SigningProgress";
import type { SigStep }   from "../../components/SigningProgress";
import { FlowDiagram }    from "../../components/FlowDiagram";

const SIG_STEPS: SigStep[] = [
  { stage: "Stage 1 — Emergency exit (WETH → USDC)",    label: "Spending permission",    icon: "🔑" },
  { stage: "Stage 1 — Emergency exit (WETH → USDC)",    label: "Execution intent",       icon: "📋" },
  { stage: "Stage 1 — Emergency exit (WETH → USDC)",    label: "Registration authority", icon: "🗝️" },
  { stage: "Stage 2 — Refinance at 50% LTV (USDC → WETH)", label: "Spending permission",    icon: "🔑" },
  { stage: "Stage 2 — Refinance at 50% LTV (USDC → WETH)", label: "Execution intent",       icon: "📋" },
  { stage: "Stage 2 — Refinance at 50% LTV (USDC → WETH)", label: "Registration authority", icon: "🗝️" },
  { stage: "On-chain", label: "Register Stage 1 liquidation shield", icon: "⛓️" },
];

import {
  buildCapability, buildManageCapability, buildIntent, buildEnvelope,
  signCapability, signIntent, signManageCapability,
  randomSalt, hashEnvelope, ZERO_ADDRESS, ComparisonOp, LogicOp,
} from "@atlas-protocol/sdk";
import type { Position, Conditions } from "@atlas-protocol/sdk";

const STRESS_PRICE    = 1500;
const STRESS_TRIGGER  = 1500n * 10n ** 8n;  // Stage 1: ETH < $1,500
const REFI_TRIGGER    = 1200n * 10n ** 8n;  // Stage 2: ETH > $1,200
const WETH_FULL       = parseUnits("1", 18);
// At $1,500: 1e18 * 1500e8 / 1e20 = 1500e6 USDC
const USDC_EXIT       = parseUnits("1500", 6);
// Stage 2 re-enters with 50% of USDC (safer LTV): 750e6 USDC → WETH
const USDC_REFI       = parseUnits("750", 6);
// At $1,500: 750e6 * 1e20 / 1500e8 = 0.5e18 WETH (re-enters at 50% allocation)
const WETH_REFI       = parseUnits("0.5", 18);
const CAP_DUR         = 90n * 86400n;
const ENV_DUR         = 30n * 86400n;

interface GraphState {
  s1Env?: unknown; s1Cap?: unknown; s1Intent?: unknown; s1MgCap?: unknown;
  s1CapSig?: `0x${string}`; s1IntentSig?: `0x${string}`; s1MgSig?: `0x${string}`;
  s1EnvHash?: `0x${string}`; s1Pos?: unknown; s1Cond?: unknown;
  s2Env?: unknown; s2Cap?: unknown; s2Intent?: unknown; s2MgCap?: unknown;
  s2CapSig?: `0x${string}`; s2IntentSig?: `0x${string}`; s2MgSig?: `0x${string}`;
  s2EnvHash?: `0x${string}`; s2Pos?: unknown; s2Cond?: unknown;
}

export function RefinancePipelineScenario() {
  const { address }            = useAccount();
  const { data: walletClient } = useWalletClient();
  const publicClient           = usePublicClient();
  const logId                  = useRef(0);

  const [logs,      setLogs]      = useState<LogEntry[]>([]);
  const [step,      setStep]      = useState(0);
  const [busy,      setBusy]      = useState(false);
  const [sigStep,   setSigStep]   = useState(-1);
  const [exitDone,  setExitDone]  = useState(false);
  const [refiDone,  setRefiDone]  = useState(false);
  const [finalWeth, setFinalWeth] = useState(0n);
  const state = useRef<GraphState>({});

  const log = useCallback((level: LogEntry["level"], msg: string) =>
    setLogs(p => [...p, { id: ++logId.current, ts: Date.now(), level, message: msg }]), []);

  const withBusy = useCallback(async (fn: () => Promise<void>) => {
    setBusy(true);
    try { await fn(); }
    catch (e: unknown) { log("error", (e instanceof Error ? e.message : String(e)).slice(0, 300)); }
    finally { setBusy(false); }
  }, [log]);

  const mint = () => withBusy(async () => {
    if (!walletClient || !address) return;
    log("info", "Minting 2 WETH…");
    await publicClient!.waitForTransactionReceipt({ hash: await walletClient.writeContract({
      address: ADDRESSES.MockWETH as `0x${string}`, abi: ERC20_ABI,
      functionName: "mint", args: [address, parseUnits("2", 18)],
    })});
    log("success", "2 WETH minted");
    setStep(1);
  });

  const setupAndSign = () => withBusy(async () => {
    if (!walletClient || !address) return;

    log("info", `Fixing oracle at $${STRESS_PRICE} for deterministic Stage 1 output…`);
    await publicClient!.waitForTransactionReceipt({ hash: await walletClient.writeContract({
      address: ADDRESSES.MockPriceOracle as `0x${string}`, abi: MOCK_PRICE_ORACLE_ABI,
      functionName: "setPrice", args: [BigInt(STRESS_PRICE) * 10n ** 8n],
    })});

    await publicClient!.waitForTransactionReceipt({ hash: await walletClient.writeContract({
      address: ADDRESSES.MockWETH as `0x${string}`, abi: ERC20_ABI,
      functionName: "approve", args: [ADDRESSES.SingletonVault as `0x${string}`, WETH_FULL],
    })});
    const s1Salt = randomSalt();
    await publicClient!.waitForTransactionReceipt({ hash: await walletClient.writeContract({
      address: ADDRESSES.SingletonVault as `0x${string}`, abi: VAULT_ABI,
      functionName: "deposit", args: [ADDRESSES.MockWETH as `0x${string}`, WETH_FULL, s1Salt],
    })});
    const s1Pos: Position = { owner: address, asset: ADDRESSES.MockWETH as `0x${string}`, amount: WETH_FULL, salt: s1Salt };
    const s1PosHash = computePositionHash(address, ADDRESSES.MockWETH as `0x${string}`, WETH_FULL, s1Salt);
    log("success", `1 WETH deposited. Position: ${s1PosHash.slice(0, 10)}…`);

    const { timestamp: now } = await publicClient!.getBlock({ blockTag: "latest" });

    // ── Stage 1: Emergency exit ──────────────────────────────────────────────
    log("info", "Signing Stage 1 (emergency exit: full WETH→USDC at stress price)…");
    setSigStep(0);
    const s1Cap = buildCapability({ issuer: address, grantee: address, expiry: now + CAP_DUR, nonce: randomSalt(),
      constraints: { maxSpendPerPeriod: WETH_FULL * 2n, periodDuration: 86400n, minReturnBps: 0n,
        allowedAdapters: [ADDRESSES.PriceSwapAdapter as `0x${string}`],
        allowedTokensIn: [ADDRESSES.MockWETH as `0x${string}`], allowedTokensOut: [ADDRESSES.MockUSDC as `0x${string}`] } });
    const s1CapSig = await signCapability(walletClient, s1Cap, ADDRESSES.CapabilityKernel as `0x${string}`, ANVIL_CHAIN_ID);

    setSigStep(1);
    const s1IntentNonce = randomSalt();
    const s1Intent = buildIntent({ position: s1Pos, capability: s1Cap,
      adapter: ADDRESSES.PriceSwapAdapter as `0x${string}`, adapterData: "0x",
      minReturn: parseUnits("1200", 6), deadline: now + CAP_DUR, nonce: s1IntentNonce,
      outputToken: ADDRESSES.MockUSDC as `0x${string}`, returnTo: ZERO_ADDRESS,
      submitter: ADDRESSES.EnvelopeRegistry as `0x${string}`, solverFeeBps: 0 });
    const s1IntentSig = await signIntent(walletClient, s1Intent, ADDRESSES.CapabilityKernel as `0x${string}`, ANVIL_CHAIN_ID);

    setSigStep(2);
    const s1MgCap = buildManageCapability({ issuer: address, grantee: address, expiry: now + ENV_DUR, nonce: randomSalt() });
    const s1MgSig = await signManageCapability(walletClient, s1MgCap, ADDRESSES.EnvelopeRegistry as `0x${string}`, ANVIL_CHAIN_ID);

    const s1Cond: Conditions = { priceOracle: ADDRESSES.MockPriceOracle as `0x${string}`, baseToken: ZERO_ADDRESS,
      quoteToken: ZERO_ADDRESS, triggerPrice: STRESS_TRIGGER, op: ComparisonOp.LESS_THAN,
      secondaryOracle: ZERO_ADDRESS, secondaryTriggerPrice: 0n, secondaryOp: ComparisonOp.LESS_THAN, logicOp: LogicOp.AND };
    const s1Env = buildEnvelope({ position: s1Pos, conditions: s1Cond, intent: s1Intent, manageCapability: s1MgCap,
      expiry: now + ENV_DUR, keeperRewardBps: 10, minKeeperRewardWei: 0n });
    const s1EnvHash = hashEnvelope(s1Env) as `0x${string}`;

    // Pre-compute Stage 2 input (USDC output from Stage 1)
    const s2InputSalt = computeOutputSalt(s1IntentNonce, s1PosHash);
    // Stage 2 only uses HALF the USDC (re-opens at safer 50% LTV)
    const s2Pos: Position = { owner: address, asset: ADDRESSES.MockUSDC as `0x${string}`, amount: USDC_REFI, salt: s2InputSalt };

    log("info", "Signing Stage 2 (refinance: USDC→WETH at 50% allocation — safer LTV)…");
    setSigStep(3);
    const s2Cap = buildCapability({ issuer: address, grantee: address, expiry: now + CAP_DUR, nonce: randomSalt(),
      constraints: { maxSpendPerPeriod: USDC_EXIT, periodDuration: 86400n, minReturnBps: 0n,
        allowedAdapters: [ADDRESSES.MockReverseSwapAdapter as `0x${string}`],
        allowedTokensIn: [ADDRESSES.MockUSDC as `0x${string}`], allowedTokensOut: [ADDRESSES.MockWETH as `0x${string}`] } });
    const s2CapSig = await signCapability(walletClient, s2Cap, ADDRESSES.CapabilityKernel as `0x${string}`, ANVIL_CHAIN_ID);

    setSigStep(4);
    const s2Intent = buildIntent({ position: s2Pos, capability: s2Cap,
      adapter: ADDRESSES.MockReverseSwapAdapter as `0x${string}`, adapterData: "0x",
      minReturn: parseUnits("0.3", 18), deadline: now + CAP_DUR, nonce: randomSalt(),
      outputToken: ADDRESSES.MockWETH as `0x${string}`, returnTo: ZERO_ADDRESS,
      submitter: ADDRESSES.EnvelopeRegistry as `0x${string}`, solverFeeBps: 0 });
    const s2IntentSig = await signIntent(walletClient, s2Intent, ADDRESSES.CapabilityKernel as `0x${string}`, ANVIL_CHAIN_ID);

    setSigStep(5);
    const s2MgCap = buildManageCapability({ issuer: address, grantee: address, expiry: now + ENV_DUR, nonce: randomSalt() });
    const s2MgSig = await signManageCapability(walletClient, s2MgCap, ADDRESSES.EnvelopeRegistry as `0x${string}`, ANVIL_CHAIN_ID);

    const s2Cond: Conditions = { priceOracle: ADDRESSES.MockPriceOracle as `0x${string}`, baseToken: ZERO_ADDRESS,
      quoteToken: ZERO_ADDRESS, triggerPrice: REFI_TRIGGER, op: ComparisonOp.GREATER_THAN,
      secondaryOracle: ZERO_ADDRESS, secondaryTriggerPrice: 0n, secondaryOp: ComparisonOp.LESS_THAN, logicOp: LogicOp.AND };
    const s2Env = buildEnvelope({ position: s2Pos, conditions: s2Cond, intent: s2Intent, manageCapability: s2MgCap,
      expiry: now + ENV_DUR, keeperRewardBps: 10, minKeeperRewardWei: 0n });
    const s2EnvHash = hashEnvelope(s2Env) as `0x${string}`;

    Object.assign(state.current, { s1Env, s1Cap, s1Intent, s1MgCap, s1CapSig, s1IntentSig, s1MgSig, s1EnvHash,
      s1Pos, s1Cond,
      s2Env, s2Cap, s2Intent, s2MgCap, s2CapSig, s2IntentSig, s2MgSig, s2EnvHash,
      s2Pos, s2Cond });

    log("success", "6 EIP-712 sigs — shield + refinance pre-committed.");
    setSigStep(6);
    await publicClient!.waitForTransactionReceipt({ hash: await walletClient.writeContract({
      address: ADDRESSES.EnvelopeRegistry as `0x${string}`, abi: REGISTRY_ABI,
      functionName: "register",
      args: [s1Env as never, s1MgCap as never, s1MgSig, s1Pos as never],
    })});
    setSigStep(7);
    log("success", `Liquidation shield live: ${s1EnvHash.slice(0, 10)}… — agent can go offline`);
    setStep(2);
  });

  const triggerExit = () => withBusy(async () => {
    if (!walletClient || !address) return;
    const s = state.current;
    log("info", `Oracle at $${STRESS_PRICE} → stress condition met (ETH < $1,500)…`);
    await publicClient!.waitForTransactionReceipt({ hash: await walletClient.writeContract({
      address: ADDRESSES.EnvelopeRegistry as `0x${string}`, abi: REGISTRY_ABI,
      functionName: "trigger",
      args: [s.s1EnvHash!, s.s1Cond as never, s.s1Pos as never, s.s1Intent as never, s.s1Cap as never, s.s1CapSig!, s.s1IntentSig!],
    })});
    setExitDone(true);
    log("success", "Emergency exit — 1 WETH → 1,500 USDC. Liquidation avoided.");
    log("info", "Registering refinance envelope (pre-signed, no agent)…");
    await publicClient!.waitForTransactionReceipt({ hash: await walletClient.writeContract({
      address: ADDRESSES.EnvelopeRegistry as `0x${string}`, abi: REGISTRY_ABI,
      functionName: "register",
      args: [s.s2Env as never, s.s2MgCap as never, s.s2MgSig!, s.s2Pos as never],
    })});
    log("success", `Refinance envelope registered: ${s.s2EnvHash!.slice(0, 10)}…`);
    setStep(3);
  });

  const triggerRefi = () => withBusy(async () => {
    if (!walletClient || !address) return;
    const s = state.current;
    log("info", `Oracle at $${STRESS_PRICE} → refi condition met (ETH > $1,200)…`);
    await publicClient!.waitForTransactionReceipt({ hash: await walletClient.writeContract({
      address: ADDRESSES.EnvelopeRegistry as `0x${string}`, abi: REGISTRY_ABI,
      functionName: "trigger",
      args: [s.s2EnvHash!, s.s2Cond as never, s.s2Pos as never, s.s2Intent as never, s.s2Cap as never, s.s2CapSig!, s.s2IntentSig!],
    })});
    const weth = await publicClient!.readContract({
      address: ADDRESSES.MockWETH as `0x${string}`, abi: ERC20_ABI,
      functionName: "balanceOf", args: [address],
    }) as bigint;
    setFinalWeth(weth);
    setRefiDone(true);
    log("success", `Refinanced — re-entered with 0.5 WETH (50% safer LTV). Wallet WETH: ${formatEther(weth)}`);
    log("success", "750 USDC kept as buffer — excess collateral vs. original over-leveraged position.");
    setStep(4);
  });

  return (
    <div className="space-y-6">
      <div className="bg-zinc-900/60 border border-zinc-800 rounded-2xl p-5">
        <div className="flex items-center gap-3 mb-2">
          <span className="text-2xl">🛡️</span>
          <div>
            <h2 className="text-lg font-bold text-zinc-100">Liquidation Shield + Instant Refinance</h2>
            <p className="text-sm text-zinc-400">Pre-commit emergency exit AND safer re-entry. Zero gap between liquidation protection and refinancing.</p>
          </div>
        </div>
        <FlowDiagram nodes={[
          { condition: "ETH < $1,500", action: "Emergency exit: 1 WETH → USDC",    result: "Liquidation avoided",    tone: "danger" },
          { condition: "ETH > $1,200", action: "Refinance: 750 USDC → 0.5 WETH",  result: "50% LTV, 750 USDC buffer", tone: "safe"   },
        ]} />
        <div className="grid grid-cols-2 gap-4 mt-4">
          <div className={`rounded-xl p-3 border text-xs ${exitDone ? "bg-red-950/30 border-red-700 text-red-300" : "bg-zinc-800/40 border-zinc-700 text-zinc-400"}`}>
            <div className="font-semibold mb-1">Stage 1 — Emergency Exit</div>
            <div>ETH &lt; $1,500 → full WETH → USDC</div>
            <div className="mt-1 text-zinc-500">Avoids liquidation cascade</div>
            {exitDone && <div className="text-emerald-400 mt-1">✓ executed</div>}
          </div>
          <div className={`rounded-xl p-3 border text-xs ${refiDone ? "bg-blue-950/30 border-blue-700 text-blue-300" : "bg-zinc-800/40 border-zinc-700 text-zinc-400"}`}>
            <div className="font-semibold mb-1">Stage 2 — Refinance</div>
            <div>ETH &gt; $1,200 → 50% USDC → WETH</div>
            <div className="mt-1 text-zinc-500">Re-enters at safer 50% LTV</div>
            {refiDone && <div className="text-emerald-400 mt-1">✓ executed</div>}
          </div>
        </div>
        {finalWeth > 0n && (
          <div className="mt-3 p-3 bg-emerald-950/40 border border-emerald-700 rounded-xl text-sm text-emerald-300">
            Refinance complete — <strong>{formatEther(finalWeth)} WETH</strong> + 750 USDC buffer.
            LTV reduced from 100% → 50%.
          </div>
        )}
      </div>

      <div className="grid gap-4">
        {[
          { title: "Fund wallet",                                  desc: "Mint 2 WETH as collateral for the over-leveraged position.",                                                                                                                                                                                   action: mint,        label: "Mint WETH"          },
          { title: "Deposit + set up shield & refinance",         desc: "Deposits 1 WETH at 100% exposure. Pre-signs both the emergency exit (Stage 1) and safer re-entry (Stage 2) in one session. Liquidation protection is live before any price stress occurs.",                                                   action: setupAndSign, label: "Set Up Shield"       },
          { title: "Stage 1 fires — emergency exit",             desc: "ETH drops below $1,500 (stress threshold). Keeper triggers Stage 1: 1 WETH → 1,500 USDC. Liquidation avoided. Stage 2 (refinance) is instantly registered from pre-committed data.",                                                         action: triggerExit,  label: "Fire Emergency Exit" },
          { title: "Stage 2 fires — refinance at 50% LTV",      desc: "ETH holds above $1,200. Keeper triggers Stage 2: 750 USDC → 0.5 WETH. Re-enters at half the original exposure. 750 USDC kept as safety buffer. LTV: 100% → 50%.",                                                                             action: triggerRefi,  label: "Execute Refinance"   },
        ].map((s, i) => (
          <StepCard key={i} index={i} title={s.title} description={s.desc}
            status={step > i ? "done" : step === i ? (busy ? "loading" : "ready") : "pending"}>
            {step === i && (
              <div className="space-y-3">
                {i === 1 && sigStep >= 0 && (
                  <SigningProgress steps={SIG_STEPS} currentIndex={sigStep} />
                )}
                {s.action && <TxButton onClick={s.action} loading={busy}>{s.label}</TxButton>}
              </div>
            )}
          </StepCard>
        ))}
      </div>

      <LogPanel entries={logs} />
    </div>
  );
}
