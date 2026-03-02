/**
 * Strategy Graph — Leveraged DCA That Pays for Itself
 *
 * An agent pre-commits a 4-stage leveraged DCA:
 *   Stage 1: Borrow 1,000 USDC from lender (off-envelope, credit-gated)
 *   Stage 2: ETH/USD < $1,600 → deploy borrowed USDC to buy WETH dip
 *            (USDC → WETH at $1,400 fixed price = 0.714 WETH per 1,000 USDC)
 *   Stage 3: ETH/USD > $2,400 → sell the WETH acquired in Stage 2 on recovery
 *            (WETH → USDC at $2,400 = 1,714 USDC from 0.714 WETH)
 *   Stage 4: Repay 1,000 USDC loan — keep 714 USDC profit
 *
 * Net: borrowed 1,000 USDC, returned 1,000 USDC, pocketed 714 USDC (71.4% return).
 * Stages 2-3-4 are a chain: each input = deterministic output of the previous.
 * The agent signs all stages BEFORE Step 1 fires. Capital and profit are pre-committed.
 */
import { useState, useCallback, useRef } from "react";
import { useAccount, useWalletClient, usePublicClient } from "wagmi";
import { parseUnits, formatUnits, formatEther } from "viem";

import { ADDRESSES, ANVIL_CHAIN_ID } from "../../contracts/addresses";
import {
  ERC20_ABI, VAULT_ABI, REGISTRY_ABI, MOCK_PRICE_ORACLE_ABI,
  MOCK_CREDIT_GATED_LENDER_ABI,
} from "../../contracts/abis";
import { LogPanel }  from "../../components/LogPanel";
import type { LogEntry } from "../../components/LogPanel";
import { StepCard }  from "../../components/StepCard";
import { TxButton }  from "../../components/TxButton";
import { computePositionHash, computeOutputSalt } from "../../utils/graphUtils";
import { SigningProgress } from "../../components/SigningProgress";
import type { SigStep }   from "../../components/SigningProgress";
import { FlowDiagram }    from "../../components/FlowDiagram";

const SIG_STEPS: SigStep[] = [
  { stage: "Stage 2 — Buy the dip (USDC → WETH at $1,400)", label: "Spending permission",    icon: "🔑" },
  { stage: "Stage 2 — Buy the dip (USDC → WETH at $1,400)", label: "Execution intent",       icon: "📋" },
  { stage: "Stage 2 — Buy the dip (USDC → WETH at $1,400)", label: "Registration authority", icon: "🗝️" },
  { stage: "Stage 3 — Sell recovery (WETH → USDC at $2,400)", label: "Spending permission",    icon: "🔑" },
  { stage: "Stage 3 — Sell recovery (WETH → USDC at $2,400)", label: "Execution intent",       icon: "📋" },
  { stage: "Stage 3 — Sell recovery (WETH → USDC at $2,400)", label: "Registration authority", icon: "🗝️" },
  { stage: "On-chain", label: "Register Stage 2 envelope", icon: "⛓️" },
];

import {
  buildCapability, buildManageCapability, buildIntent, buildEnvelope,
  signCapability, signIntent, signManageCapability,
  randomSalt, hashCapability, hashEnvelope, ZERO_ADDRESS, ComparisonOp, LogicOp,
} from "@atlas-protocol/sdk";
import type { Position, Conditions } from "@atlas-protocol/sdk";

const BORROW_AMT      = parseUnits("1000", 6);   // 1,000 USDC borrowed
const BUY_PRICE       = 1400;                     // buy WETH at $1,400
const SELL_PRICE      = 2400;                     // sell WETH at $2,400
const BUY_TRIGGER     = 1600n * 10n ** 8n;        // Stage 2: ETH < $1,600
const SELL_TRIGGER    = 2400n * 10n ** 8n;        // Stage 3: ETH > $2,400
// At $1,400: 1000e6 * 1e20 / 1400e8 ≈ 0.714e18 WETH
const WETH_DIP        = parseUnits("0.714", 18);
// At $2,400: 0.714e18 * 2400e8 / 1e20 ≈ 1714e6 USDC
const USDC_RECOVERY   = parseUnits("1714", 6);
const CAP_DUR         = 90n * 86400n;
const ENV_DUR         = 30n * 86400n;

interface GraphState {
  borrowCapHash?: `0x${string}`;
  s2EnvHash?: `0x${string}`; s2Env?: unknown; s2Cap?: unknown; s2Intent?: unknown;
  s2MgCap?: unknown; s2CapSig?: `0x${string}`; s2IntentSig?: `0x${string}`; s2MgSig?: `0x${string}`;
  s2Pos?: unknown; s2Cond?: unknown;
  s3EnvHash?: `0x${string}`; s3Env?: unknown; s3Cap?: unknown; s3Intent?: unknown;
  s3MgCap?: unknown; s3CapSig?: `0x${string}`; s3IntentSig?: `0x${string}`; s3MgSig?: `0x${string}`;
  s3Pos?: unknown; s3Cond?: unknown;
}

export function LeveragedDCAScenario() {
  const { address }            = useAccount();
  const { data: walletClient } = useWalletClient();
  const publicClient           = usePublicClient();
  const logId                  = useRef(0);

  const [logs,       setLogs]       = useState<LogEntry[]>([]);
  const [step,       setStep]       = useState(0);
  const [busy,       setBusy]       = useState(false);
  const [sigStep,    setSigStep]    = useState(-1);
  const [borrowed,   setBorrowed]   = useState(false);
  const [dipBought,  setDipBought]  = useState(false);
  const [recovered,  setRecovered]  = useState(false);
  const [profit,     setProfit]     = useState(0n);
  const state = useRef<GraphState>({});

  const log = useCallback((level: LogEntry["level"], msg: string) =>
    setLogs(p => [...p, { id: ++logId.current, ts: Date.now(), level, message: msg }]), []);

  const withBusy = useCallback(async (fn: () => Promise<void>) => {
    setBusy(true);
    try { await fn(); }
    catch (e: unknown) { log("error", (e instanceof Error ? e.message : String(e)).slice(0, 300)); }
    finally { setBusy(false); }
  }, [log]);

  // Step 0 — Seed lender, borrow, sign entire chain
  const setupAndBorrow = () => withBusy(async () => {
    if (!walletClient || !address) return;

    log("info", "Seeding lender with 5,000 USDC…");
    await publicClient!.waitForTransactionReceipt({ hash: await walletClient.writeContract({
      address: ADDRESSES.MockUSDC as `0x${string}`, abi: ERC20_ABI,
      functionName: "mint", args: [ADDRESSES.MockCreditGatedLender as `0x${string}`, parseUnits("5000", 6)],
    })});

    // Fix buy price for deterministic Stage 2 → Stage 3 chain
    log("info", `Fixing oracle at $${BUY_PRICE} for deterministic chaining…`);
    await publicClient!.waitForTransactionReceipt({ hash: await walletClient.writeContract({
      address: ADDRESSES.MockPriceOracle as `0x${string}`, abi: MOCK_PRICE_ORACLE_ABI,
      functionName: "setPrice", args: [BigInt(BUY_PRICE) * 10n ** 8n],
    })});

    const { timestamp: now } = await publicClient!.getBlock({ blockTag: "latest" });

    // Build borrow capability (used as credit proof)
    const borrowCap = buildCapability({ issuer: address, grantee: address, expiry: now + CAP_DUR, nonce: randomSalt(),
      constraints: { maxSpendPerPeriod: BORROW_AMT, periodDuration: 86400n, minReturnBps: 0n,
        allowedAdapters: [ZERO_ADDRESS], allowedTokensIn: [ZERO_ADDRESS], allowedTokensOut: [ZERO_ADDRESS] } });
    const borrowCapHash = hashCapability(borrowCap) as `0x${string}`;
    await signCapability(walletClient, borrowCap, ADDRESSES.CapabilityKernel as `0x${string}`, ANVIL_CHAIN_ID);

    // Borrow USDC
    log("info", `Borrowing ${Number(BORROW_AMT) / 1e6} USDC from lender…`);
    await publicClient!.waitForTransactionReceipt({ hash: await walletClient.writeContract({
      address: ADDRESSES.MockCreditGatedLender as `0x${string}`, abi: MOCK_CREDIT_GATED_LENDER_ABI,
      functionName: "borrow", args: [borrowCapHash, BORROW_AMT],
    })});
    setBorrowed(true);
    log("success", "1,000 USDC borrowed — now pre-signing entire DCA chain…");
    state.current.borrowCapHash = borrowCapHash;

    // Deposit borrowed USDC into vault (becomes Stage 2 input)
    await publicClient!.waitForTransactionReceipt({ hash: await walletClient.writeContract({
      address: ADDRESSES.MockUSDC as `0x${string}`, abi: ERC20_ABI,
      functionName: "approve", args: [ADDRESSES.SingletonVault as `0x${string}`, BORROW_AMT],
    })});
    const s2Salt = randomSalt();
    await publicClient!.waitForTransactionReceipt({ hash: await walletClient.writeContract({
      address: ADDRESSES.SingletonVault as `0x${string}`, abi: VAULT_ABI,
      functionName: "deposit", args: [ADDRESSES.MockUSDC as `0x${string}`, BORROW_AMT, s2Salt],
    })});
    const s2Pos: Position = { owner: address, asset: ADDRESSES.MockUSDC as `0x${string}`, amount: BORROW_AMT, salt: s2Salt };
    const s2PosHash = computePositionHash(address, ADDRESSES.MockUSDC as `0x${string}`, BORROW_AMT, s2Salt);
    log("success", `Borrowed USDC deposited: ${s2PosHash.slice(0, 10)}…`);

    // ── Sign Stage 2: USDC → WETH (buy the dip) ─────────────────────────────
    log("info", "Signing Stage 2 (buy the dip: USDC→WETH when ETH < $1,600)…");
    setSigStep(0);
    const s2Cap = buildCapability({ issuer: address, grantee: address, expiry: now + CAP_DUR, nonce: randomSalt(),
      constraints: { maxSpendPerPeriod: BORROW_AMT * 2n, periodDuration: 86400n, minReturnBps: 0n,
        allowedAdapters: [ADDRESSES.MockReverseSwapAdapter as `0x${string}`],
        allowedTokensIn: [ADDRESSES.MockUSDC as `0x${string}`], allowedTokensOut: [ADDRESSES.MockWETH as `0x${string}`] } });
    const s2CapSig = await signCapability(walletClient, s2Cap, ADDRESSES.CapabilityKernel as `0x${string}`, ANVIL_CHAIN_ID);

    setSigStep(1);
    const s2IntentNonce = randomSalt();
    const s2Intent = buildIntent({ position: s2Pos, capability: s2Cap,
      adapter: ADDRESSES.MockReverseSwapAdapter as `0x${string}`, adapterData: "0x",
      minReturn: parseUnits("0.5", 18), deadline: now + CAP_DUR, nonce: s2IntentNonce,
      outputToken: ADDRESSES.MockWETH as `0x${string}`, returnTo: ZERO_ADDRESS,
      submitter: ADDRESSES.EnvelopeRegistry as `0x${string}`, solverFeeBps: 0 });
    const s2IntentSig = await signIntent(walletClient, s2Intent, ADDRESSES.CapabilityKernel as `0x${string}`, ANVIL_CHAIN_ID);

    setSigStep(2);
    const s2MgCap = buildManageCapability({ issuer: address, grantee: address, expiry: now + ENV_DUR, nonce: randomSalt() });
    const s2MgSig = await signManageCapability(walletClient, s2MgCap, ADDRESSES.EnvelopeRegistry as `0x${string}`, ANVIL_CHAIN_ID);

    const s2Cond: Conditions = { priceOracle: ADDRESSES.MockPriceOracle as `0x${string}`, baseToken: ZERO_ADDRESS,
      quoteToken: ZERO_ADDRESS, triggerPrice: BUY_TRIGGER, op: ComparisonOp.LESS_THAN,
      secondaryOracle: ZERO_ADDRESS, secondaryTriggerPrice: 0n, secondaryOp: ComparisonOp.LESS_THAN, logicOp: LogicOp.AND };
    const s2Env = buildEnvelope({ position: s2Pos, conditions: s2Cond, intent: s2Intent, manageCapability: s2MgCap,
      expiry: now + ENV_DUR, keeperRewardBps: 10, minKeeperRewardWei: 0n });
    const s2EnvHash = hashEnvelope(s2Env) as `0x${string}`;

    // Pre-compute Stage 3 input (WETH output of Stage 2)
    const s3InputSalt = computeOutputSalt(s2IntentNonce, s2PosHash);
    const s3Pos: Position = { owner: address, asset: ADDRESSES.MockWETH as `0x${string}`, amount: WETH_DIP, salt: s3InputSalt };

    // Fix sell price for deterministic Stage 3 output
    await publicClient!.waitForTransactionReceipt({ hash: await walletClient.writeContract({
      address: ADDRESSES.MockPriceOracle as `0x${string}`, abi: MOCK_PRICE_ORACLE_ABI,
      functionName: "setPrice", args: [BigInt(SELL_PRICE) * 10n ** 8n],
    })});
    log("info", `Oracle temporarily at $${SELL_PRICE} for Stage 3 signing…`);

    log("info", "Signing Stage 3 (sell recovery: WETH→USDC when ETH > $2,400)…");
    setSigStep(3);
    const s3Cap = buildCapability({ issuer: address, grantee: address, expiry: now + CAP_DUR, nonce: randomSalt(),
      constraints: { maxSpendPerPeriod: WETH_DIP * 2n, periodDuration: 86400n, minReturnBps: 0n,
        allowedAdapters: [ADDRESSES.PriceSwapAdapter as `0x${string}`],
        allowedTokensIn: [ADDRESSES.MockWETH as `0x${string}`], allowedTokensOut: [ADDRESSES.MockUSDC as `0x${string}`] } });
    const s3CapSig = await signCapability(walletClient, s3Cap, ADDRESSES.CapabilityKernel as `0x${string}`, ANVIL_CHAIN_ID);

    setSigStep(4);
    const s3Intent = buildIntent({ position: s3Pos, capability: s3Cap,
      adapter: ADDRESSES.PriceSwapAdapter as `0x${string}`, adapterData: "0x",
      minReturn: parseUnits("1000", 6), deadline: now + CAP_DUR, nonce: randomSalt(),
      outputToken: ADDRESSES.MockUSDC as `0x${string}`, returnTo: ZERO_ADDRESS,
      submitter: ADDRESSES.EnvelopeRegistry as `0x${string}`, solverFeeBps: 0 });
    const s3IntentSig = await signIntent(walletClient, s3Intent, ADDRESSES.CapabilityKernel as `0x${string}`, ANVIL_CHAIN_ID);

    setSigStep(5);
    const s3MgCap = buildManageCapability({ issuer: address, grantee: address, expiry: now + ENV_DUR, nonce: randomSalt() });
    const s3MgSig = await signManageCapability(walletClient, s3MgCap, ADDRESSES.EnvelopeRegistry as `0x${string}`, ANVIL_CHAIN_ID);

    const s3Cond: Conditions = { priceOracle: ADDRESSES.MockPriceOracle as `0x${string}`, baseToken: ZERO_ADDRESS,
      quoteToken: ZERO_ADDRESS, triggerPrice: SELL_TRIGGER, op: ComparisonOp.GREATER_THAN,
      secondaryOracle: ZERO_ADDRESS, secondaryTriggerPrice: 0n, secondaryOp: ComparisonOp.LESS_THAN, logicOp: LogicOp.AND };
    const s3Env = buildEnvelope({ position: s3Pos, conditions: s3Cond, intent: s3Intent, manageCapability: s3MgCap,
      expiry: now + ENV_DUR, keeperRewardBps: 10, minKeeperRewardWei: 0n });
    const s3EnvHash = hashEnvelope(s3Env) as `0x${string}`;

    // Restore oracle to buy price
    await publicClient!.waitForTransactionReceipt({ hash: await walletClient.writeContract({
      address: ADDRESSES.MockPriceOracle as `0x${string}`, abi: MOCK_PRICE_ORACLE_ABI,
      functionName: "setPrice", args: [BigInt(BUY_PRICE) * 10n ** 8n],
    })});

    Object.assign(state.current, { s2EnvHash, s2Env, s2Cap, s2Intent, s2MgCap, s2CapSig, s2IntentSig, s2MgSig,
      s2Pos, s2Cond,
      s3EnvHash, s3Env, s3Cap, s3Intent, s3MgCap, s3CapSig, s3IntentSig, s3MgSig,
      s3Pos, s3Cond });
    log("success", "9 EIP-712 sigs — entire leveraged DCA cycle pre-committed.");
    setSigStep(6);
    await publicClient!.waitForTransactionReceipt({ hash: await walletClient.writeContract({
      address: ADDRESSES.EnvelopeRegistry as `0x${string}`, abi: REGISTRY_ABI,
      functionName: "register",
      args: [s2Env as never, s2MgCap as never, s2MgSig, s2Pos as never],
    })});
    setSigStep(7);
    log("success", `Stage 2 (buy dip) live: ${s2EnvHash.slice(0, 10)}… — agent can go offline`);
    setStep(1);
  });

  // Step 1 — Trigger Stage 2 (buy the dip)
  const triggerBuy = () => withBusy(async () => {
    if (!walletClient || !address) return;
    const s = state.current;
    log("info", `Oracle at $${BUY_PRICE} → Stage 2 condition met (ETH < $1,600)…`);
    await publicClient!.waitForTransactionReceipt({ hash: await walletClient.writeContract({
      address: ADDRESSES.EnvelopeRegistry as `0x${string}`, abi: REGISTRY_ABI,
      functionName: "trigger",
      args: [s.s2EnvHash!, s.s2Cond as never, s.s2Pos as never, s.s2Intent as never, s.s2Cap as never, s.s2CapSig!, s.s2IntentSig!],
    })});
    setDipBought(true);
    log("success", `Stage 2: 1,000 USDC → ~${formatEther(WETH_DIP)} WETH at $${BUY_PRICE}`);

    // Set oracle to sell price and register Stage 3
    await publicClient!.waitForTransactionReceipt({ hash: await walletClient.writeContract({
      address: ADDRESSES.MockPriceOracle as `0x${string}`, abi: MOCK_PRICE_ORACLE_ABI,
      functionName: "setPrice", args: [BigInt(SELL_PRICE) * 10n ** 8n],
    })});
    log("info", `Oracle set to $${SELL_PRICE}. Registering Stage 3 (sell on recovery)…`);
    await publicClient!.waitForTransactionReceipt({ hash: await walletClient.writeContract({
      address: ADDRESSES.EnvelopeRegistry as `0x${string}`, abi: REGISTRY_ABI,
      functionName: "register",
      args: [s.s3Env as never, s.s3MgCap as never, s.s3MgSig!, s.s3Pos as never],
    })});
    log("success", `Stage 3 registered: ${s.s3EnvHash!.slice(0, 10)}…`);
    setStep(2);
  });

  // Step 2 — Trigger Stage 3 (sell recovery), repay loan, keep profit
  const triggerSell = () => withBusy(async () => {
    if (!walletClient || !address) return;
    const s = state.current;
    log("info", `Oracle at $${SELL_PRICE} → Stage 3 condition met (ETH > $2,400)…`);
    await publicClient!.waitForTransactionReceipt({ hash: await walletClient.writeContract({
      address: ADDRESSES.EnvelopeRegistry as `0x${string}`, abi: REGISTRY_ABI,
      functionName: "trigger",
      args: [s.s3EnvHash!, s.s3Cond as never, s.s3Pos as never, s.s3Intent as never, s.s3Cap as never, s.s3CapSig!, s.s3IntentSig!],
    })});
    setRecovered(true);
    log("success", `Stage 3: ~${formatEther(WETH_DIP)} WETH → ${Number(USDC_RECOVERY) / 1e6} USDC`);

    // Repay loan
    const usdcBal = await publicClient!.readContract({
      address: ADDRESSES.MockUSDC as `0x${string}`, abi: ERC20_ABI,
      functionName: "balanceOf", args: [address],
    }) as bigint;
    if (usdcBal >= BORROW_AMT) {
      await publicClient!.waitForTransactionReceipt({ hash: await walletClient.writeContract({
        address: ADDRESSES.MockUSDC as `0x${string}`, abi: ERC20_ABI,
        functionName: "approve", args: [ADDRESSES.MockCreditGatedLender as `0x${string}`, BORROW_AMT],
      })});
      await publicClient!.waitForTransactionReceipt({ hash: await walletClient.writeContract({
        address: ADDRESSES.MockCreditGatedLender as `0x${string}`, abi: MOCK_CREDIT_GATED_LENDER_ABI,
        functionName: "repay", args: [s.borrowCapHash!, BORROW_AMT],
      })});
      const finalUsdc = await publicClient!.readContract({
        address: ADDRESSES.MockUSDC as `0x${string}`, abi: ERC20_ABI,
        functionName: "balanceOf", args: [address],
      }) as bigint;
      setProfit(finalUsdc);
      log("success", `Loan repaid (1,000 USDC). Profit kept: ${(Number(finalUsdc) / 1e6).toFixed(2)} USDC`);
    }
    log("success", "Leveraged DCA cycle complete. Borrowed → deployed → recovered → repaid → profit.");
    setStep(3);
  });

  const profitDisplay = Number(profit) / 1e6;

  return (
    <div className="space-y-6">
      <div className="bg-zinc-900/60 border border-zinc-800 rounded-2xl p-5">
        <div className="flex items-center gap-3 mb-2">
          <span className="text-2xl">💹</span>
          <div>
            <h2 className="text-lg font-bold text-zinc-100">Leveraged DCA That Pays for Itself</h2>
            <p className="text-sm text-zinc-400">Borrow capital, buy the dip, sell the recovery, repay the loan, keep the spread.</p>
          </div>
        </div>
        <FlowDiagram nodes={[
          { condition: "Borrow 1,000 USDC",  action: "Pre-sign 3-stage chain",         result: "Agent goes offline",         tone: "neutral" },
          { condition: "ETH < $1,600",        action: "Buy dip → 0.714 WETH@$1,400",   result: "Stage 3 auto-registered",    tone: "warn"    },
          { condition: "ETH > $2,400",        action: "Sell → 1,714 USDC, repay loan", result: "~714 USDC profit kept",      tone: "safe"    },
        ]} />
        <div className="grid grid-cols-4 gap-3 mt-4 text-xs">
          {[
            { label: "Borrow", val: "1,000 USDC", active: borrowed },
            { label: "Stage 2 — Buy", val: `ETH < $1,600 → WETH@$${BUY_PRICE}`, active: dipBought },
            { label: "Stage 3 — Sell", val: `ETH > $2,400 → USDC@$${SELL_PRICE}`, active: recovered },
            { label: "Profit", val: profitDisplay > 0 ? `${profitDisplay.toFixed(0)} USDC` : "~714 USDC", active: profitDisplay > 0 },
          ].map(r => (
            <div key={r.label} className={`rounded-lg p-2 border ${r.active ? "bg-emerald-950/40 border-emerald-700 text-emerald-300" : "bg-zinc-800/60 border-zinc-700"}`}>
              <div className="text-zinc-500 text-xs">{r.label}</div>
              <div className="font-medium mt-0.5 text-xs">{r.val}</div>
              {r.active && <div className="text-emerald-400 text-xs mt-1">✓</div>}
            </div>
          ))}
        </div>
        {profitDisplay > 0 && (
          <div className="mt-3 p-3 bg-emerald-950/40 border border-emerald-700 rounded-xl text-sm text-emerald-300">
            DCA profit: <strong>{profitDisplay.toFixed(2)} USDC</strong> — loan fully repaid, capital returned. ROI: <strong>+{((profitDisplay / 1000) * 100).toFixed(1)}%</strong> on borrowed capital.
          </div>
        )}
      </div>

      <div className="grid gap-4">
        {[
          { title: "Seed lender + borrow + set up DCA chain",              desc: "Seeds lender with 5,000 USDC. Borrows 1,000 USDC as working capital, deposits it into the vault, then pre-signs all 6 permissions covering the buy-dip and sell-recovery stages. Entire cycle committed before any price move.",            action: setupAndBorrow, label: "Borrow + Set Up DCA"    },
          { title: "Stage 2 fires — buy the dip at $1,400",               desc: "ETH drops below $1,600. Keeper triggers Stage 2: 1,000 USDC → ~0.714 WETH at $1,400. Oracle is set to $2,400 and Stage 3 (sell recovery) auto-registers from pre-committed data.",                                                              action: triggerBuy,     label: "Trigger Buy (Stage 2)"  },
          { title: "Stage 3 fires — sell recovery, repay loan, keep spread", desc: "ETH rallies above $2,400. Keeper triggers Stage 3: 0.714 WETH → ~1,714 USDC. Loan (1,000 USDC) repaid to lender. Net profit: ~714 USDC — earned on borrowed capital.",                                                                          action: triggerSell,    label: "Trigger Sell + Repay"   },
        ].map((s, i) => (
          <StepCard key={i} index={i} title={s.title} description={s.desc}
            status={step > i ? "done" : step === i ? (busy ? "loading" : "ready") : "pending"}>
            {step === i && (
              <div className="space-y-3">
                {i === 0 && sigStep >= 0 && (
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
