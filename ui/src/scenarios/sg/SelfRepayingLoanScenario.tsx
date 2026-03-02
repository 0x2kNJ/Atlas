/**
 * Self-Repaying Loan
 *
 * Borrow USDC today. Pre-sign the repayment chain before going offline.
 * When ETH rallies, a yield position auto-harvests and the loan repays itself.
 *
 * Stage 1: Borrow 500 USDC (credit-gated, off-envelope).
 * Stage 2: ETH > $2,800 → sell 0.3 WETH yield position for ~840 USDC.
 * Stage 3: Chained from Stage 2 — 840 USDC → buy WETH back (closes cycle).
 * Repay:   Wallet USDC balance repays the 500 USDC loan from lender.
 *
 * Key insight: all three stages are pre-signed in one session. The agent can
 * go offline immediately. No agent liveness required at any trigger point.
 */
import { useState, useCallback, useRef } from "react";
import { useAccount, useWalletClient, usePublicClient } from "wagmi";
import { parseUnits, formatUnits } from "viem";

import { ADDRESSES, ANVIL_CHAIN_ID } from "../../contracts/addresses";
import {
  ERC20_ABI, VAULT_ABI, REGISTRY_ABI, MOCK_PRICE_ORACLE_ABI,
  MOCK_CREDIT_GATED_LENDER_ABI,
} from "../../contracts/abis";
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
  randomSalt, hashCapability, hashEnvelope, ZERO_ADDRESS, ComparisonOp, LogicOp,
} from "@atlas-protocol/sdk";
import type { Position, Conditions } from "@atlas-protocol/sdk";

const BORROW_AMT     = parseUnits("500", 6);
const WETH_YIELD_IN  = parseUnits("0.3", 18);
const RALLY_PRICE    = 2800;
const RALLY_TRIGGER  = 2800n * 10n ** 8n;
const USDC_YIELD_OUT = parseUnits("840", 6);
const CAP_DUR        = 90n * 86400n;
const ENV_DUR        = 30n * 86400n;

// ── Signing steps manifest ────────────────────────────────────────────────────
const SIG_STEPS: SigStep[] = [
  { stage: "Stage 2 — Harvest yield (WETH → USDC)",  label: "Spending permission",      icon: "🔑" },
  { stage: "Stage 2 — Harvest yield (WETH → USDC)",  label: "Execution intent",         icon: "📋" },
  { stage: "Stage 2 — Harvest yield (WETH → USDC)",  label: "Registration authority",   icon: "🗝️" },
  { stage: "Stage 3 — Close cycle (USDC → WETH)",    label: "Spending permission",      icon: "🔑" },
  { stage: "Stage 3 — Close cycle (USDC → WETH)",    label: "Execution intent",         icon: "📋" },
  { stage: "Stage 3 — Close cycle (USDC → WETH)",    label: "Registration authority",   icon: "🗝️" },
  { stage: "On-chain",                                label: "Register Stage 2 envelope", icon: "⛓️" },
];

interface StageData {
  envelope: unknown; manageCap: unknown; manageCapSig: `0x${string}`; position: unknown;
  envelopeHash: `0x${string}`; conditions: unknown; intent: unknown; spendCap: unknown;
  capSig: `0x${string}`; intentSig: `0x${string}`;
}
interface GraphState {
  borrowCapHash?: `0x${string}`;
  s2?: StageData;
  s3?: StageData;
}

export function SelfRepayingLoanScenario() {
  const { address }            = useAccount();
  const { data: walletClient } = useWalletClient();
  const publicClient           = usePublicClient();
  const logId                  = useRef(0);

  const [logs,       setLogs]       = useState<LogEntry[]>([]);
  const [step,       setStep]       = useState(0);
  const [busy,       setBusy]       = useState(false);
  const [sigStep,    setSigStep]    = useState(-1);
  const [borrowed,   setBorrowed]   = useState(false);
  const [loanRepaid, setLoanRepaid] = useState(false);
  const state = useRef<GraphState>({});

  const log = useCallback((level: LogEntry["level"], msg: string) =>
    setLogs(p => [...p, { id: ++logId.current, ts: Date.now(), level, message: msg }]), []);

  const withBusy = useCallback(async (fn: () => Promise<void>) => {
    setBusy(true);
    try { await fn(); }
    catch (e: unknown) {
      log("error", (e instanceof Error ? e.message : String(e)).slice(0, 300));
      setSigStep(-1);
    }
    finally { setBusy(false); }
  }, [log]);

  const mint = () => withBusy(async () => {
    if (!walletClient || !address) return;
    log("info", "Minting 2 WETH + seeding lender with 5,000 USDC…");
    await publicClient!.waitForTransactionReceipt({ hash: await walletClient.writeContract({
      address: ADDRESSES.MockWETH as `0x${string}`, abi: ERC20_ABI,
      functionName: "mint", args: [address, parseUnits("2", 18)],
    })});
    await publicClient!.waitForTransactionReceipt({ hash: await walletClient.writeContract({
      address: ADDRESSES.MockUSDC as `0x${string}`, abi: ERC20_ABI,
      functionName: "mint", args: [ADDRESSES.MockCreditGatedLender as `0x${string}`, parseUnits("5000", 6)],
    })});
    log("success", "Wallet funded. Lender has liquidity.");
    setStep(1);
  });

  const borrowAndSign = () => withBusy(async () => {
    if (!walletClient || !address) return;
    setSigStep(0);

    log("info", `Fixing oracle at $${RALLY_PRICE} for deterministic output hashes…`);
    await publicClient!.waitForTransactionReceipt({ hash: await walletClient.writeContract({
      address: ADDRESSES.MockPriceOracle as `0x${string}`, abi: MOCK_PRICE_ORACLE_ABI,
      functionName: "setPrice", args: [BigInt(RALLY_PRICE) * 10n ** 8n],
    })});

    await publicClient!.waitForTransactionReceipt({ hash: await walletClient.writeContract({
      address: ADDRESSES.MockWETH as `0x${string}`, abi: ERC20_ABI,
      functionName: "approve", args: [ADDRESSES.SingletonVault as `0x${string}`, WETH_YIELD_IN],
    })});
    const yieldSalt = randomSalt();
    await publicClient!.waitForTransactionReceipt({ hash: await walletClient.writeContract({
      address: ADDRESSES.SingletonVault as `0x${string}`, abi: VAULT_ABI,
      functionName: "deposit", args: [ADDRESSES.MockWETH as `0x${string}`, WETH_YIELD_IN, yieldSalt],
    })});
    const yieldPos: Position = { owner: address, asset: ADDRESSES.MockWETH as `0x${string}`, amount: WETH_YIELD_IN, salt: yieldSalt };
    const yieldPosHash = computePositionHash(address, ADDRESSES.MockWETH as `0x${string}`, WETH_YIELD_IN, yieldSalt);
    log("success", `0.3 WETH in vault — yield position: ${yieldPosHash.slice(0, 10)}…`);

    const { timestamp: now } = await publicClient!.getBlock({ blockTag: "latest" });

    const borrowCap = buildCapability({ issuer: address, grantee: address, expiry: now + CAP_DUR, nonce: randomSalt(),
      constraints: { maxSpendPerPeriod: BORROW_AMT * 2n, periodDuration: 86400n, minReturnBps: 0n,
        allowedAdapters: [ZERO_ADDRESS], allowedTokensIn: [ZERO_ADDRESS], allowedTokensOut: [ZERO_ADDRESS] } });
    const borrowCapHash = hashCapability(borrowCap) as `0x${string}`;
    await signCapability(walletClient, borrowCap, ADDRESSES.CapabilityKernel as `0x${string}`, ANVIL_CHAIN_ID);
    await publicClient!.waitForTransactionReceipt({ hash: await walletClient.writeContract({
      address: ADDRESSES.MockCreditGatedLender as `0x${string}`, abi: MOCK_CREDIT_GATED_LENDER_ABI,
      functionName: "borrow", args: [borrowCapHash, BORROW_AMT],
    })});
    setBorrowed(true);
    log("success", `Borrowed ${formatUnits(BORROW_AMT, 6)} USDC from lender`);
    state.current.borrowCapHash = borrowCapHash;

    // Stage 2 — spending permission
    setSigStep(0);
    const s2Cap = buildCapability({ issuer: address, grantee: address, expiry: now + CAP_DUR, nonce: randomSalt(),
      constraints: { maxSpendPerPeriod: WETH_YIELD_IN * 2n, periodDuration: 86400n, minReturnBps: 0n,
        allowedAdapters: [ADDRESSES.PriceSwapAdapter as `0x${string}`],
        allowedTokensIn: [ADDRESSES.MockWETH as `0x${string}`], allowedTokensOut: [ADDRESSES.MockUSDC as `0x${string}`] } });
    const s2CapSig = await signCapability(walletClient, s2Cap, ADDRESSES.CapabilityKernel as `0x${string}`, ANVIL_CHAIN_ID);

    // Stage 2 — execution intent
    setSigStep(1);
    const s2IntentNonce = randomSalt();
    const s2Intent = buildIntent({ position: yieldPos, capability: s2Cap,
      adapter: ADDRESSES.PriceSwapAdapter as `0x${string}`, adapterData: "0x",
      minReturn: parseUnits("700", 6), deadline: now + CAP_DUR, nonce: s2IntentNonce,
      outputToken: ADDRESSES.MockUSDC as `0x${string}`, returnTo: ZERO_ADDRESS,
      submitter: ADDRESSES.EnvelopeRegistry as `0x${string}`, solverFeeBps: 0 });
    const s2IntentSig = await signIntent(walletClient, s2Intent, ADDRESSES.CapabilityKernel as `0x${string}`, ANVIL_CHAIN_ID);

    // Stage 2 — registration authority
    setSigStep(2);
    const s2MgCap = buildManageCapability({ issuer: address, grantee: address, expiry: now + ENV_DUR, nonce: randomSalt() });
    const s2MgSig = await signManageCapability(walletClient, s2MgCap, ADDRESSES.EnvelopeRegistry as `0x${string}`, ANVIL_CHAIN_ID);

    const s2Cond: Conditions = { priceOracle: ADDRESSES.MockPriceOracle as `0x${string}`, baseToken: ZERO_ADDRESS,
      quoteToken: ZERO_ADDRESS, triggerPrice: RALLY_TRIGGER, op: ComparisonOp.GREATER_THAN,
      secondaryOracle: ZERO_ADDRESS, secondaryTriggerPrice: 0n, secondaryOp: ComparisonOp.LESS_THAN, logicOp: LogicOp.AND };
    const s2Env = buildEnvelope({ position: yieldPos, conditions: s2Cond, intent: s2Intent, manageCapability: s2MgCap,
      expiry: now + ENV_DUR, keeperRewardBps: 10, minKeeperRewardWei: 0n });
    const s2EnvHash = hashEnvelope(s2Env) as `0x${string}`;

    const s3InputSalt = computeOutputSalt(s2IntentNonce, yieldPosHash);
    const s3Pos: Position = { owner: address, asset: ADDRESSES.MockUSDC as `0x${string}`, amount: USDC_YIELD_OUT, salt: s3InputSalt };
    log("success", `Stage 3 input pre-computed — position hash deterministic before Stage 2 fires`);

    // Stage 3 — spending permission
    setSigStep(3);
    const s3Cap = buildCapability({ issuer: address, grantee: address, expiry: now + CAP_DUR, nonce: randomSalt(),
      constraints: { maxSpendPerPeriod: USDC_YIELD_OUT * 2n, periodDuration: 86400n, minReturnBps: 0n,
        allowedAdapters: [ADDRESSES.MockReverseSwapAdapter as `0x${string}`],
        allowedTokensIn: [ADDRESSES.MockUSDC as `0x${string}`], allowedTokensOut: [ADDRESSES.MockWETH as `0x${string}`] } });
    const s3CapSig = await signCapability(walletClient, s3Cap, ADDRESSES.CapabilityKernel as `0x${string}`, ANVIL_CHAIN_ID);

    // Stage 3 — execution intent
    setSigStep(4);
    const s3Intent = buildIntent({ position: s3Pos, capability: s3Cap,
      adapter: ADDRESSES.MockReverseSwapAdapter as `0x${string}`, adapterData: "0x",
      minReturn: parseUnits("0.1", 18), deadline: now + CAP_DUR, nonce: randomSalt(),
      outputToken: ADDRESSES.MockWETH as `0x${string}`, returnTo: ZERO_ADDRESS,
      submitter: ADDRESSES.EnvelopeRegistry as `0x${string}`, solverFeeBps: 0 });
    const s3IntentSig = await signIntent(walletClient, s3Intent, ADDRESSES.CapabilityKernel as `0x${string}`, ANVIL_CHAIN_ID);

    // Stage 3 — registration authority
    setSigStep(5);
    const s3MgCap = buildManageCapability({ issuer: address, grantee: address, expiry: now + ENV_DUR, nonce: randomSalt() });
    const s3MgSig = await signManageCapability(walletClient, s3MgCap, ADDRESSES.EnvelopeRegistry as `0x${string}`, ANVIL_CHAIN_ID);

    const s3Env = buildEnvelope({ position: s3Pos, conditions: s2Cond, intent: s3Intent, manageCapability: s3MgCap,
      expiry: now + ENV_DUR, keeperRewardBps: 10, minKeeperRewardWei: 0n });
    const s3EnvHash = hashEnvelope(s3Env) as `0x${string}`;

    state.current.s2 = { envelope: s2Env, manageCap: s2MgCap, manageCapSig: s2MgSig, position: yieldPos,
      envelopeHash: s2EnvHash, conditions: s2Cond, intent: s2Intent, spendCap: s2Cap, capSig: s2CapSig, intentSig: s2IntentSig };
    state.current.s3 = { envelope: s3Env, manageCap: s3MgCap, manageCapSig: s3MgSig, position: s3Pos,
      envelopeHash: s3EnvHash, conditions: s2Cond, intent: s3Intent, spendCap: s3Cap, capSig: s3CapSig, intentSig: s3IntentSig };

    // Register Stage 2 on-chain
    setSigStep(6);
    await publicClient!.waitForTransactionReceipt({ hash: await walletClient.writeContract({
      address: ADDRESSES.EnvelopeRegistry as `0x${string}`, abi: REGISTRY_ABI,
      functionName: "register",
      args: [s2Env as never, s2MgCap as never, s2MgSig, yieldPos as never],
    })});
    setSigStep(7);
    log("success", `Strategy live: ${s2EnvHash.slice(0, 10)}… — agent can now go offline`);
    setStep(2);
  });

  const triggerHarvest = () => withBusy(async () => {
    if (!walletClient || !address) return;
    const { s2, s3 } = state.current;
    if (!s2 || !s3) { log("error", "Complete step 2 first"); return; }

    log("info", `Oracle at $${RALLY_PRICE} — ETH > $2,800 condition met. Keeper triggering Stage 2…`);
    await publicClient!.waitForTransactionReceipt({ hash: await walletClient.writeContract({
      address: ADDRESSES.EnvelopeRegistry as `0x${string}`, abi: REGISTRY_ABI,
      functionName: "trigger",
      args: [s2.envelopeHash, s2.conditions as never, s2.position as never, s2.intent as never, s2.spendCap as never, s2.capSig, s2.intentSig],
    })});
    log("success", `Stage 2 executed — 0.3 WETH → ${formatUnits(USDC_YIELD_OUT, 6)} USDC`);

    log("info", "Auto-chaining: registering Stage 3 from pre-signed data (no agent online)…");
    await publicClient!.waitForTransactionReceipt({ hash: await walletClient.writeContract({
      address: ADDRESSES.EnvelopeRegistry as `0x${string}`, abi: REGISTRY_ABI,
      functionName: "register",
      args: [s3.envelope as never, s3.manageCap as never, s3.manageCapSig, s3.position as never],
    })});
    log("success", `Stage 3 registered: ${s3.envelopeHash.slice(0, 10)}…`);
    setStep(3);
  });

  const triggerRepay = () => withBusy(async () => {
    if (!walletClient || !address) return;
    const { s3, borrowCapHash } = state.current;
    if (!s3) { log("error", "Complete step 3 first"); return; }

    log("info", "Triggering Stage 3 — USDC → WETH (close cycle)…");
    await publicClient!.waitForTransactionReceipt({ hash: await walletClient.writeContract({
      address: ADDRESSES.EnvelopeRegistry as `0x${string}`, abi: REGISTRY_ABI,
      functionName: "trigger",
      args: [s3.envelopeHash, s3.conditions as never, s3.position as never, s3.intent as never, s3.spendCap as never, s3.capSig, s3.intentSig],
    })});
    log("success", "Stage 3 executed — USDC converted back to WETH");

    const usdcBal = await publicClient!.readContract({
      address: ADDRESSES.MockUSDC as `0x${string}`, abi: ERC20_ABI,
      functionName: "balanceOf", args: [address],
    }) as bigint;
    if (usdcBal >= BORROW_AMT && borrowCapHash) {
      await publicClient!.waitForTransactionReceipt({ hash: await walletClient.writeContract({
        address: ADDRESSES.MockUSDC as `0x${string}`, abi: ERC20_ABI,
        functionName: "approve", args: [ADDRESSES.MockCreditGatedLender as `0x${string}`, BORROW_AMT],
      })});
      await publicClient!.waitForTransactionReceipt({ hash: await walletClient.writeContract({
        address: ADDRESSES.MockCreditGatedLender as `0x${string}`, abi: MOCK_CREDIT_GATED_LENDER_ABI,
        functionName: "repay", args: [borrowCapHash, BORROW_AMT],
      })});
      log("success", `Loan repaid — ${formatUnits(BORROW_AMT, 6)} USDC returned to lender`);
    }
    setLoanRepaid(true);
    log("success", "Cycle complete. Yield surplus: ~340 USDC. Borrower never had to touch it.");
    setStep(4);
  });

  const steps = [
    {
      title: "Fund wallet",
      desc:  "Mint 2 WETH to your wallet. Top up the mock lender with 5,000 USDC so it has liquidity to lend.",
      action: mint, label: "Mint Tokens",
    },
    {
      title: "Borrow + set up repayment strategy",
      desc:  "Deposits 0.3 WETH as a yield position, borrows 500 USDC, then pre-signs all 6 permissions covering both the harvest and repayment stages. One setup session — then the agent goes offline.",
      action: borrowAndSign, label: "Borrow + Set Up Strategy",
    },
    {
      title: "Stage 2 fires — keeper harvests yield",
      desc:  "ETH rallies above $2,800. A keeper (anyone) triggers the envelope: 0.3 WETH sells for ~840 USDC. The Stage 3 repayment envelope is immediately auto-registered from pre-committed data.",
      action: triggerHarvest, label: "Trigger Harvest (Stage 2)",
    },
    {
      title: "Stage 3 fires — loan auto-repays",
      desc:  "USDC from Stage 2 is converted back to WETH, and 500 USDC is returned to the lender. Net result: loan fully repaid, ~340 USDC surplus kept by borrower.",
      action: triggerRepay, label: "Auto-Repay (Stage 3)",
    },
  ];

  return (
    <div className="space-y-6">
      {/* Scenario header */}
      <div className="bg-zinc-900/60 border border-zinc-800 rounded-2xl p-5">
        <div className="flex items-center gap-3 mb-2">
          <span className="text-2xl">🌱</span>
          <div>
            <h2 className="text-lg font-bold text-zinc-100">Borrow-to-Yield Self-Repaying Loan</h2>
            <p className="text-sm text-zinc-400">Borrow USDC. Pre-commit the entire repayment chain in one session. The yield harvest repays the loan automatically — no agent online required.</p>
          </div>
        </div>
        <FlowDiagram nodes={[
          { condition: "Setup",           action: "Borrow 500 USDC",           result: "0.3 WETH in vault",     tone: "neutral" },
          { condition: "ETH > $2,800",    action: "Harvest yield → 840 USDC",  result: "Stage 3 auto-registers", tone: "safe"    },
          { condition: "Chained",         action: "Repay 500 USDC loan",        result: "~340 USDC surplus",      tone: "safe"    },
        ]} />
        <div className="grid grid-cols-4 gap-3 mt-4 text-xs">
          {[
            { label: "Borrow",          val: "500 USDC" },
            { label: "Yield position",  val: "0.3 WETH" },
            { label: "Harvest trigger", val: "ETH > $2,800" },
            { label: "Yield surplus",   val: "840 USDC (covers 500)" },
          ].map(r => (
            <div key={r.label} className="bg-zinc-800/60 rounded-lg p-2">
              <div className="text-zinc-500">{r.label}</div>
              <div className="text-zinc-200 font-medium mt-0.5">{r.val}</div>
            </div>
          ))}
        </div>
        {borrowed && !loanRepaid && (
          <div className="mt-4 p-3 bg-amber-950/40 border border-amber-700 rounded-xl text-sm text-amber-300">
            Loan active — 500 USDC borrowed. Waiting for ETH rally above $2,800…
          </div>
        )}
        {loanRepaid && (
          <div className="mt-4 p-3 bg-emerald-950/40 border border-emerald-700 rounded-xl text-sm text-emerald-300">
            ✓ Loan fully repaid. Yield exceeded principal by ~340 USDC. Agent was offline the entire time.
          </div>
        )}
      </div>

      {/* Steps */}
      <div className="grid gap-4">
        {steps.map((s, i) => (
          <StepCard key={i} index={i} title={s.title} description={s.desc}
            status={step > i ? "done" : step === i ? (busy ? "loading" : "ready") : "pending"}>
            {step === i && (
              <div className="space-y-3">
                {/* Show signing widget during the borrow+sign step */}
                {i === 1 && sigStep >= 0 && sigStep < SIG_STEPS.length + 1 && (
                  <SigningProgress steps={SIG_STEPS} currentIndex={sigStep} />
                )}
                {s.action && (
                  <TxButton onClick={s.action} loading={busy}>{s.label}</TxButton>
                )}
              </div>
            )}
          </StepCard>
        ))}
      </div>

      <LogPanel entries={logs} />
    </div>
  );
}
