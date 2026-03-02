/**
 * Capital Provider — Institutional Lend tab
 *
 * Step 1 — Fund the pool        Lender deposits 100,000 USDC.
 * Step 2 — Define risk policy   Configure guard threshold & tier limits before any borrowing.
 * Step 3 — Verify borrower      ZK Credit Passport assigns Tier 2 (within policy limits).
 * Step 4 — Loan drawn           Agent borrows 45,000 USDC → 45% utilisation.
 * Step 5 — Register & enforce   Sign 3 EIP-712 messages. Keeper fires PoolPauseAdapter.
 * Step 6 — Repayment + yield    Agent repays + interest; lender claims yield.
 */
import { useState, useCallback, useRef, useEffect } from "react";
import { useAccount, useWalletClient, usePublicClient } from "wagmi";
import { parseUnits, formatUnits, encodeAbiParameters } from "viem";

import { ADDRESSES, ANVIL_CHAIN_ID } from "../contracts/addresses";
import {
  ERC20_ABI,
  MOCK_CAPITAL_POOL_ABI,
  VAULT_ABI,
  REGISTRY_ABI,
} from "../contracts/abis";
import { LogPanel }        from "../components/LogPanel";
import type { LogEntry }   from "../components/LogPanel";
import { StepCard }        from "../components/StepCard";
import type { StepStatus } from "../components/StepCard";
import { TxButton }        from "../components/TxButton";
import { FlowDiagram }     from "../components/FlowDiagram";
import { SigningProgress } from "../components/SigningProgress";
import type { SigStep }    from "../components/SigningProgress";

import {
  buildCapability, buildManageCapability, buildIntent, buildEnvelope,
  signCapability, signIntent, signManageCapability,
  randomSalt, hashEnvelope, ZERO_ADDRESS, ComparisonOp, LogicOp,
} from "@atlas-protocol/sdk";
// NOTE: ComparisonOp only has LESS_THAN(0), GREATER_THAN(1), EQUAL(2).
// GTE semantics → use GREATER_THAN with triggerPrice = guardBps - 1.
import type { Position, Conditions } from "@atlas-protocol/sdk";

// ─── Constants ────────────────────────────────────────────────────────────────
const LEND_AMT     = parseUnits("100000", 6);
const BORROW_AMT   = parseUnits("45000",  6);
const INTEREST_AMT = parseUnits("2250",   6);
const SENTINEL_AMT = parseUnits("100",    6);
const BOT_ID       = 99n;
const CAP_DUR      = 90n  * 86400n;
const ENV_DUR      = 30n  * 86400n;

// ─── Risk policy presets ──────────────────────────────────────────────────────
interface PolicyPreset {
  id: string; label: string; description: string; tag: string;
  guardBps: number; tier1Limit: number; tier2Limit: number; maxDuration: number;
  color: string; border: string;
}

const PRESETS: PolicyPreset[] = [
  {
    id: "conservative", label: "Conservative", tag: "Low Risk",
    description: "Tight controls. Guard fires at 70% utilisation. Small credit limits. Best for first deployment.",
    guardBps: 7000, tier1Limit: 5_000, tier2Limit: 20_000, maxDuration: 14,
    color: "text-blue-300", border: "border-blue-700",
  },
  {
    id: "moderate", label: "Moderate", tag: "Balanced",
    description: "Standard institutional parameters. Guard at 80%. Comfortable tier limits for vetted borrowers.",
    guardBps: 8000, tier1Limit: 10_000, tier2Limit: 35_000, maxDuration: 30,
    color: "text-indigo-300", border: "border-indigo-700",
  },
  {
    id: "standard", label: "Standard", tag: "Production",
    description: "Full Tier 2 limits. 90% guard threshold. Suitable when ZK proof quality is high.",
    guardBps: 9000, tier1Limit: 10_000, tier2Limit: 50_000, maxDuration: 30,
    color: "text-emerald-300", border: "border-emerald-700",
  },
  {
    id: "demo", label: "Demo", tag: "Demo Mode",
    description: "Guard at 44% — already exceeded after step 3 (45%). Keeper fires immediately after registration.",
    guardBps: 4400, tier1Limit: 10_000, tier2Limit: 50_000, maxDuration: 7,
    color: "text-amber-300", border: "border-amber-700",
  },
];

// ─── Signing steps ─────────────────────────────────────────────────────────
const SIG_STEPS: SigStep[] = [
  { stage: "Guard Envelope", label: "Sentinel spending permission",  icon: "🔑" },
  { stage: "Guard Envelope", label: "PoolPauseAdapter intent",       icon: "📋" },
  { stage: "Guard Envelope", label: "Registration authority",        icon: "🗝️" },
  { stage: "On-chain",       label: "Register envelope",             icon: "⛓️" },
];

// ─── Pool stats ───────────────────────────────────────────────────────────────
interface PoolStats {
  totalCapital: bigint; totalBorrowed: bigint; available: bigint;
  utilizationBps: bigint; yieldEarned: bigint; paused: boolean;
}

// ─── UI helpers ───────────────────────────────────────────────────────────────
function UtilBar({ bps, guardBps }: { bps: bigint; guardBps: number }) {
  const pct      = Math.min(Number(bps) / 100, 100);
  const guardPct = guardBps / 100;
  const color    = Number(bps) >= 9000 ? "bg-red-500" : Number(bps) >= guardBps ? "bg-amber-400" : "bg-emerald-500";
  return (
    <div className="relative h-3 rounded-full bg-zinc-800 overflow-hidden">
      <div className={`h-full rounded-full transition-all duration-700 ${color}`} style={{ width: `${pct}%` }} />
      <div className="absolute top-0 bottom-0 w-px bg-amber-400/80" style={{ left: `${guardPct}%` }} />
    </div>
  );
}

function StatPill({ label, value, sub, highlight }: { label: string; value: string; sub?: string; highlight?: boolean }) {
  return (
    <div className={`rounded-xl px-4 py-3 flex flex-col gap-0.5 transition-colors ${highlight ? "bg-emerald-900/30 border border-emerald-700/50" : "bg-zinc-800/60"}`}>
      <span className="text-xs text-zinc-500 font-medium">{label}</span>
      <span className={`text-lg font-bold leading-tight ${highlight ? "text-emerald-300" : "text-zinc-100"}`}>{value}</span>
      {sub && <span className="text-xs text-zinc-500">{sub}</span>}
    </div>
  );
}

function PolicyCard({ policy }: { policy: PolicyPreset }) {
  const rules = [
    { icon: "🛡️", label: "Utilisation Guard",   value: `≥ ${policy.guardBps/100}%`,                  action: "→ Pause all new borrows",    note: "PoolPauseAdapter · Atlas keeper · no ops team",        accent: policy.guardBps <= 5000 ? "text-amber-400" : policy.guardBps <= 8000 ? "text-indigo-300" : "text-emerald-300" },
    { icon: "🏅", label: "Tier 1 Credit Limit", value: `≤ $${policy.tier1Limit.toLocaleString()} USDC`, action: "→ ZK grade 1 required",      note: "Borrower identity never exposed",                      accent: "text-zinc-300" },
    { icon: "🏆", label: "Tier 2 Credit Limit", value: `≤ $${policy.tier2Limit.toLocaleString()} USDC`, action: "→ ZK grade 2 required",      note: "Higher income + credit score proof",                   accent: "text-zinc-300" },
    { icon: "⏱️", label: "Max Loan Duration",   value: `${policy.maxDuration} days`,                  action: "→ Auto-repayment envelope",  note: "Keeper enforces deadline regardless of agent liveness", accent: "text-zinc-300" },
  ];
  return (
    <div className="rounded-xl border border-zinc-700/60 bg-zinc-800/30 overflow-hidden text-xs">
      <div className="px-4 py-2.5 border-b border-zinc-700/60 flex items-center justify-between bg-zinc-800/50">
        <span className="font-semibold text-zinc-300">RISK POLICY v1.0 · ClawLoan Capital Pool</span>
        <span className="text-zinc-600">Pre-committed · Immutable after signing</span>
      </div>
      <div className="divide-y divide-zinc-700/40">
        {rules.map(r => (
          <div key={r.label} className="px-4 py-2.5 flex items-start gap-3">
            <span className="text-sm mt-0.5 shrink-0">{r.icon}</span>
            <div className="flex-1">
              <div className="flex items-baseline gap-2 flex-wrap">
                <span className="text-zinc-400 font-medium">{r.label}</span>
                <span className={`font-bold ${r.accent}`}>{r.value}</span>
                <span className="text-zinc-500">{r.action}</span>
              </div>
              <p className="text-zinc-600 mt-0.5">{r.note}</p>
            </div>
          </div>
        ))}
      </div>
      <div className="px-4 py-2 border-t border-zinc-700/60 bg-zinc-900/50 flex justify-between text-zinc-600">
        <span>UtilisationOracle · PoolPauseAdapter · EnvelopeRegistry</span>
        <span className="font-mono">UNSIGNED</span>
      </div>
    </div>
  );
}

type StepKey = "fund" | "policy" | "verify" | "borrow" | "guard" | "repay";

function statusFor(key: StepKey, done: Set<StepKey>, busy: StepKey | null): StepStatus {
  if (done.has(key)) return "done";
  if (busy === key)  return "loading";
  const order: StepKey[] = ["fund", "policy", "verify", "borrow", "guard", "repay"];
  const prevDone = order.slice(0, order.indexOf(key)).every(k => done.has(k));
  return prevDone ? "ready" : "pending";
}

// ─── Main component ───────────────────────────────────────────────────────────
export function CapitalProviderScenario() {
  const { address }  = useAccount();
  const { data: wc } = useWalletClient();
  const pub          = usePublicClient();
  const logId        = useRef(0);

  const [logs, setLogs]          = useState<LogEntry[]>([]);
  const [done, setDone]          = useState<Set<StepKey>>(new Set());
  const [busy, setBusy]          = useState<StepKey | null>(null);
  const [stats, setStats]        = useState<PoolStats | null>(null);
  const [yieldPending, setYield] = useState<bigint>(0n);
  const [sigStep, setSigStep]    = useState(-1);
  const [envelopeHash, setEnvHash]     = useState<string>("");
  const [selectedPreset, setSelectedPreset] = useState<PolicyPreset>(PRESETS[3]);
  const [lockedPolicy, setLockedPolicy]     = useState<PolicyPreset | null>(null);

  const log = useCallback((level: LogEntry["level"], message: string) =>
    setLogs(p => [...p, { id: ++logId.current, ts: Date.now(), level, message }]), []);

  // ── Stats polling — use getPoolStats (single call, all fields in ABI) ─────────
  const refreshStats = useCallback(async () => {
    if (!pub) return;
    try {
      const raw = await pub.readContract({
        address: ADDRESSES.MockCapitalPool as `0x${string}`,
        abi: MOCK_CAPITAL_POOL_ABI,
        functionName: "getPoolStats",
      }) as readonly [bigint, bigint, bigint, bigint, bigint, boolean];
      // Destructure by index: totalCap, totalBorrow, available, utilBps, yieldEarned, paused
      setStats({
        totalCapital:   raw[0],
        totalBorrowed:  raw[1],
        available:      raw[2],
        utilizationBps: raw[3],
        yieldEarned:    raw[4],
        paused:         raw[5],
      });
      if (address) {
        const yp = await pub.readContract({
          address: ADDRESSES.MockCapitalPool as `0x${string}`,
          abi: MOCK_CAPITAL_POOL_ABI,
          functionName: "pendingYield",
          args: [address],
        }) as bigint;
        setYield(yp);
      }
    } catch { /* pool not yet deployed or funded */ }
  }, [pub, address]);

  useEffect(() => {
    refreshStats();
    const t = setInterval(refreshStats, 3000);
    return () => clearInterval(t);
  }, [refreshStats]);

  const withBusy = useCallback(async (key: StepKey, fn: () => Promise<void>) => {
    setBusy(key);
    try {
      await fn();
      setDone(p => new Set([...p, key]));
    } catch (e: unknown) {
      log("error", (e instanceof Error ? e.message : String(e)).slice(0, 400));
      setSigStep(-1);
    } finally {
      setBusy(null);
      await refreshStats();
    }
  }, [log, refreshStats]);

  // ── Step 1 ──────────────────────────────────────────────────────────────────
  const fundPool = useCallback(() => withBusy("fund", async () => {
    if (!wc || !address || !pub) throw new Error("Wallet not connected");
    log("info", "Minting 100,000 USDC…");
    await pub.waitForTransactionReceipt({ hash: await wc.writeContract({ address: ADDRESSES.MockUSDC as `0x${string}`, abi: ERC20_ABI, functionName: "mint", args: [address, LEND_AMT] }) });
    await pub.waitForTransactionReceipt({ hash: await wc.writeContract({ address: ADDRESSES.MockUSDC as `0x${string}`, abi: ERC20_ABI, functionName: "approve", args: [ADDRESSES.MockCapitalPool as `0x${string}`, LEND_AMT] }) });
    log("info", "Depositing 100,000 USDC into capital pool…");
    const h = await wc.writeContract({ address: ADDRESSES.MockCapitalPool as `0x${string}`, abi: MOCK_CAPITAL_POOL_ABI, functionName: "provideCapital", args: [LEND_AMT] });
    await pub.waitForTransactionReceipt({ hash: h });
    log("success", `Pool funded: 100,000 USDC committed. tx ${h.slice(0,10)}…`);
    log("info", "Default tier limits: Tier 1 = 10k · Tier 2 = 50k USDC");
  }), [wc, address, pub, log, withBusy]);

  // ── Step 2 ──────────────────────────────────────────────────────────────────
  const verifyBorrower = useCallback(() => withBusy("verify", async () => {
    if (!wc || !pub) throw new Error("Wallet not connected");
    log("info", `ZK Credit Passport check for Bot #${BOT_ID}…`);
    log("info", "Proof: grade 2 (income > $150k, score 780+, 0 defaults) — verified without doxxing");
    const h = await wc.writeContract({ address: ADDRESSES.MockCapitalPool as `0x${string}`, abi: MOCK_CAPITAL_POOL_ABI, functionName: "assignTier", args: [BOT_ID, 2] });
    await pub.waitForTransactionReceipt({ hash: h });
    log("success", `Tier 2 assigned — limit: 50,000 USDC. tx ${h.slice(0,10)}…`);
  }), [wc, pub, log, withBusy]);

  // ── Step 3 ──────────────────────────────────────────────────────────────────
  const simulateBorrow = useCallback(() => withBusy("borrow", async () => {
    if (!wc || !pub) throw new Error("Wallet not connected");
    log("info", `Bot #${BOT_ID} drawing 45,000 USDC (within Tier 2 limit)…`);
    const h = await wc.writeContract({ address: ADDRESSES.MockCapitalPool as `0x${string}`, abi: MOCK_CAPITAL_POOL_ABI, functionName: "borrow", args: [BOT_ID, BORROW_AMT] });
    await pub.waitForTransactionReceipt({ hash: h });
    log("success", `Loan issued: 45,000 USDC. Utilisation now 45%. tx ${h.slice(0,10)}…`);
    log("info", "Now register the Atlas Envelope in Step 5 to enforce your locked policy");
  }), [wc, pub, log, withBusy]);

  // ── Step 4: Lock policy on-chain ─────────────────────────────────────────────
  const lockPolicy = useCallback(() => withBusy("policy", async () => {
    if (!wc || !pub) throw new Error("Wallet not connected");
    const p = selectedPreset;
    log("info", `Committing "${p.label}" policy — Guard: ${p.guardBps/100}% · Tier 1: $${p.tier1Limit.toLocaleString()} · Tier 2: $${p.tier2Limit.toLocaleString()}`);
    await pub.waitForTransactionReceipt({ hash: await wc.writeContract({ address: ADDRESSES.MockCapitalPool as `0x${string}`, abi: MOCK_CAPITAL_POOL_ABI, functionName: "setTierLimit", args: [1, parseUnits(p.tier1Limit.toString(), 6)] }) });
    await pub.waitForTransactionReceipt({ hash: await wc.writeContract({ address: ADDRESSES.MockCapitalPool as `0x${string}`, abi: MOCK_CAPITAL_POOL_ABI, functionName: "setTierLimit", args: [2, parseUnits(p.tier2Limit.toString(), 6)] }) });
    const h = await wc.writeContract({ address: ADDRESSES.MockCapitalPool as `0x${string}`, abi: MOCK_CAPITAL_POOL_ABI, functionName: "setUtilizationGuard", args: [BigInt(p.guardBps)] });
    await pub.waitForTransactionReceipt({ hash: h });
    setLockedPolicy(p);
    log("success", `Policy locked on-chain. tx ${h.slice(0,10)}…`);
    log("info", "Step 5: register the Atlas Envelope that enforces this policy cryptographically");
  }), [wc, pub, log, withBusy, selectedPreset]);

  // ── Step 5: Sign + register real Atlas envelope ─────────────────────────────
  const registerGuard = useCallback(() => withBusy("guard", async () => {
    if (!wc || !address || !pub) throw new Error("Wallet not connected");
    const policy   = lockedPolicy ?? selectedPreset;
    const guardBps = BigInt(policy.guardBps);
    const { timestamp: now } = await pub.getBlock({ blockTag: "latest" });

    // Deposit sentinel USDC position into vault
    log("info", "Minting + depositing 100 USDC sentinel position into Atlas vault…");
    await pub.waitForTransactionReceipt({ hash: await wc.writeContract({ address: ADDRESSES.MockUSDC as `0x${string}`, abi: ERC20_ABI, functionName: "mint", args: [address, SENTINEL_AMT] }) });
    await pub.waitForTransactionReceipt({ hash: await wc.writeContract({ address: ADDRESSES.MockUSDC as `0x${string}`, abi: ERC20_ABI, functionName: "approve", args: [ADDRESSES.SingletonVault as `0x${string}`, SENTINEL_AMT] }) });
    const sentinelSalt = randomSalt();
    await pub.waitForTransactionReceipt({
      hash: await wc.writeContract({ address: ADDRESSES.SingletonVault as `0x${string}`, abi: VAULT_ABI, functionName: "deposit", args: [ADDRESSES.MockUSDC as `0x${string}`, SENTINEL_AMT, sentinelSalt] }),
    });
    log("success", "Sentinel position deposited");

    const position: Position = {
      owner: address, asset: ADDRESSES.MockUSDC as `0x${string}`,
      amount: SENTINEL_AMT, salt: sentinelSalt,
    };
    const adapterData = encodeAbiParameters([{ type: "address" }], [ADDRESSES.MockCapitalPool as `0x${string}`]);

    // Sign spending capability
    log("info", "Sign spending permission (1/3)…");
    setSigStep(0);
    const spendCap = buildCapability({
      issuer: address, grantee: address,
      expiry: now + CAP_DUR, nonce: randomSalt(),
      constraints: {
        maxSpendPerPeriod: SENTINEL_AMT * 2n, periodDuration: CAP_DUR, minReturnBps: 0n,
        allowedAdapters:  [ADDRESSES.PoolPauseAdapter as `0x${string}`],
        allowedTokensIn:  [ADDRESSES.MockUSDC as `0x${string}`],
        allowedTokensOut: [ADDRESSES.MockUSDC as `0x${string}`],
      },
    });
    const capSig = await signCapability(wc, spendCap, ADDRESSES.CapabilityKernel as `0x${string}`, ANVIL_CHAIN_ID);

    // Sign execution intent
    log("info", "Sign PoolPauseAdapter intent (2/3)…");
    setSigStep(1);
    const intent = buildIntent({
      position, capability: spendCap,
      adapter: ADDRESSES.PoolPauseAdapter as `0x${string}`, adapterData,
      minReturn: SENTINEL_AMT, deadline: now + ENV_DUR, nonce: randomSalt(),
      outputToken: ADDRESSES.MockUSDC as `0x${string}`,
      returnTo:  ZERO_ADDRESS as `0x${string}`,
      submitter: ADDRESSES.EnvelopeRegistry as `0x${string}`,
      solverFeeBps: 0,
    });
    const intentSig = await signIntent(wc, intent, ADDRESSES.CapabilityKernel as `0x${string}`, ANVIL_CHAIN_ID);

    // Sign manage capability
    log("info", "Sign registration authority (3/3)…");
    setSigStep(2);
    const manageCap = buildManageCapability({
      issuer: address, grantee: address,
      expiry: now + ENV_DUR, nonce: randomSalt(),
    });
    const manageCapSig = await signManageCapability(wc, manageCap, ADDRESSES.EnvelopeRegistry as `0x${string}`, ANVIL_CHAIN_ID);

    // Build envelope + register
    // GREATER_THAN with (guardBps - 1) gives "price >= guardBps" for integer BPS
    const conditions: Conditions = {
      priceOracle:   ADDRESSES.UtilisationOracle as `0x${string}`,
      baseToken:     ZERO_ADDRESS as `0x${string}`,
      quoteToken:    ZERO_ADDRESS as `0x${string}`,
      triggerPrice:  guardBps > 0n ? guardBps - 1n : 0n,
      op:            ComparisonOp.GREATER_THAN,
      secondaryOracle: ZERO_ADDRESS as `0x${string}`,
      secondaryTriggerPrice: 0n,
      secondaryOp:   ComparisonOp.EQUAL,
      logicOp:       LogicOp.AND,
    };

    const envelope = buildEnvelope({
      position, conditions, intent, manageCapability: manageCap,
      expiry: now + ENV_DUR, keeperRewardBps: 50, minKeeperRewardWei: 0n,
    });

    log("info", "Registering guard envelope on-chain…");
    setSigStep(3);
    const regH = await wc.writeContract({
      address: ADDRESSES.EnvelopeRegistry as `0x${string}`, abi: REGISTRY_ABI,
      functionName: "register", args: [envelope as never, manageCap as never, manageCapSig, position as never],
    });
    await pub.waitForTransactionReceipt({ hash: regH });
    const envHash = hashEnvelope(envelope) as `0x${string}`;
    setSigStep(-1);

    log("success", `Guard envelope registered: ${envHash.slice(0,12)}… tx ${regH.slice(0,10)}…`);
    log("info", `Condition: UtilisationOracle > ${Number(guardBps)-1} bps (≥ ${policy.guardBps/100}%)`);
    setEnvHash(envHash);

    const currentUtil = stats?.utilizationBps ?? 0n;
    if (currentUtil >= guardBps) {
      log("info", `Utilisation is ${Number(currentUtil)/100}% — condition TRUE — keeper triggering now…`);
      const trigH = await wc.writeContract({
        address: ADDRESSES.EnvelopeRegistry as `0x${string}`, abi: REGISTRY_ABI,
        functionName: "trigger",
        args: [envHash, conditions as never, position as never, intent as never, spendCap as never, capSig, intentSig],
      });
      await pub.waitForTransactionReceipt({ hash: trigH });
      log("success", `Pool paused by keeper via PoolPauseAdapter. tx ${trigH.slice(0,10)}…`);
    } else {
      log("info", `Pool live. Guard activates when utilisation reaches ${policy.guardBps/100}%.`);
    }
  }), [wc, address, pub, log, withBusy, lockedPolicy, selectedPreset, stats]);

  // ── Step 6 ──────────────────────────────────────────────────────────────────
  const repayAndClaim = useCallback(() => withBusy("repay", async () => {
    if (!wc || !address || !pub) throw new Error("Wallet not connected");
    const isPaused = await pub.readContract({ address: ADDRESSES.MockCapitalPool as `0x${string}`, abi: MOCK_CAPITAL_POOL_ABI, functionName: "borrowingPaused" }) as boolean;
    if (isPaused) {
      log("info", "Resuming pool (guard served its purpose)…");
      await pub.waitForTransactionReceipt({ hash: await wc.writeContract({ address: ADDRESSES.MockCapitalPool as `0x${string}`, abi: MOCK_CAPITAL_POOL_ABI, functionName: "resumeBorrowing" }) });
    }
    const total = BORROW_AMT + INTEREST_AMT;
    log("info", `Minting ${formatUnits(total, 6)} USDC (principal + 5% interest)…`);
    await pub.waitForTransactionReceipt({ hash: await wc.writeContract({ address: ADDRESSES.MockUSDC as `0x${string}`, abi: ERC20_ABI, functionName: "mint", args: [address, total] }) });
    await pub.waitForTransactionReceipt({ hash: await wc.writeContract({ address: ADDRESSES.MockUSDC as `0x${string}`, abi: ERC20_ABI, functionName: "approve", args: [ADDRESSES.MockCapitalPool as `0x${string}`, total] }) });
    const repayH = await wc.writeContract({ address: ADDRESSES.MockCapitalPool as `0x${string}`, abi: MOCK_CAPITAL_POOL_ABI, functionName: "repay", args: [BOT_ID, BORROW_AMT, INTEREST_AMT] });
    await pub.waitForTransactionReceipt({ hash: repayH });
    log("success", `Loan repaid: 45,000 principal + 2,250 interest. tx ${repayH.slice(0,10)}…`);
    log("info", "80% of interest (1,800 USDC) → lenders via yield accumulator");
    await refreshStats();
    const yp = await pub.readContract({ address: ADDRESSES.MockCapitalPool as `0x${string}`, abi: MOCK_CAPITAL_POOL_ABI, functionName: "pendingYield", args: [address] }) as bigint;
    if (yp > 0n) {
      log("info", `Claiming ${formatUnits(yp, 6)} USDC yield…`);
      const claimH = await wc.writeContract({ address: ADDRESSES.MockCapitalPool as `0x${string}`, abi: MOCK_CAPITAL_POOL_ABI, functionName: "claimYield" });
      await pub.waitForTransactionReceipt({ hash: claimH });
      log("success", `${formatUnits(yp, 6)} USDC yield claimed to lender wallet. tx ${claimH.slice(0,10)}…`);
    }
    log("info", "Pool fully liquid — ready for next cycle.");
  }), [wc, address, pub, log, withBusy, refreshStats]);

  const reset = useCallback(() => {
    setDone(new Set()); setBusy(null); setLogs([]); setSigStep(-1);
    setStats(null); setYield(0n); setEnvHash(""); setLockedPolicy(null); setSelectedPreset(PRESETS[3]);
  }, []);

  const allDone = (["fund","verify","borrow","policy","guard","repay"] as StepKey[]).every(k => done.has(k));
  const guardBps = lockedPolicy?.guardBps ?? selectedPreset.guardBps;

  return (
    <div className="max-w-7xl mx-auto w-full px-6 py-6 space-y-6">

      {/* Header */}
      <div className="rounded-2xl border border-zinc-800 bg-zinc-900/60 p-6">
        <div className="flex items-start justify-between gap-4 flex-wrap">
          <div>
            <div className="flex items-center gap-3 mb-2">
              <span className="text-3xl">🏦</span>
              <div>
                <h1 className="text-2xl font-bold text-zinc-100">Capital Provider</h1>
                <p className="text-sm text-zinc-400">Institutional lender perspective — fund, define policy, protect, earn</p>
              </div>
            </div>
            <p className="text-sm text-zinc-400 max-w-2xl leading-relaxed">
              Fund a lending pool, define your exact risk policy, then pre-commit it as a cryptographic
              Atlas Envelope. Your rules execute permissionlessly — no governance vote, no multisig,
              no ops team required at any point.
            </p>
          </div>
          <div className="flex flex-col items-end gap-2">
            <span className="text-xs px-3 py-1.5 rounded-full bg-indigo-900/50 border border-indigo-700 text-indigo-300 font-medium">Lender POV</span>
            <span className="text-xs text-zinc-600">UtilisationOracle · PoolPauseAdapter · Real Envelope</span>
          </div>
        </div>
        <FlowDiagram nodes={[
          { condition: "Fund pool",              action: "Define risk policy",     result: "Rules pre-committed",      tone: "safe"    },
          { condition: "Borrower ZK-verified",   action: "Tier auto-assigned",     result: "Credit limit set",         tone: "neutral" },
          { condition: "Utilisation ≥ guard",    action: "Keeper fires envelope",  result: "Pool auto-paused",         tone: "warn"    },
          { condition: "Loan repaid + interest", action: "Yield distributed",      result: "Lender claims USDC",       tone: "safe"    },
        ]} />
      </div>

      {/* Live pool stats */}
      <div className="rounded-2xl border border-zinc-700/60 bg-zinc-900/40 p-5 space-y-4">
        <div className="flex items-center justify-between flex-wrap gap-2">
          <span className="text-sm font-semibold text-zinc-300">Live Pool Stats</span>
          <div className="flex items-center gap-3 flex-wrap">
            {stats?.paused && <span className="text-xs px-2 py-1 rounded-full bg-red-900/60 border border-red-700 text-red-300 font-medium animate-pulse">🛑 Paused by Keeper</span>}
            {envelopeHash && <span className="text-xs px-2 py-1 rounded-full bg-indigo-900/40 border border-indigo-800 text-indigo-400">⛓️ Guard active</span>}
            <span className="text-xs text-zinc-600">auto-refresh 3s</span>
          </div>
        </div>
        <div className="grid grid-cols-2 sm:grid-cols-4 gap-3">
          <StatPill label="Total Capital"  value={stats ? `$${Number(formatUnits(stats.totalCapital, 6)).toLocaleString()}`  : "$0"} sub="USDC committed" />
          <StatPill label="Active Loans"   value={stats ? `$${Number(formatUnits(stats.totalBorrowed,6)).toLocaleString()}`  : "$0"} sub="outstanding" />
          <StatPill label="Available"      value={stats ? `$${Number(formatUnits(stats.available,    6)).toLocaleString()}`  : "$0"} sub="ready to lend" />
          <StatPill label="Yield Earned"   value={stats ? `$${Number(formatUnits(stats.yieldEarned,  6)).toLocaleString()}`  : "$0"}
            sub={yieldPending > 0n ? `${formatUnits(yieldPending,6)} claimable` : "accrued"}
            highlight={yieldPending > 0n} />
        </div>
        <div className="space-y-1">
          <div className="flex justify-between text-xs text-zinc-500">
            <span>Utilisation</span>
            <span className={stats && Number(stats.utilizationBps) >= guardBps ? "text-amber-400 font-medium" : "text-emerald-400"}>
              {stats ? `${(Number(stats.utilizationBps)/100).toFixed(1)}%` : "0.0%"}
              {stats && Number(stats.utilizationBps) >= guardBps && " — above guard"}
            </span>
          </div>
          <UtilBar bps={stats?.utilizationBps ?? 0n} guardBps={guardBps} />
          <div className="text-xs text-zinc-600 flex justify-between">
            <span>0%</span>
            <span className="text-amber-500/70">⚠ Guard: {guardBps/100}%</span>
            <span>100%</span>
          </div>
        </div>
      </div>

      <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
        <div className="space-y-4">

          <StepCard index={0} title="Fund the Pool"
            description="Deposit 100,000 USDC as lending capital. Only ZK-verified borrowers can draw. Define your risk policy next before any borrowing begins."
            status={statusFor("fund", done, busy)}>
            <TxButton onClick={fundPool} loading={busy==="fund"} disabled={done.has("fund")||(busy!==null&&busy!=="fund")} variant="primary">
              {done.has("fund") ? "✓ 100,000 USDC deposited" : "Deposit 100,000 USDC"}
            </TxButton>
          </StepCard>

          {/* Step 2 — Risk Policy (immediately after deposit) */}
          <StepCard index={1} title="Define Risk Policy"
            description="Set your exact risk parameters right after funding — before any borrower is onboarded. The policy card shows precisely what gets locked on-chain. Immutable once signed in Step 5."
            status={statusFor("policy", done, busy)}>
            {!done.has("policy") && done.has("fund") && (
              <div className="space-y-4">
                <div className="grid grid-cols-2 gap-2">
                  {PRESETS.map(p => (
                    <button key={p.id} onClick={() => setSelectedPreset(p)}
                      className={`text-left px-3 py-2.5 rounded-xl border text-xs transition-all
                        ${selectedPreset.id === p.id
                          ? `${p.border} bg-zinc-800/80 ${p.color}`
                          : "border-zinc-700/50 bg-zinc-800/30 text-zinc-500 hover:text-zinc-300 hover:bg-zinc-800/60"
                        }`}>
                      <div className="font-semibold">{p.label}</div>
                      <div className={`mt-0.5 ${selectedPreset.id === p.id ? "opacity-80" : "text-zinc-600"}`}>{p.tag} · Guard {p.guardBps/100}%</div>
                    </button>
                  ))}
                </div>
                <PolicyCard policy={selectedPreset} />
                <p className="text-xs text-zinc-500 leading-relaxed">{selectedPreset.description}</p>
                <TxButton onClick={lockPolicy} loading={busy==="policy"} disabled={busy!==null&&busy!=="policy"} variant="primary">
                  Lock In "{selectedPreset.label}" Policy
                </TxButton>
              </div>
            )}
            {done.has("policy") && lockedPolicy && (
              <div className="space-y-3">
                <span className={`inline-flex items-center gap-2 px-3 py-1.5 rounded-full border text-xs font-medium ${lockedPolicy.color} ${lockedPolicy.border} bg-zinc-800/50`}>
                  ✓ {lockedPolicy.label} policy locked
                </span>
                <PolicyCard policy={lockedPolicy} />
              </div>
            )}
          </StepCard>

          <StepCard index={2} title="Verify Borrower Credit Tier"
            description="Borrower presents ZK Credit Passport (grade 2). CreditVerifier checks proof and assigns Tier 2 — within the limits set by your policy. No identity exposed."
            status={statusFor("verify", done, busy)}>
            <TxButton onClick={verifyBorrower} loading={busy==="verify"} disabled={!done.has("policy")||done.has("verify")||(busy!==null&&busy!=="verify")} variant="secondary">
              {done.has("verify") ? "✓ Tier 2 assigned" : "Verify ZK Proof → Assign Tier"}
            </TxButton>
          </StepCard>

          <StepCard index={3} title="Agent Draws Loan"
            description="Bot #99 draws 45,000 USDC against Tier 2 limit. Utilisation rises to 45%. Your policy from Step 2 determines whether the guard envelope fires."
            status={statusFor("borrow", done, busy)}>
            <TxButton onClick={simulateBorrow} loading={busy==="borrow"} disabled={!done.has("verify")||done.has("borrow")||(busy!==null&&busy!=="borrow")} variant="secondary">
              {done.has("borrow") ? "✓ 45,000 USDC drawn (45% util)" : "Agent Draws 45,000 USDC"}
            </TxButton>
          </StepCard>

          {/* Step 5 — Register envelope */}
          <StepCard index={4} title="Register Guard Envelope"
            description="Sign 3 EIP-712 messages and register the Atlas Envelope on-chain. The keeper reads UtilisationOracle at trigger time — if utilisation ≥ your threshold, PoolPauseAdapter fires."
            status={statusFor("guard", done, busy)}>
            {busy === "guard" && sigStep >= 0 && (
              <div className="mb-4"><SigningProgress steps={SIG_STEPS} currentIndex={sigStep} /></div>
            )}
            {done.has("policy") && !done.has("guard") && lockedPolicy && (
              <div className="mb-3 rounded-lg border border-zinc-700/50 bg-zinc-800/40 px-3 py-2.5 text-xs space-y-1">
                <p className="text-zinc-400 font-medium">Envelope will encode:</p>
                <p className="text-zinc-500">Condition: <span className="text-amber-300">UtilisationOracle &gt; {lockedPolicy.guardBps - 1} bps (≥ {lockedPolicy.guardBps/100}%)</span></p>
                <p className="text-zinc-500">Action: <span className="text-indigo-300">PoolPauseAdapter → pool.pauseBorrowing()</span></p>
                <p className="text-zinc-500">Executor: <span className="text-zinc-300">Any Atlas keeper — permissionless</span></p>
              </div>
            )}
            <TxButton onClick={registerGuard} loading={busy==="guard"} disabled={!done.has("borrow")||done.has("guard")||(busy!==null&&busy!=="guard")} variant="danger">
              {done.has("guard") ? "✓ Guard fired via real envelope" : "Sign & Register Guard Envelope"}
            </TxButton>
          </StepCard>

          {/* Step 6 */}
          <StepCard index={5} title="Repayment & Yield Claim"
            description="Bot repays 45,000 USDC + 2,250 USDC interest. 80% of interest → lenders via on-chain yield accumulator. Lender claims pro-rata share directly to wallet."
            status={statusFor("repay", done, busy)}>
            <TxButton onClick={repayAndClaim} loading={busy==="repay"} disabled={!done.has("guard")||done.has("repay")||(busy!==null&&busy!=="repay")} variant="keeper">
              {done.has("repay") ? "✓ Yield claimed" : "Repay Loan + Claim Yield"}
            </TxButton>
          </StepCard>

          {allDone && (
            <div className="rounded-2xl border border-emerald-700/60 bg-emerald-950/30 p-4 flex items-start gap-3">
              <span className="text-2xl">🎉</span>
              <div>
                <p className="font-semibold text-emerald-300 text-sm">Full lender cycle complete</p>
                <p className="text-xs text-zinc-400 mt-1 leading-relaxed">
                  Capital deployed → ZK-verified → loan issued → policy defined → envelope enforced → repaid → yield claimed. No trusted operator at any step.
                </p>
                <button onClick={reset} className="mt-3 text-xs text-zinc-500 hover:text-zinc-300 underline">Reset demo</button>
              </div>
            </div>
          )}
        </div>

        <div className="space-y-4">
          <LogPanel entries={logs} />

          <div className="rounded-2xl border border-zinc-700/60 bg-zinc-900/40 p-4 space-y-3">
            <p className="text-xs font-semibold text-zinc-400 uppercase tracking-wider">Why This Beats Existing DeFi Risk Management</p>
            <div className="space-y-3">
              {[
                { icon: "⚡", title: "No governance delay",       desc: "Aave risk changes take 48–72hr through DAO + timelock. Atlas: condition fires in the same block it's met." },
                { icon: "🔒", title: "Lender sovereignty",        desc: "Your policy is signed by your key. The protocol team cannot modify, delay, or override it." },
                { icon: "🌐", title: "Permissionless execution",  desc: "Any keeper worldwide can trigger. No single point of failure, no ops team going offline at 2am." },
                { icon: "🔐", title: "ZK credit gating",          desc: "Borrower quality verified cryptographically — no trusted analyst, no doxxing." },
                { icon: "💰", title: "Trustless yield",           desc: "yieldPerShareScaled is pure arithmetic. You don't trust the protocol to calculate your share." },
              ].map(({ icon, title, desc }) => (
                <div key={title} className="flex gap-3 items-start">
                  <span className="text-base mt-0.5 shrink-0">{icon}</span>
                  <div>
                    <p className="text-xs font-semibold text-zinc-300">{title}</p>
                    <p className="text-xs text-zinc-500 leading-relaxed">{desc}</p>
                  </div>
                </div>
              ))}
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
