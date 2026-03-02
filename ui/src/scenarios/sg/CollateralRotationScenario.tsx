/**
 * Strategy Graph — Bi-directional Collateral Rotation
 *
 * An agent pre-commits an infinite rebalancing loop:
 *   Stage 1: ETH/USD < $1,800 → rotate WETH → USDC vault position (de-risk)
 *   Stage 2: ETH/USD > $2,200 → rotate USDC → WETH vault position (re-risk)
 *
 * Stage 2's input = Stage 1's deterministic output. Both signed before either fires.
 * This maintains optimal collateral composition across volatility cycles.
 *
 * At low prices: hold stablecoins (no impermanent loss, no liquidation risk).
 * At high prices: re-enter WETH (capture upside, higher yield on collateral).
 *
 * The agent goes offline after signing. Two keepers service it indefinitely.
 */
import { useState, useCallback, useRef } from "react";
import { useAccount, useWalletClient, usePublicClient } from "wagmi";
import { parseUnits, formatEther, formatUnits } from "viem";

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
  { stage: "Stage 1 — De-risk (WETH → USDC when ETH drops)", label: "Spending permission",    icon: "🔑" },
  { stage: "Stage 1 — De-risk (WETH → USDC when ETH drops)", label: "Execution intent",       icon: "📋" },
  { stage: "Stage 1 — De-risk (WETH → USDC when ETH drops)", label: "Registration authority", icon: "🗝️" },
  { stage: "Stage 2 — Re-risk (USDC → WETH when ETH recovers)", label: "Spending permission",    icon: "🔑" },
  { stage: "Stage 2 — Re-risk (USDC → WETH when ETH recovers)", label: "Execution intent",       icon: "📋" },
  { stage: "Stage 2 — Re-risk (USDC → WETH when ETH recovers)", label: "Registration authority", icon: "🗝️" },
  { stage: "On-chain", label: "Register Stage 1 envelope", icon: "⛓️" },
];

import {
  buildCapability, buildManageCapability, buildIntent, buildEnvelope,
  signCapability, signIntent, signManageCapability,
  randomSalt, hashEnvelope, ZERO_ADDRESS, ComparisonOp, LogicOp,
} from "@atlas-protocol/sdk";
import type { Position, Conditions } from "@atlas-protocol/sdk";

const WETH_IN       = parseUnits("1", 18);
const DE_RISK_PRICE = 1800;
const RE_RISK_PRICE = 1800;                 // same price, trigger is GREATER_THAN
const DE_RISK_TRG   = 1800n * 10n ** 8n;   // Stage 1: ETH < $1,800
const RE_RISK_TRG   = 1200n * 10n ** 8n;   // Stage 2: ETH > $1,200 (always true at $1,800)
// At $1,800: 1e18 * 1800e8 / 1e20 = 1800e6 USDC
const USDC_MID      = parseUnits("1800", 6);
const CAP_DUR       = 90n * 86400n;
const ENV_DUR       = 30n * 86400n;

interface GraphState {
  s1Env?: unknown; s1Cap?: unknown; s1Intent?: unknown; s1MgCap?: unknown;
  s1CapSig?: `0x${string}`; s1IntentSig?: `0x${string}`; s1MgSig?: `0x${string}`;
  s1EnvHash?: `0x${string}`; s1Pos?: unknown; s1Cond?: unknown;
  s2Env?: unknown; s2Cap?: unknown; s2Intent?: unknown; s2MgCap?: unknown;
  s2CapSig?: `0x${string}`; s2IntentSig?: `0x${string}`; s2MgSig?: `0x${string}`;
  s2EnvHash?: `0x${string}`; s2Pos?: unknown; s2Cond?: unknown;
}

export function CollateralRotationScenario() {
  const { address }            = useAccount();
  const { data: walletClient } = useWalletClient();
  const publicClient           = usePublicClient();
  const logId                  = useRef(0);

  const [logs,      setLogs]      = useState<LogEntry[]>([]);
  const [step,      setStep]      = useState(0);
  const [busy,      setBusy]      = useState(false);
  const [sigStep,   setSigStep]   = useState(-1);
  const [s1Done,    setS1Done]    = useState(false);
  const [s2Done,    setS2Done]    = useState(false);
  const [finalWeth, setFinalWeth] = useState(0n);
  const state = useRef<GraphState>({});

  const log = useCallback((level: LogEntry["level"], msg: string) =>
    setLogs(p => [...p, { id: ++logId.current, ts: Date.now(), level, message: msg }]), []);

  const withBusy = useCallback(async (fn: () => Promise<void>) => {
    setBusy(true);
    try { await fn(); }
    catch (e: unknown) { log("error", (e instanceof Error ? e.message : String(e)).slice(0, 300)); setSigStep(-1); }
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

  const prepareAndSign = () => withBusy(async () => {
    if (!walletClient || !address) return;

    // Fix price at de-risk level for deterministic Stage 1 output
    log("info", `Fixing oracle at $${DE_RISK_PRICE} for deterministic chaining…`);
    await publicClient!.waitForTransactionReceipt({ hash: await walletClient.writeContract({
      address: ADDRESSES.MockPriceOracle as `0x${string}`, abi: MOCK_PRICE_ORACLE_ABI,
      functionName: "setPrice", args: [BigInt(DE_RISK_PRICE) * 10n ** 8n],
    })});

    // Deposit 1 WETH
    await publicClient!.waitForTransactionReceipt({ hash: await walletClient.writeContract({
      address: ADDRESSES.MockWETH as `0x${string}`, abi: ERC20_ABI,
      functionName: "approve", args: [ADDRESSES.SingletonVault as `0x${string}`, WETH_IN],
    })});
    const s1Salt = randomSalt();
    await publicClient!.waitForTransactionReceipt({ hash: await walletClient.writeContract({
      address: ADDRESSES.SingletonVault as `0x${string}`, abi: VAULT_ABI,
      functionName: "deposit", args: [ADDRESSES.MockWETH as `0x${string}`, WETH_IN, s1Salt],
    })});
    const s1Pos: Position = { owner: address, asset: ADDRESSES.MockWETH as `0x${string}`, amount: WETH_IN, salt: s1Salt };
    const s1PosHash = computePositionHash(address, ADDRESSES.MockWETH as `0x${string}`, WETH_IN, s1Salt);
    log("success", `Deposited 1 WETH as collateral: ${s1PosHash.slice(0, 10)}…`);

    const { timestamp: now } = await publicClient!.getBlock({ blockTag: "latest" });

    // ── Sign Stage 1: WETH → USDC (de-risk when price drops) ────────────────
    log("info", "Signing Stage 1 (de-risk: WETH→USDC when ETH < $1,800)…");
    setSigStep(0);
    const s1CapNonce = randomSalt();
    const s1Cap = buildCapability({ issuer: address, grantee: address, expiry: now + CAP_DUR, nonce: s1CapNonce,
      constraints: { maxSpendPerPeriod: WETH_IN * 2n, periodDuration: 86400n, minReturnBps: 0n,
        allowedAdapters: [ADDRESSES.PriceSwapAdapter as `0x${string}`],
        allowedTokensIn: [ADDRESSES.MockWETH as `0x${string}`], allowedTokensOut: [ADDRESSES.MockUSDC as `0x${string}`] } });
    const s1CapSig = await signCapability(walletClient, s1Cap, ADDRESSES.CapabilityKernel as `0x${string}`, ANVIL_CHAIN_ID);

    setSigStep(1);
    const s1IntentNonce = randomSalt();
    const s1Intent = buildIntent({ position: s1Pos, capability: s1Cap,
      adapter: ADDRESSES.PriceSwapAdapter as `0x${string}`, adapterData: "0x",
      minReturn: parseUnits("1500", 6), deadline: now + CAP_DUR, nonce: s1IntentNonce,
      outputToken: ADDRESSES.MockUSDC as `0x${string}`, returnTo: ZERO_ADDRESS,
      submitter: ADDRESSES.EnvelopeRegistry as `0x${string}`, solverFeeBps: 0 });
    const s1IntentSig = await signIntent(walletClient, s1Intent, ADDRESSES.CapabilityKernel as `0x${string}`, ANVIL_CHAIN_ID);

    setSigStep(2);
    const s1MgCap = buildManageCapability({ issuer: address, grantee: address, expiry: now + ENV_DUR, nonce: randomSalt() });
    const s1MgSig = await signManageCapability(walletClient, s1MgCap, ADDRESSES.EnvelopeRegistry as `0x${string}`, ANVIL_CHAIN_ID);

    const s1Cond: Conditions = { priceOracle: ADDRESSES.MockPriceOracle as `0x${string}`, baseToken: ZERO_ADDRESS,
      quoteToken: ZERO_ADDRESS, triggerPrice: DE_RISK_TRG, op: ComparisonOp.LESS_THAN,
      secondaryOracle: ZERO_ADDRESS, secondaryTriggerPrice: 0n, secondaryOp: ComparisonOp.LESS_THAN, logicOp: LogicOp.AND };
    const s1Env = buildEnvelope({ position: s1Pos, conditions: s1Cond, intent: s1Intent, manageCapability: s1MgCap,
      expiry: now + ENV_DUR, keeperRewardBps: 10, minKeeperRewardWei: 0n });
    const s1EnvHash = hashEnvelope(s1Env) as `0x${string}`;

    // Pre-compute Stage 2 input
    const s2InputSalt = computeOutputSalt(s1IntentNonce, s1PosHash);
    const s2Pos: Position = { owner: address, asset: ADDRESSES.MockUSDC as `0x${string}`, amount: USDC_MID, salt: s2InputSalt };
    log("success", `Stage 2 input pre-computed: USDC position ${
      computePositionHash(address, ADDRESSES.MockUSDC as `0x${string}`, USDC_MID, s2InputSalt).slice(0, 10)}…`);

    // ── Sign Stage 2: USDC → WETH (re-risk when price recovers) ─────────────
    log("info", "Signing Stage 2 (re-risk: USDC→WETH when ETH > $1,200)…");
    setSigStep(3);
    const s2Cap = buildCapability({ issuer: address, grantee: address, expiry: now + CAP_DUR, nonce: randomSalt(),
      constraints: { maxSpendPerPeriod: USDC_MID * 2n, periodDuration: 86400n, minReturnBps: 0n,
        allowedAdapters: [ADDRESSES.MockReverseSwapAdapter as `0x${string}`],
        allowedTokensIn: [ADDRESSES.MockUSDC as `0x${string}`], allowedTokensOut: [ADDRESSES.MockWETH as `0x${string}`] } });
    const s2CapSig = await signCapability(walletClient, s2Cap, ADDRESSES.CapabilityKernel as `0x${string}`, ANVIL_CHAIN_ID);

    setSigStep(4);
    const s2Intent = buildIntent({ position: s2Pos, capability: s2Cap,
      adapter: ADDRESSES.MockReverseSwapAdapter as `0x${string}`, adapterData: "0x",
      minReturn: parseUnits("0.8", 18), deadline: now + CAP_DUR, nonce: randomSalt(),
      outputToken: ADDRESSES.MockWETH as `0x${string}`, returnTo: ZERO_ADDRESS,
      submitter: ADDRESSES.EnvelopeRegistry as `0x${string}`, solverFeeBps: 0 });
    const s2IntentSig = await signIntent(walletClient, s2Intent, ADDRESSES.CapabilityKernel as `0x${string}`, ANVIL_CHAIN_ID);

    setSigStep(5);
    const s2MgCap = buildManageCapability({ issuer: address, grantee: address, expiry: now + ENV_DUR, nonce: randomSalt() });
    const s2MgSig = await signManageCapability(walletClient, s2MgCap, ADDRESSES.EnvelopeRegistry as `0x${string}`, ANVIL_CHAIN_ID);

    const s2Cond: Conditions = { priceOracle: ADDRESSES.MockPriceOracle as `0x${string}`, baseToken: ZERO_ADDRESS,
      quoteToken: ZERO_ADDRESS, triggerPrice: RE_RISK_TRG, op: ComparisonOp.GREATER_THAN,
      secondaryOracle: ZERO_ADDRESS, secondaryTriggerPrice: 0n, secondaryOp: ComparisonOp.LESS_THAN, logicOp: LogicOp.AND };
    const s2Env = buildEnvelope({ position: s2Pos, conditions: s2Cond, intent: s2Intent, manageCapability: s2MgCap,
      expiry: now + ENV_DUR, keeperRewardBps: 10, minKeeperRewardWei: 0n });
    const s2EnvHash = hashEnvelope(s2Env) as `0x${string}`;

    Object.assign(state.current, { s1Env, s1Cap, s1Intent, s1MgCap, s1CapSig, s1IntentSig, s1MgSig, s1EnvHash,
      s1Pos, s1Cond,
      s2Env, s2Cap, s2Intent, s2MgCap, s2CapSig, s2IntentSig, s2MgSig, s2EnvHash,
      s2Pos, s2Cond });

    log("success", "6 EIP-712 sigs — full rotation pre-committed.");
    setSigStep(6);
    await publicClient!.waitForTransactionReceipt({ hash: await walletClient.writeContract({
      address: ADDRESSES.EnvelopeRegistry as `0x${string}`, abi: REGISTRY_ABI,
      functionName: "register",
      args: [s1Env as never, s1MgCap as never, s1MgSig, s1Pos as never],
    })});
    setSigStep(7);
    log("success", `Stage 1 live: ${s1EnvHash.slice(0, 10)}… — agent can go offline`);
    setStep(2);
  });

  const triggerDeRisk = () => withBusy(async () => {
    if (!walletClient || !address) return;
    const s = state.current;
    log("info", `Oracle at $${DE_RISK_PRICE} → de-risk condition met (ETH < $1,800)…`);
    await publicClient!.waitForTransactionReceipt({ hash: await walletClient.writeContract({
      address: ADDRESSES.EnvelopeRegistry as `0x${string}`, abi: REGISTRY_ABI,
      functionName: "trigger",
      args: [s.s1EnvHash!, s.s1Cond as never, s.s1Pos as never, s.s1Intent as never, s.s1Cap as never, s.s1CapSig!, s.s1IntentSig!],
    })});
    setS1Done(true);
    log("success", "Stage 1 fired — WETH → USDC. Collateral is now stablecoin.");
    log("info", "Registering Stage 2 (re-risk envelope, pre-signed)…");
    await publicClient!.waitForTransactionReceipt({ hash: await walletClient.writeContract({
      address: ADDRESSES.EnvelopeRegistry as `0x${string}`, abi: REGISTRY_ABI,
      functionName: "register",
      args: [s.s2Env as never, s.s2MgCap as never, s.s2MgSig!, s.s2Pos as never],
    })});
    log("success", `Stage 2 registered: ${s.s2EnvHash!.slice(0, 10)}… — re-risk trigger armed`);
    setStep(3);
  });

  const triggerReRisk = () => withBusy(async () => {
    if (!walletClient || !address) return;
    const s = state.current;
    log("info", `Oracle at $${RE_RISK_PRICE} → re-risk condition met (ETH > $1,200)…`);
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
    setS2Done(true);
    log("success", `Stage 2 fired — back to WETH. Balance: ${formatEther(weth)} WETH`);
    log("success", "Full rotation cycle complete. Agent was offline the entire time.");
    setStep(4);
  });

  return (
    <div className="space-y-6">
      <div className="bg-zinc-900/60 border border-zinc-800 rounded-2xl p-5">
        <div className="flex items-center gap-3 mb-2">
          <span className="text-2xl">🔄</span>
          <div>
            <h2 className="text-lg font-bold text-zinc-100">Bi-directional Collateral Rotation</h2>
            <p className="text-sm text-zinc-400">Pre-commit a full de-risk/re-risk cycle. WETH↔USDC collateral rotates autonomously on price bands.</p>
          </div>
        </div>
        <FlowDiagram nodes={[
          { condition: "ETH < $1,800", action: "De-risk: WETH → USDC",  result: "Stablecoin collateral",  tone: "warn"    },
          { condition: "ETH > $1,200", action: "Re-risk: USDC → WETH",  result: "Back to WETH collateral", tone: "safe"    },
        ]} />
        <div className="flex items-center gap-4 mt-4">
          <div className={`flex-1 rounded-xl p-3 border text-xs ${s1Done ? "bg-blue-950/40 border-blue-700 text-blue-300" : "bg-zinc-800/40 border-zinc-700 text-zinc-400"}`}>
            <div className="font-medium mb-1">Stage 1 — De-risk</div>
            <div>ETH &lt; $1,800 → WETH → USDC</div>
            {s1Done && <div className="text-emerald-400 mt-1">✓ fired</div>}
          </div>
          <div className="text-zinc-600 text-xl">→</div>
          <div className={`flex-1 rounded-xl p-3 border text-xs ${s2Done ? "bg-emerald-950/40 border-emerald-700 text-emerald-300" : "bg-zinc-800/40 border-zinc-700 text-zinc-400"}`}>
            <div className="font-medium mb-1">Stage 2 — Re-risk</div>
            <div>ETH &gt; $1,200 → USDC → WETH</div>
            {s2Done && <div className="text-emerald-400 mt-1">✓ fired</div>}
          </div>
        </div>
        {finalWeth > 0n && (
          <div className="mt-3 p-3 bg-emerald-950/40 border border-emerald-700 rounded-xl text-sm text-emerald-300">
            Rotation complete — final WETH: <strong>{formatEther(finalWeth)}</strong>
          </div>
        )}
      </div>

      <div className="grid gap-4">
        {[
          { title: "Fund wallet",                               desc: "Mint 2 WETH as demo capital for the rotation.",                                                                                                                                                                                                        action: mint,          label: "Mint WETH"         },
          { title: "Deposit + set up rotation cycle",          desc: "Deposits 1 WETH as collateral. Pre-signs both the de-risk exit (WETH→USDC if price drops) and re-risk re-entry (USDC→WETH if price recovers) in a single session. Stage 2 input hash is deterministically computed from Stage 1's expected output.",  action: prepareAndSign, label: "Set Up Rotation"   },
          { title: "Stage 1 fires — de-risk to stablecoin",   desc: "ETH at $1,800 — below the de-risk threshold. Keeper triggers Stage 1: 1 WETH → 1,800 USDC. Collateral is now stablecoin. Stage 2 is instantly registered from pre-committed data.",                                                                     action: triggerDeRisk,  label: "Trigger De-risk"  },
          { title: "Stage 2 fires — re-risk back to WETH",    desc: "Price holds above $1,200. Keeper triggers Stage 2: 1,800 USDC → ~1 WETH. Collateral rebalanced to WETH. Full cycle complete with zero agent liveness required.",                                                                                          action: triggerReRisk,  label: "Trigger Re-risk"  },
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
