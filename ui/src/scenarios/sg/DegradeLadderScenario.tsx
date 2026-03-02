/**
 * Strategy Graph — Graduated Deleverage Ladder
 *
 * An agent pre-commits THREE independent exit envelopes at once, each covering
 * 1/3 of the position, triggered at successively lower price bands:
 *
 *   Envelope A: ETH < $2,000 → sell 0.33 WETH (first tranche)
 *   Envelope B: ETH < $1,600 → sell 0.33 WETH (second tranche)
 *   Envelope C: ETH < $1,200 → sell 0.34 WETH (final tranche, full exit)
 *
 * All three are registered simultaneously and fire independently.
 * Proves: fan-out pre-authorization (N envelopes, 1 setup session, 0 liveness).
 */
import { useState, useCallback, useRef } from "react";
import { useAccount, useWalletClient, usePublicClient } from "wagmi";
import { parseUnits, formatUnits } from "viem";

import { ADDRESSES, ANVIL_CHAIN_ID } from "../../contracts/addresses";
import { ERC20_ABI, VAULT_ABI, REGISTRY_ABI, MOCK_PRICE_ORACLE_ABI } from "../../contracts/abis";
import { LogPanel }  from "../../components/LogPanel";
import type { LogEntry } from "../../components/LogPanel";
import { StepCard }  from "../../components/StepCard";
import { TxButton }  from "../../components/TxButton";

import { SigningProgress } from "../../components/SigningProgress";
import type { SigStep }   from "../../components/SigningProgress";
import { FlowDiagram }    from "../../components/FlowDiagram";

import {
  buildCapability, buildManageCapability, buildIntent, buildEnvelope,
  signCapability, signIntent, signManageCapability,
  randomSalt, hashEnvelope, ZERO_ADDRESS, ComparisonOp, LogicOp,
} from "@atlas-protocol/sdk";
import type { Position, Conditions } from "@atlas-protocol/sdk";

const SIG_STEPS: SigStep[] = [
  { stage: "Tranche A — ETH < $2,000 (0.33 WETH)", label: "Spending permission",    icon: "🔑" },
  { stage: "Tranche A — ETH < $2,000 (0.33 WETH)", label: "Execution intent",       icon: "📋" },
  { stage: "Tranche A — ETH < $2,000 (0.33 WETH)", label: "Registration authority", icon: "🗝️" },
  { stage: "Tranche B — ETH < $1,600 (0.33 WETH)", label: "Spending permission",    icon: "🔑" },
  { stage: "Tranche B — ETH < $1,600 (0.33 WETH)", label: "Execution intent",       icon: "📋" },
  { stage: "Tranche B — ETH < $1,600 (0.33 WETH)", label: "Registration authority", icon: "🗝️" },
  { stage: "Tranche C — ETH < $1,200 (0.34 WETH)", label: "Spending permission",    icon: "🔑" },
  { stage: "Tranche C — ETH < $1,200 (0.34 WETH)", label: "Execution intent",       icon: "📋" },
  { stage: "Tranche C — ETH < $1,200 (0.34 WETH)", label: "Registration authority", icon: "🗝️" },
  { stage: "On-chain", label: "Register all 3 envelopes", icon: "⛓️" },
];

const TRANCHE_A   = parseUnits("0.33",  18);
const TRANCHE_B   = parseUnits("0.33",  18);
const TRANCHE_C   = parseUnits("0.34",  18);
const TRIGGER_A   = 2000n * 10n ** 8n;   // ETH < $2,000
const TRIGGER_B   = 1600n * 10n ** 8n;   // ETH < $1,600
const TRIGGER_C   = 1200n * 10n ** 8n;   // ETH < $1,200
const FIXED_PRICE = 1100;                // price below all triggers
const CAP_DUR     = 90n * 86400n;
const ENV_DUR     = 30n * 86400n;

interface TrancheData {
  envHash:      `0x${string}`;
  envelope:     unknown;
  manageCap:    unknown;
  manageCapSig: `0x${string}`;
  position:     unknown;
  conditions:   unknown;
  intent:       unknown;
  spendCap:     unknown;
  capSig:       `0x${string}`;
  intentSig:    `0x${string}`;
}

export function DegradeLadderScenario() {
  const { address }            = useAccount();
  const { data: walletClient } = useWalletClient();
  const publicClient           = usePublicClient();
  const logId                  = useRef(0);

  const [logs,    setLogs]    = useState<LogEntry[]>([]);
  const [step,    setStep]    = useState(0);
  const [busy,    setBusy]    = useState(false);
  const [sigStep, setSigStep] = useState(-1);
  const [tDone,   setTDone]   = useState([false, false, false]);
  const tranches = useRef<TrancheData[]>([]);

  const log = useCallback((level: LogEntry["level"], msg: string) =>
    setLogs(p => [...p, { id: ++logId.current, ts: Date.now(), level, message: msg }]), []);

  const withBusy = useCallback(async (fn: () => Promise<void>) => {
    setBusy(true);
    try { await fn(); }
    catch (e: unknown) { log("error", (e instanceof Error ? e.message : String(e)).slice(0, 300)); setSigStep(-1); }
    finally { setBusy(false); }
  }, [log]);

  const buildTranche = async (
    amount: bigint,
    trigger: bigint,
    label: string,
    now: bigint,
    sigOffset: number,
  ): Promise<TrancheData> => {
    if (!walletClient || !address) throw new Error("No wallet");

    await publicClient!.waitForTransactionReceipt({ hash: await walletClient.writeContract({
      address: ADDRESSES.MockWETH as `0x${string}`, abi: ERC20_ABI,
      functionName: "approve", args: [ADDRESSES.SingletonVault as `0x${string}`, amount],
    })});
    const salt = randomSalt();
    await publicClient!.waitForTransactionReceipt({ hash: await walletClient.writeContract({
      address: ADDRESSES.SingletonVault as `0x${string}`, abi: VAULT_ABI,
      functionName: "deposit", args: [ADDRESSES.MockWETH as `0x${string}`, amount, salt],
    })});
    const pos: Position = { owner: address, asset: ADDRESSES.MockWETH as `0x${string}`, amount, salt };

    setSigStep(sigOffset);
    const cap = buildCapability({
      issuer: address, grantee: address, expiry: now + CAP_DUR, nonce: randomSalt(),
      constraints: {
        maxSpendPerPeriod: amount * 2n, periodDuration: 86400n, minReturnBps: 0n,
        allowedAdapters: [ADDRESSES.PriceSwapAdapter as `0x${string}`],
        allowedTokensIn: [ADDRESSES.MockWETH as `0x${string}`], allowedTokensOut: [ADDRESSES.MockUSDC as `0x${string}`],
      },
    });
    const capSig = await signCapability(walletClient, cap, ADDRESSES.CapabilityKernel as `0x${string}`, ANVIL_CHAIN_ID);

    setSigStep(sigOffset + 1);
    const intent = buildIntent({
      position: pos, capability: cap, adapter: ADDRESSES.PriceSwapAdapter as `0x${string}`,
      adapterData: "0x", minReturn: 1n, deadline: now + CAP_DUR, nonce: randomSalt(),
      outputToken: ADDRESSES.MockUSDC as `0x${string}`, returnTo: ZERO_ADDRESS,
      submitter: ADDRESSES.EnvelopeRegistry as `0x${string}`, solverFeeBps: 0,
    });
    const intentSig = await signIntent(walletClient, intent, ADDRESSES.CapabilityKernel as `0x${string}`, ANVIL_CHAIN_ID);

    setSigStep(sigOffset + 2);
    const mgCap = buildManageCapability({ issuer: address, grantee: address, expiry: now + ENV_DUR, nonce: randomSalt() });
    const mgSig = await signManageCapability(walletClient, mgCap, ADDRESSES.EnvelopeRegistry as `0x${string}`, ANVIL_CHAIN_ID);

    const cond: Conditions = {
      priceOracle: ADDRESSES.MockPriceOracle as `0x${string}`, baseToken: ZERO_ADDRESS,
      quoteToken: ZERO_ADDRESS, triggerPrice: trigger, op: ComparisonOp.LESS_THAN,
      secondaryOracle: ZERO_ADDRESS, secondaryTriggerPrice: 0n, secondaryOp: ComparisonOp.LESS_THAN, logicOp: LogicOp.AND,
    };
    const env = buildEnvelope({ position: pos, conditions: cond, intent, manageCapability: mgCap,
      expiry: now + ENV_DUR, keeperRewardBps: 10, minKeeperRewardWei: 0n });
    const envHash = hashEnvelope(env) as `0x${string}`;

    log("success", `${label}: ${formatUnits(amount, 18)} WETH signed — ${envHash.slice(0, 10)}…`);
    return { envHash, envelope: env, manageCap: mgCap, manageCapSig: mgSig, position: pos,
      conditions: cond, intent, spendCap: cap, capSig, intentSig };
  };

  const mint = () => withBusy(async () => {
    if (!walletClient || !address) return;
    log("info", "Minting 1 WETH for 3-tranche position…");
    await publicClient!.waitForTransactionReceipt({ hash: await walletClient.writeContract({
      address: ADDRESSES.MockWETH as `0x${string}`, abi: ERC20_ABI,
      functionName: "mint", args: [address, parseUnits("1", 18)],
    })});
    log("success", "1 WETH minted");
    setStep(1);
  });

  const signAll = () => withBusy(async () => {
    if (!walletClient || !address) return;
    const { timestamp: now } = await publicClient!.getBlock({ blockTag: "latest" });

    await publicClient!.waitForTransactionReceipt({ hash: await walletClient.writeContract({
      address: ADDRESSES.MockPriceOracle as `0x${string}`, abi: MOCK_PRICE_ORACLE_ABI,
      functionName: "setPrice", args: [BigInt(FIXED_PRICE) * 10n ** 8n],
    })});
    log("info", `Oracle set to $${FIXED_PRICE} (below all triggers)…`);

    setSigStep(0);
    log("info", "Depositing & signing Tranche A (0.33 WETH, ETH < $2,000)…");
    const tA = await buildTranche(TRANCHE_A, TRIGGER_A, "Tranche A", now, 0);
    log("info", "Depositing & signing Tranche B (0.33 WETH, ETH < $1,600)…");
    const tB = await buildTranche(TRANCHE_B, TRIGGER_B, "Tranche B", now, 3);
    log("info", "Depositing & signing Tranche C (0.34 WETH, ETH < $1,200)…");
    const tC = await buildTranche(TRANCHE_C, TRIGGER_C, "Tranche C", now, 6);

    tranches.current = [tA, tB, tC];
    log("success", "9 EIP-712 sigs complete. Registering all 3 envelopes on-chain…");
    setSigStep(9);

    for (const [idx, t] of tranches.current.entries()) {
      await publicClient!.waitForTransactionReceipt({ hash: await walletClient.writeContract({
        address: ADDRESSES.EnvelopeRegistry as `0x${string}`, abi: REGISTRY_ABI,
        functionName: "register",
        args: [t.envelope as never, t.manageCap as never, t.manageCapSig, t.position as never],
      })});
      log("success", `Tranche ${["A","B","C"][idx]} registered on-chain`);
    }
    setSigStep(10);
    log("info", "All 3 exit envelopes live simultaneously — ladder is armed.");
    setStep(2);
  });

  const triggerAll = () => withBusy(async () => {
    if (!walletClient || !address || tranches.current.length === 0) return;
    log("info", `Oracle at $${FIXED_PRICE} — all 3 trigger conditions met simultaneously…`);

    for (const [idx, t] of tranches.current.entries()) {
      const label = ["A","B","C"][idx];
      await publicClient!.waitForTransactionReceipt({ hash: await walletClient.writeContract({
        address: ADDRESSES.EnvelopeRegistry as `0x${string}`, abi: REGISTRY_ABI,
        functionName: "trigger",
        args: [
          t.envHash,
          t.conditions as never,
          t.position as never,
          t.intent as never,
          t.spendCap as never,
          t.capSig,
          t.intentSig,
        ],
      })});
      log("success", `Tranche ${label} triggered — ${formatUnits(
        idx === 2 ? TRANCHE_C : TRANCHE_A, 18
      )} WETH → USDC`);
    }
    setTDone([true, true, true]);
    const usdc = await publicClient!.readContract({
      address: ADDRESSES.MockUSDC as `0x${string}`, abi: ERC20_ABI,
      functionName: "balanceOf", args: [address],
    }) as bigint;
    log("success", `Full exit complete — wallet USDC: ${(Number(usdc) / 1e6).toFixed(2)}`);
    log("info", "Each tranche fired independently. Zero agent liveness required at any trigger.");
    setStep(3);
  });

  const steps = [
    { title: "Fund wallet",                           desc: "Mint 1 WETH — split into 3 equal tranches for the deleverage ladder.",                                                                                                                                                                             action: mint,       label: "Mint WETH"           },
    { title: "Deposit 3 tranches + set up ladder",    desc: "Each tranche is a separate vault position with its own envelope. 9 signatures in one session authorise all 3 exits at different price thresholds. All 3 envelopes are registered on-chain simultaneously — the ladder is armed before prices move.",  action: signAll,    label: "Set Up Ladder"       },
    { title: "Fire all 3 tranches",                   desc: "Oracle at $1,100 — all three conditions (ETH < $2,000, $1,600, $1,200) are met. Each envelope fires independently as a separate transaction. Full WETH position exits to USDC.",                                                                       action: triggerAll, label: "Fire All Tranches"   },
  ];

  return (
    <div className="space-y-6">
      <div className="bg-zinc-900/60 border border-zinc-800 rounded-2xl p-5">
        <div className="flex items-center gap-3 mb-2">
          <span className="text-2xl">🪜</span>
          <div>
            <h2 className="text-lg font-bold text-zinc-100">Graduated Deleverage Ladder</h2>
            <p className="text-sm text-zinc-400">Pre-commit 3 independent exit envelopes at once, each covering 1/3 of your position. Each fires at a different price threshold — no agent online required at any trigger.</p>
          </div>
        </div>
        <FlowDiagram nodes={[
          { condition: "ETH < $2,000", action: "Sell Tranche A (0.33 WETH)", result: "First exit — profit lock", tone: "warn"    },
          { condition: "ETH < $1,600", action: "Sell Tranche B (0.33 WETH)", result: "Mid exit — stop-loss",     tone: "warn"    },
          { condition: "ETH < $1,200", action: "Sell Tranche C (0.34 WETH)", result: "Full exit — max protect",  tone: "danger"  },
        ]} />
        <div className="grid grid-cols-3 gap-3 mt-4 text-xs">
          {[
            { label: "Tranche A (33%)", val: "ETH < $2,000", color: "text-yellow-400" },
            { label: "Tranche B (33%)", val: "ETH < $1,600", color: "text-orange-400" },
            { label: "Tranche C (34%)", val: "ETH < $1,200", color: "text-red-400"    },
          ].map((r, i) => (
            <div key={r.label} className={`bg-zinc-800/60 rounded-lg p-2 ${tDone[i] ? "border border-emerald-700" : ""}`}>
              <div className="text-zinc-500">{r.label}</div>
              <div className={`${r.color} font-medium mt-0.5`}>{r.val}</div>
              {tDone[i] && <div className="text-emerald-400 text-xs mt-1">✓ triggered</div>}
            </div>
          ))}
        </div>
      </div>

      <div className="grid gap-4">
        {steps.map((s, i) => (
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
