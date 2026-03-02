/**
 * Leveraged Long — Recursive Rebuy
 *
 * Pre-commit a sell-high / buy-low cycle before any price move happens.
 * Stage 1: ETH < $2,000 → sell 1 WETH → 2,000 USDC (protective exit).
 * Stage 2: ETH > $1,200 → rebuy with USDC at $1,400 → ~1.43 WETH.
 * Net gain: +43% WETH. No agent online at either trigger.
 */
import { useState, useCallback, useRef } from "react";
import { useAccount, useWalletClient, usePublicClient } from "wagmi";
import { parseUnits, formatEther } from "viem";

import { ADDRESSES, ANVIL_CHAIN_ID } from "../../contracts/addresses";
import { ERC20_ABI, VAULT_ABI, REGISTRY_ABI, MOCK_PRICE_ORACLE_ABI } from "../../contracts/abis";
import { LogPanel }       from "../../components/LogPanel";
import type { LogEntry }  from "../../components/LogPanel";
import { StepCard }       from "../../components/StepCard";
import { TxButton }       from "../../components/TxButton";
import { SigningProgress } from "../../components/SigningProgress";
import type { SigStep }   from "../../components/SigningProgress";
import { FlowDiagram }    from "../../components/FlowDiagram";
import { computePositionHash, computeOutputSalt } from "../../utils/graphUtils";

import {
  buildCapability, buildManageCapability, buildIntent, buildEnvelope,
  signCapability, signIntent, signManageCapability,
  randomSalt, hashEnvelope, ZERO_ADDRESS, ComparisonOp, LogicOp,
} from "@atlas-protocol/sdk";
import type { Position, Conditions } from "@atlas-protocol/sdk";

const SELL_TRIGGER   = 2000n * 10n ** 8n;
const REBUY_TRIGGER  = 1200n * 10n ** 8n;
const EXIT_PRICE     = 2000;
const REBUY_PRICE    = 1400;
const WETH_IN        = parseUnits("1", 18);
const USDC_MID       = parseUnits("2000", 6);
const WETH_FINAL_MIN = parseUnits("1.4", 18);
const CAP_DUR        = 90n * 86400n;
const ENV_DUR        = 30n * 86400n;

const SIG_STEPS: SigStep[] = [
  { stage: "Stage 1 — Sell on price drop (WETH → USDC)", label: "Spending permission",    icon: "🔑" },
  { stage: "Stage 1 — Sell on price drop (WETH → USDC)", label: "Execution intent",       icon: "📋" },
  { stage: "Stage 1 — Sell on price drop (WETH → USDC)", label: "Registration authority", icon: "🗝️" },
  { stage: "Stage 2 — Rebuy on recovery (USDC → WETH)",  label: "Spending permission",    icon: "🔑" },
  { stage: "Stage 2 — Rebuy on recovery (USDC → WETH)",  label: "Execution intent",       icon: "📋" },
  { stage: "Stage 2 — Rebuy on recovery (USDC → WETH)",  label: "Registration authority", icon: "🗝️" },
  { stage: "On-chain", label: "Register Stage 1 envelope", icon: "⛓️" },
];

interface StageData {
  envelope: unknown; manageCap: unknown; manageCapSig: `0x${string}`; position: unknown;
  envelopeHash: `0x${string}`; conditions: unknown; intent: unknown; spendCap: unknown;
  capSig: `0x${string}`; intentSig: `0x${string}`;
}
interface GraphState { s1?: StageData; s2?: StageData; }

export function LeveragedLongScenario() {
  const { address }            = useAccount();
  const { data: walletClient } = useWalletClient();
  const publicClient           = usePublicClient();
  const logId                  = useRef(0);

  const [logs,      setLogs]      = useState<LogEntry[]>([]);
  const [step,      setStep]      = useState(0);
  const [busy,      setBusy]      = useState(false);
  const [sigStep,   setSigStep]   = useState(-1);
  const [wethFinal, setWethFinal] = useState(0n);
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
    setSigStep(0);

    log("info", `Oracle → $${EXIT_PRICE} for deterministic Stage 1 output…`);
    await publicClient!.waitForTransactionReceipt({ hash: await walletClient.writeContract({
      address: ADDRESSES.MockPriceOracle as `0x${string}`, abi: MOCK_PRICE_ORACLE_ABI,
      functionName: "setPrice", args: [BigInt(EXIT_PRICE) * 10n ** 8n],
    })});

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
    log("success", `Deposited 1 WETH. Position: ${s1PosHash.slice(0, 10)}…`);
    const { timestamp: now } = await publicClient!.getBlock({ blockTag: "latest" });

    // Stage 1 sigs
    setSigStep(0);
    const s1Cap = buildCapability({ issuer: address, grantee: address, expiry: now + CAP_DUR, nonce: randomSalt(),
      constraints: { maxSpendPerPeriod: WETH_IN * 2n, periodDuration: 86400n, minReturnBps: 0n,
        allowedAdapters: [ADDRESSES.PriceSwapAdapter as `0x${string}`],
        allowedTokensIn: [ADDRESSES.MockWETH as `0x${string}`], allowedTokensOut: [ADDRESSES.MockUSDC as `0x${string}`] } });
    const s1CapSig = await signCapability(walletClient, s1Cap, ADDRESSES.CapabilityKernel as `0x${string}`, ANVIL_CHAIN_ID);

    setSigStep(1);
    const s1IntentNonce = randomSalt();
    const s1Intent = buildIntent({ position: s1Pos, capability: s1Cap, adapter: ADDRESSES.PriceSwapAdapter as `0x${string}`,
      adapterData: "0x", minReturn: parseUnits("1800", 6), deadline: now + CAP_DUR, nonce: s1IntentNonce,
      outputToken: ADDRESSES.MockUSDC as `0x${string}`, returnTo: ZERO_ADDRESS,
      submitter: ADDRESSES.EnvelopeRegistry as `0x${string}`, solverFeeBps: 0 });
    const s1IntentSig = await signIntent(walletClient, s1Intent, ADDRESSES.CapabilityKernel as `0x${string}`, ANVIL_CHAIN_ID);

    setSigStep(2);
    const s1MgCap = buildManageCapability({ issuer: address, grantee: address, expiry: now + ENV_DUR, nonce: randomSalt() });
    const s1MgSig = await signManageCapability(walletClient, s1MgCap, ADDRESSES.EnvelopeRegistry as `0x${string}`, ANVIL_CHAIN_ID);

    const s1Cond: Conditions = { priceOracle: ADDRESSES.MockPriceOracle as `0x${string}`, baseToken: ZERO_ADDRESS,
      quoteToken: ZERO_ADDRESS, triggerPrice: SELL_TRIGGER, op: ComparisonOp.LESS_THAN,
      secondaryOracle: ZERO_ADDRESS, secondaryTriggerPrice: 0n, secondaryOp: ComparisonOp.LESS_THAN, logicOp: LogicOp.AND };
    const s1Env = buildEnvelope({ position: s1Pos, conditions: s1Cond, intent: s1Intent, manageCapability: s1MgCap,
      expiry: now + ENV_DUR, keeperRewardBps: 10, minKeeperRewardWei: 0n });
    const s1EnvHash = hashEnvelope(s1Env) as `0x${string}`;

    const s2InputSalt = computeOutputSalt(s1IntentNonce, s1PosHash);
    const s2Pos: Position = { owner: address, asset: ADDRESSES.MockUSDC as `0x${string}`, amount: USDC_MID, salt: s2InputSalt };
    log("success", `Stage 2 input pre-computed — hash locked before Stage 1 fires`);

    // Fix oracle to rebuy price for Stage 2 signing
    await publicClient!.waitForTransactionReceipt({ hash: await walletClient.writeContract({
      address: ADDRESSES.MockPriceOracle as `0x${string}`, abi: MOCK_PRICE_ORACLE_ABI,
      functionName: "setPrice", args: [BigInt(REBUY_PRICE) * 10n ** 8n],
    })});

    setSigStep(3);
    const s2Cap = buildCapability({ issuer: address, grantee: address, expiry: now + CAP_DUR, nonce: randomSalt(),
      constraints: { maxSpendPerPeriod: USDC_MID * 2n, periodDuration: 86400n, minReturnBps: 0n,
        allowedAdapters: [ADDRESSES.MockReverseSwapAdapter as `0x${string}`],
        allowedTokensIn: [ADDRESSES.MockUSDC as `0x${string}`], allowedTokensOut: [ADDRESSES.MockWETH as `0x${string}`] } });
    const s2CapSig = await signCapability(walletClient, s2Cap, ADDRESSES.CapabilityKernel as `0x${string}`, ANVIL_CHAIN_ID);

    setSigStep(4);
    const s2Intent = buildIntent({ position: s2Pos, capability: s2Cap, adapter: ADDRESSES.MockReverseSwapAdapter as `0x${string}`,
      adapterData: "0x", minReturn: WETH_FINAL_MIN, deadline: now + CAP_DUR, nonce: randomSalt(),
      outputToken: ADDRESSES.MockWETH as `0x${string}`, returnTo: ZERO_ADDRESS,
      submitter: ADDRESSES.EnvelopeRegistry as `0x${string}`, solverFeeBps: 0 });
    const s2IntentSig = await signIntent(walletClient, s2Intent, ADDRESSES.CapabilityKernel as `0x${string}`, ANVIL_CHAIN_ID);

    setSigStep(5);
    const s2MgCap = buildManageCapability({ issuer: address, grantee: address, expiry: now + ENV_DUR, nonce: randomSalt() });
    const s2MgSig = await signManageCapability(walletClient, s2MgCap, ADDRESSES.EnvelopeRegistry as `0x${string}`, ANVIL_CHAIN_ID);

    const s2Cond: Conditions = { priceOracle: ADDRESSES.MockPriceOracle as `0x${string}`, baseToken: ZERO_ADDRESS,
      quoteToken: ZERO_ADDRESS, triggerPrice: REBUY_TRIGGER, op: ComparisonOp.GREATER_THAN,
      secondaryOracle: ZERO_ADDRESS, secondaryTriggerPrice: 0n, secondaryOp: ComparisonOp.LESS_THAN, logicOp: LogicOp.AND };
    const s2Env = buildEnvelope({ position: s2Pos, conditions: s2Cond, intent: s2Intent, manageCapability: s2MgCap,
      expiry: now + ENV_DUR, keeperRewardBps: 10, minKeeperRewardWei: 0n });
    const s2EnvHash = hashEnvelope(s2Env) as `0x${string}`;

    await publicClient!.waitForTransactionReceipt({ hash: await walletClient.writeContract({
      address: ADDRESSES.MockPriceOracle as `0x${string}`, abi: MOCK_PRICE_ORACLE_ABI,
      functionName: "setPrice", args: [BigInt(EXIT_PRICE) * 10n ** 8n],
    })});

    state.current.s1 = { envelope: s1Env, manageCap: s1MgCap, manageCapSig: s1MgSig, position: s1Pos,
      envelopeHash: s1EnvHash, conditions: s1Cond, intent: s1Intent, spendCap: s1Cap, capSig: s1CapSig, intentSig: s1IntentSig };
    state.current.s2 = { envelope: s2Env, manageCap: s2MgCap, manageCapSig: s2MgSig, position: s2Pos,
      envelopeHash: s2EnvHash, conditions: s2Cond, intent: s2Intent, spendCap: s2Cap, capSig: s2CapSig, intentSig: s2IntentSig };

    setSigStep(6);
    await publicClient!.waitForTransactionReceipt({ hash: await walletClient.writeContract({
      address: ADDRESSES.EnvelopeRegistry as `0x${string}`, abi: REGISTRY_ABI,
      functionName: "register",
      args: [s1Env as never, s1MgCap as never, s1MgSig, s1Pos as never],
    })});
    setSigStep(7);
    log("success", `Both stages committed. Stage 1 live — oracle reset to $${EXIT_PRICE}.`);
    setStep(2);
  });

  const triggerStage1 = () => withBusy(async () => {
    if (!walletClient || !address) return;
    const { s1, s2 } = state.current;
    if (!s1 || !s2) { log("error", "Complete step 2 first"); return; }

    log("info", `Oracle at $${EXIT_PRICE} — ETH < $2,000 condition met. Keeper triggering…`);
    await publicClient!.waitForTransactionReceipt({ hash: await walletClient.writeContract({
      address: ADDRESSES.EnvelopeRegistry as `0x${string}`, abi: REGISTRY_ABI,
      functionName: "trigger",
      args: [s1.envelopeHash, s1.conditions as never, s1.position as never, s1.intent as never, s1.spendCap as never, s1.capSig, s1.intentSig],
    })});
    log("success", "Stage 1 executed — 1 WETH → 2,000 USDC");

    await publicClient!.waitForTransactionReceipt({ hash: await walletClient.writeContract({
      address: ADDRESSES.MockPriceOracle as `0x${string}`, abi: MOCK_PRICE_ORACLE_ABI,
      functionName: "setPrice", args: [BigInt(REBUY_PRICE) * 10n ** 8n],
    })});
    log("info", `Oracle → $${REBUY_PRICE}. Registering Stage 2 from pre-signed data…`);
    await publicClient!.waitForTransactionReceipt({ hash: await walletClient.writeContract({
      address: ADDRESSES.EnvelopeRegistry as `0x${string}`, abi: REGISTRY_ABI,
      functionName: "register",
      args: [s2.envelope as never, s2.manageCap as never, s2.manageCapSig, s2.position as never],
    })});
    log("success", `Stage 2 registered: ${s2.envelopeHash.slice(0, 10)}… — condition ETH > $1,200 already met`);
    setStep(3);
  });

  const triggerStage2 = () => withBusy(async () => {
    if (!walletClient || !address) return;
    const { s2 } = state.current;
    if (!s2) { log("error", "Complete step 3 first"); return; }

    log("info", `Oracle at $${REBUY_PRICE} — ETH > $1,200 condition met. Keeper triggering rebuy…`);
    await publicClient!.waitForTransactionReceipt({ hash: await walletClient.writeContract({
      address: ADDRESSES.EnvelopeRegistry as `0x${string}`, abi: REGISTRY_ABI,
      functionName: "trigger",
      args: [s2.envelopeHash, s2.conditions as never, s2.position as never, s2.intent as never, s2.spendCap as never, s2.capSig, s2.intentSig],
    })});

    const finalWeth = await publicClient!.readContract({
      address: ADDRESSES.MockWETH as `0x${string}`, abi: ERC20_ABI,
      functionName: "balanceOf", args: [address],
    }) as bigint;
    setWethFinal(finalWeth);
    log("success", `Stage 2 executed — 2,000 USDC → ${formatEther(finalWeth)} WETH`);
    log("success", `Net: started 1 WETH, ended ${formatEther(finalWeth)} WETH (+${((Number(formatEther(finalWeth)) - 1) * 100).toFixed(1)}%)`);
    setStep(4);
  });

  const steps = [
    { title: "Fund wallet",                       desc: "Mint 2 WETH to use as collateral for the leveraged long.",                                                                                                                            action: mint,          label: "Mint WETH"           },
    { title: "Deposit + set up leverage graph",   desc: "Deposits 1 WETH as collateral. Pre-signs all 6 permissions covering both stages — before any price event occurs. Oracle is set temporarily to compute deterministic output hashes.",  action: prepareAndSign, label: "Deposit + Set Up Graph" },
    { title: "Stage 1 fires — sell at $2,000",   desc: "ETH drops below $2,000. Keeper triggers Stage 1: 1 WETH converts to 2,000 USDC. Stage 2 (rebuy) is instantly registered from the pre-committed signature.",                          action: triggerStage1,  label: "Trigger Stage 1 (sell)"  },
    { title: "Stage 2 fires — rebuy at $1,400",  desc: "Oracle set to $1,400 (ETH > $1,200 condition met). Keeper triggers Stage 2: 2,000 USDC → ~1.43 WETH. Leverage cycle complete.",                                                       action: triggerStage2,  label: "Trigger Stage 2 (rebuy)" },
  ];

  return (
    <div className="space-y-6">
      <div className="bg-zinc-900/60 border border-zinc-800 rounded-2xl p-5">
        <div className="flex items-center gap-3 mb-2">
          <span className="text-2xl">📈</span>
          <div>
            <h2 className="text-lg font-bold text-zinc-100">Leveraged Long — Recursive Rebuy</h2>
            <p className="text-sm text-zinc-400">Pre-commit a full sell-high / buy-low cycle in one setup session. Exit at $2,000, rebuy at $1,400, end with 43% more WETH — no agent online at either trigger.</p>
          </div>
        </div>
        <FlowDiagram nodes={[
          { condition: "Deposit 1 WETH",  action: "Pre-sign both stages",        result: "Agent goes offline",          tone: "neutral" },
          { condition: "ETH < $2,000",    action: "Sell → 2,000 USDC",           result: "Stage 2 auto-registered",     tone: "warn"    },
          { condition: "ETH > $1,200",    action: "Rebuy → ~1.43 WETH",          result: "+43% vs. starting balance",   tone: "safe"    },
        ]} />
        <div className="grid grid-cols-3 gap-3 mt-4 text-xs">
          {[
            { label: "Stage 1 trigger", val: "ETH < $2,000 → sell" },
            { label: "Stage 2 trigger", val: "ETH > $1,200 → rebuy" },
            { label: "Leverage",        val: "$2k exit / $1.4k rebuy = 1.43×" },
          ].map(r => (
            <div key={r.label} className="bg-zinc-800/60 rounded-lg p-2">
              <div className="text-zinc-500">{r.label}</div>
              <div className="text-zinc-200 font-medium mt-0.5">{r.val}</div>
            </div>
          ))}
        </div>
        {wethFinal > 0n && (
          <div className="mt-4 p-3 bg-emerald-950/40 border border-emerald-700 rounded-xl text-sm text-emerald-300">
            ✓ Final: <strong>{formatEther(wethFinal)} WETH</strong> — gain: <strong>+{((Number(formatEther(wethFinal)) - 1) * 100).toFixed(1)}%</strong>
          </div>
        )}
      </div>

      <div className="grid gap-4">
        {steps.map((s, i) => (
          <StepCard key={i} index={i} title={s.title} description={s.desc}
            status={step > i ? "done" : step === i ? (busy ? "loading" : "ready") : "pending"}>
            {step === i && (
              <div className="space-y-3">
                {i === 1 && sigStep >= 0 && sigStep < SIG_STEPS.length + 1 && (
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
