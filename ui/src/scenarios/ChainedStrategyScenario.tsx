/**
 * Phase 8 — Chained Strategy Graph
 *
 * An AI agent pre-commits an ENTIRE two-stage autonomous strategy at setup time:
 *   Stage 1: ETH/USD < $1,800 → sell 1 WETH for USDC (protective exit)
 *   Stage 2: ETH/USD > $1,200 → rebuy WETH with USDC (re-entry)
 *
 * Both stages are signed ONCE at setup. No agent key needed for either trigger.
 * After Stage 1 fires, Stage 2 is automatically registered by the UI acting
 * as the "strategy executor" — using only pre-committed, pre-signed data.
 *
 * The key insight: the output position hash from Stage 1 is deterministic
 * (position.salt = keccak256(abi.encode(nullifier, "output"))), so the agent
 * can pre-sign Stage 2's intent referencing it BEFORE Stage 1 ever fires.
 *
 * Proves: full autonomous strategy graph, multi-stage pre-authorization,
 * liveness-independent chaining — structurally impossible with session keys.
 */
import { useState, useCallback, useRef } from "react";
import { useAccount, useWalletClient, usePublicClient } from "wagmi";
import {
  parseUnits, formatUnits, formatEther,
} from "viem";
import { computePositionHash, computeOutputSalt } from "../utils/graphUtils";

import { ADDRESSES, ANVIL_CHAIN_ID } from "../contracts/addresses";
import {
  ERC20_ABI,
  VAULT_ABI,
  REGISTRY_ABI,
  MOCK_PRICE_ORACLE_ABI,
} from "../contracts/abis";
import { LogPanel }  from "../components/LogPanel";
import type { LogEntry } from "../components/LogPanel";
import { StepCard }  from "../components/StepCard";
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
import type { Position, Conditions, Capability, Intent } from "@atlas-protocol/sdk";

// ── Oracle prices (8 decimals, Chainlink style) ───────────────────────────────
const INITIAL_PRICE      = 2500;                          // $2,500 — start
const CRASH_PRICE        = 1700;                          // $1,700 — trigger Stage 1 sell
const REBUY_PRICE        = 1700;                          // same level — rebuy
const STAGE1_TRIGGER     = 1800n * 10n ** 8n;             // < $1,800 → sell
const STAGE2_TRIGGER     = 1200n * 10n ** 8n;             // > $1,200 → rebuy (always true at $1,700)

// ── Position sizes ───────────────────────────────────────────────────────────
const WETH_DEPOSIT       = parseUnits("1", 18);           // 1 WETH
// At CRASH_PRICE ($1700) with 0% solver fee: 1e18 * 1700e8 / 1e20 = 1700e6 USDC
const STAGE1_USDC_OUT    = parseUnits("1700", 6);         // deterministic output
// At REBUY_PRICE ($1700): 1700e6 * 1e20 / 1700e8 = 1e18 WETH (same amount)
const STAGE2_WETH_OUT    = parseUnits("1", 18);           // deterministic output

const CAP_DURATION       = 90n * 86400n;
const ENV_DURATION       = 30n * 86400n;

// ── State types ───────────────────────────────────────────────────────────────
interface StageSignatures {
  position:      Position;
  spendCap:      Capability;
  intent:        Intent;
  manageCap:     Capability;
  conditions:    Conditions;
  capSig:        `0x${string}`;
  intentSig:     `0x${string}`;
  manageCapSig:  `0x${string}`;
  envelope:      unknown;
  envelopeHash:  `0x${string}`;
}

interface GraphState {
  stage1?: StageSignatures;
  stage2?: StageSignatures;
  stage1OutputPositionHash?: `0x${string}`;
}

// computePositionHash and computeOutputSalt are imported from ../utils/graphUtils

export function ChainedStrategyScenario() {
  const { address }            = useAccount();
  const { data: walletClient } = useWalletClient();
  const publicClient           = usePublicClient();
  const logId                  = useRef(0);

  const [logs,         setLogs]         = useState<LogEntry[]>([]);
  const [step,         setStep]         = useState(0);
  const [busy,         setBusy]         = useState(false);
  const [oraclePrice,  setOraclePrice]  = useState(INITIAL_PRICE);
  const [stage1Done,   setStage1Done]   = useState(false);
  const [stage2Done,   setStage2Done]   = useState(false);
  const [wethFinal,    setWethFinal]    = useState(0n);
  const graphState = useRef<GraphState>({});

  const log = useCallback((level: LogEntry["level"], msg: string) => {
    setLogs(p => [...p, { id: ++logId.current, ts: Date.now(), level, message: msg }]);
  }, []);

  const withBusy = useCallback(async (fn: () => Promise<void>) => {
    setBusy(true);
    try { await fn(); }
    catch (e: unknown) { log("error", (e instanceof Error ? e.message : String(e)).slice(0, 300)); }
    finally { setBusy(false); }
  }, [log]);

  // ── Step 0: Mint WETH ────────────────────────────────────────────────────
  const mintWETH = () => withBusy(async () => {
    if (!walletClient || !address) return;
    log("info", "Minting 2 WETH for demo…");
    await publicClient!.waitForTransactionReceipt({ hash: await walletClient.writeContract({
      address: ADDRESSES.MockWETH as `0x${string}`,
      abi: ERC20_ABI,
      functionName: "mint",
      args: [address, parseUnits("2", 18)],
    })});
    log("success", "2 WETH minted");
    setStep(1);
  });

  // ── Step 1: Set oracle to crash price & deposit 1 WETH ───────────────────
  // Fixing the oracle price BEFORE signing is the key that makes Stage 2's
  // position commitment pre-computable.
  const prepareAndDeposit = () => withBusy(async () => {
    if (!walletClient || !address) return;

    // Fix oracle to crash price so Stage 1 output = deterministic
    log("info", `Fixing oracle at $${CRASH_PRICE} for deterministic chaining…`);
    await publicClient!.waitForTransactionReceipt({ hash: await walletClient.writeContract({
      address: ADDRESSES.MockPriceOracle as `0x${string}`,
      abi: MOCK_PRICE_ORACLE_ABI,
      functionName: "setPrice",
      args: [BigInt(CRASH_PRICE) * 10n ** 8n],
    })});

    // Approve + deposit 1 WETH into vault
    await publicClient!.waitForTransactionReceipt({ hash: await walletClient.writeContract({
      address: ADDRESSES.MockWETH as `0x${string}`,
      abi: ERC20_ABI,
      functionName: "approve",
      args: [ADDRESSES.SingletonVault as `0x${string}`, WETH_DEPOSIT],
    })});
    const stage1Salt = randomSalt();
    await publicClient!.waitForTransactionReceipt({ hash: await walletClient.writeContract({
      address: ADDRESSES.SingletonVault as `0x${string}`,
      abi: VAULT_ABI,
      functionName: "deposit",
      args: [ADDRESSES.MockWETH as `0x${string}`, WETH_DEPOSIT, stage1Salt as `0x${string}`],
    })});

    const stage1InputPos: Position = {
      owner:  address,
      asset:  ADDRESSES.MockWETH as `0x${string}`,
      amount: WETH_DEPOSIT,
      salt:   stage1Salt,
    };
    const stage1PositionHash = computePositionHash(
      address,
      ADDRESSES.MockWETH as `0x${string}`,
      WETH_DEPOSIT,
      stage1Salt as `0x${string}`,
    );
    log("success", `1 WETH deposited. Position: ${stage1PositionHash.slice(0, 10)}…`);

    // Pre-compute the Stage 1 output → Stage 2 input position hash
    // We need intent1.nonce to compute the nullifier. Pick it now.
    const intent1Nonce = randomSalt();
    const outputSalt = computeOutputSalt(
      intent1Nonce as `0x${string}`,
      stage1PositionHash as `0x${string}`,
    );
    const stage2InputPosHash = computePositionHash(
      address,
      ADDRESSES.MockUSDC as `0x${string}`,
      STAGE1_USDC_OUT,
      outputSalt,
    );

    // Also pre-compute Stage 2 output → used for display only (no Stage 3 needed)
    const intent2Nonce = randomSalt();
    const stage2OutputSalt = computeOutputSalt(
      intent2Nonce as `0x${string}`,
      stage2InputPosHash as `0x${string}`,
    );
    const stage2OutputPosHash = computePositionHash(
      address,
      ADDRESSES.MockWETH as `0x${string}`,
      STAGE2_WETH_OUT,
      stage2OutputSalt,
    );

    log("success", `Stage 2 input commitment pre-computed: ${stage2InputPosHash.slice(0, 10)}…`);
    log("info", `Stage 2 output commitment pre-computed: ${stage2OutputPosHash.slice(0, 10)}…`);

    const { timestamp: now } = await publicClient!.getBlock({ blockTag: "latest" });

    // ── Sign Stage 1 ────────────────────────────────────────────────────────
    log("info", "Signing Stage 1 (WETH→USDC protective sell) [3 EIP-712 sigs]…");

    const cap1Nonce = randomSalt();
    const spendCap1 = buildCapability({
      issuer:  address,
      grantee: address,
      expiry:  now + CAP_DURATION,
      nonce:   cap1Nonce,
      constraints: {
        maxSpendPerPeriod: WETH_DEPOSIT * 2n,
        periodDuration:    86400n,
        minReturnBps:      0n,
        allowedAdapters:   [ADDRESSES.PriceSwapAdapter as `0x${string}`],
        allowedTokensIn:   [ADDRESSES.MockWETH as `0x${string}`],
        allowedTokensOut:  [ADDRESSES.MockUSDC as `0x${string}`],
      },
    });
    const capSig1 = await signCapability(walletClient, spendCap1, ADDRESSES.CapabilityKernel as `0x${string}`, ANVIL_CHAIN_ID);

    const intent1 = buildIntent({
      position:    stage1InputPos,
      capability:  spendCap1,
      adapter:     ADDRESSES.PriceSwapAdapter as `0x${string}`,
      adapterData: "0x",
      minReturn:   parseUnits("1500", 6),
      deadline:    now + CAP_DURATION,
      nonce:       intent1Nonce,
      outputToken: ADDRESSES.MockUSDC as `0x${string}`,
      returnTo:    ZERO_ADDRESS,
      submitter:   ADDRESSES.EnvelopeRegistry as `0x${string}`,
      solverFeeBps: 0,
    });
    const intentSig1 = await signIntent(walletClient, intent1, ADDRESSES.CapabilityKernel as `0x${string}`, ANVIL_CHAIN_ID);

    const manageCap1 = buildManageCapability({
      issuer:  address,
      grantee: address,
      expiry:  now + ENV_DURATION,
      nonce:   randomSalt(),
    });
    const manageCapSig1 = await signManageCapability(walletClient, manageCap1, ADDRESSES.EnvelopeRegistry as `0x${string}`, ANVIL_CHAIN_ID);

    const conditions1: Conditions = {
      priceOracle:           ADDRESSES.MockPriceOracle as `0x${string}`,
      baseToken:             ZERO_ADDRESS,
      quoteToken:            ZERO_ADDRESS,
      triggerPrice:          STAGE1_TRIGGER,
      op:                    ComparisonOp.LESS_THAN,
      secondaryOracle:       ZERO_ADDRESS,
      secondaryTriggerPrice: 0n,
      secondaryOp:           ComparisonOp.LESS_THAN,
      logicOp:               LogicOp.AND,
    };
    const envelope1 = buildEnvelope({
      position:          stage1InputPos,
      conditions:        conditions1,
      intent:            intent1,
      manageCapability:  manageCap1,
      expiry:            now + ENV_DURATION,
      keeperRewardBps:   10,
      minKeeperRewardWei: 0n,
    });
    const envelopeHash1 = hashEnvelope(envelope1) as `0x${string}`;

    log("success", "Stage 1 signed ✓");

    // ── Sign Stage 2 ────────────────────────────────────────────────────────
    log("info", "Signing Stage 2 (USDC→WETH rebuy) using pre-computed Stage 1 output position…");

    const stage2InputPos: Position = {
      owner:  address,
      asset:  ADDRESSES.MockUSDC as `0x${string}`,
      amount: STAGE1_USDC_OUT,
      salt:   outputSalt,
    };

    const cap2Nonce = randomSalt();
    const spendCap2 = buildCapability({
      issuer:  address,
      grantee: address,
      expiry:  now + CAP_DURATION,
      nonce:   cap2Nonce,
      constraints: {
        maxSpendPerPeriod: STAGE1_USDC_OUT * 2n,
        periodDuration:    86400n,
        minReturnBps:      0n,
        allowedAdapters:   [ADDRESSES.MockReverseSwapAdapter as `0x${string}`],
        allowedTokensIn:   [ADDRESSES.MockUSDC as `0x${string}`],
        allowedTokensOut:  [ADDRESSES.MockWETH as `0x${string}`],
      },
    });
    const capSig2 = await signCapability(walletClient, spendCap2, ADDRESSES.CapabilityKernel as `0x${string}`, ANVIL_CHAIN_ID);

    const intent2 = buildIntent({
      position:    stage2InputPos,
      capability:  spendCap2,
      adapter:     ADDRESSES.MockReverseSwapAdapter as `0x${string}`,
      adapterData: "0x",
      minReturn:   parseUnits("0.8", 18),
      deadline:    now + CAP_DURATION,
      nonce:       intent2Nonce,
      outputToken: ADDRESSES.MockWETH as `0x${string}`,
      returnTo:    ZERO_ADDRESS,
      submitter:   ADDRESSES.EnvelopeRegistry as `0x${string}`,
      solverFeeBps: 0,
    });
    const intentSig2 = await signIntent(walletClient, intent2, ADDRESSES.CapabilityKernel as `0x${string}`, ANVIL_CHAIN_ID);

    const manageCap2 = buildManageCapability({
      issuer:  address,
      grantee: address,
      expiry:  now + ENV_DURATION,
      nonce:   randomSalt(),
    });
    const manageCapSig2 = await signManageCapability(walletClient, manageCap2, ADDRESSES.EnvelopeRegistry as `0x${string}`, ANVIL_CHAIN_ID);

    const conditions2: Conditions = {
      priceOracle:           ADDRESSES.MockPriceOracle as `0x${string}`,
      baseToken:             ZERO_ADDRESS,
      quoteToken:            ZERO_ADDRESS,
      triggerPrice:          STAGE2_TRIGGER,
      op:                    ComparisonOp.GREATER_THAN,
      secondaryOracle:       ZERO_ADDRESS,
      secondaryTriggerPrice: 0n,
      secondaryOp:           ComparisonOp.LESS_THAN,
      logicOp:               LogicOp.AND,
    };
    const envelope2 = buildEnvelope({
      position:          stage2InputPos,
      conditions:        conditions2,
      intent:            intent2,
      manageCapability:  manageCap2,
      expiry:            now + ENV_DURATION,
      keeperRewardBps:   10,
      minKeeperRewardWei: 0n,
    });
    const envelopeHash2 = hashEnvelope(envelope2) as `0x${string}`;

    log("success", "Stage 2 signed ✓");

    // ── Store all state ──────────────────────────────────────────────────────
    graphState.current = {
      stage1: {
        position:     stage1InputPos,
        spendCap:     spendCap1,
        intent:       intent1,
        manageCap:    manageCap1,
        conditions:   conditions1,
        capSig:       capSig1 as `0x${string}`,
        intentSig:    intentSig1 as `0x${string}`,
        manageCapSig: manageCapSig1 as `0x${string}`,
        envelope:     envelope1,
        envelopeHash: envelopeHash1,
      },
      stage2: {
        position:     stage2InputPos,
        spendCap:     spendCap2,
        intent:       intent2,
        manageCap:    manageCap2,
        conditions:   conditions2,
        capSig:       capSig2 as `0x${string}`,
        intentSig:    intentSig2 as `0x${string}`,
        manageCapSig: manageCapSig2 as `0x${string}`,
        envelope:     envelope2,
        envelopeHash: envelopeHash2,
      },
      stage1OutputPositionHash: stage2InputPosHash as `0x${string}`,
    };

    log("success", "Entire strategy graph pre-committed. Agent can go offline.");
    setOraclePrice(CRASH_PRICE);
    setStep(2);
  });

  // ── Step 2: Register Stage 1 envelope ────────────────────────────────────
  const registerStage1 = () => withBusy(async () => {
    if (!walletClient || !address) return;
    const { stage1 } = graphState.current;
    if (!stage1) return;

    log("info", "Registering Stage 1 envelope on-chain…");
    await publicClient!.waitForTransactionReceipt({ hash: await walletClient.writeContract({
      address: ADDRESSES.EnvelopeRegistry as `0x${string}`,
      abi: REGISTRY_ABI,
      functionName: "register",
      args: [stage1.envelope as never, stage1.manageCap as never, stage1.manageCapSig, stage1.position as never],
    })});
    log("success", `Stage 1 envelope registered ✓ — ${stage1.envelopeHash.slice(0, 10)}…`);
    log("success", "Both stages committed. Oracle at $1,700 → condition: ETH < $1,800 = TRUE");
    setStep(3);
  });

  // ── Step 3: Keeper triggers Stage 1 + auto-chains Stage 2 ───────────────
  const triggerStage1AndChain = () => withBusy(async () => {
    if (!walletClient || !address) return;
    const { stage1, stage2 } = graphState.current;
    if (!stage1 || !stage2) return;

    log("info", "Keeper: Stage 1 condition TRUE (ETH $1,700 < $1,800) — triggering…");
    await publicClient!.waitForTransactionReceipt({ hash: await walletClient.writeContract({
      address: ADDRESSES.EnvelopeRegistry as `0x${string}`,
      abi: REGISTRY_ABI,
      functionName: "trigger",
      args: [
        stage1.envelopeHash,
        stage1.conditions as never,
        stage1.position as never,
        stage1.intent as never,
        stage1.spendCap as never,
        stage1.capSig,
        stage1.intentSig,
      ],
    })});
    log("success", `Stage 1 executed: 1 WETH → ${formatUnits(STAGE1_USDC_OUT, 6)} USDC`);
    log("info", "Auto-chaining: registering Stage 2 envelope with pre-committed signatures…");

    // The output USDC position now exists in the vault.
    // Register Stage 2 using the pre-signed data.
    await publicClient!.waitForTransactionReceipt({ hash: await walletClient.writeContract({
      address: ADDRESSES.EnvelopeRegistry as `0x${string}`,
      abi: REGISTRY_ABI,
      functionName: "register",
      args: [stage2.envelope as never, stage2.manageCap as never, stage2.manageCapSig, stage2.position as never],
    })});
    log("success", `Stage 2 registered ✓ — ${stage2.envelopeHash.slice(0, 10)}…`);
    log("success", "Strategy chained. Condition for Stage 2: ETH > $1,200 (TRUE at $1,700)");
    setStage1Done(true);
    setStep(4);
  });

  // ── Step 4: Keeper triggers Stage 2 (complete the cycle) ─────────────────
  const triggerStage2 = () => withBusy(async () => {
    if (!walletClient || !address) return;
    const { stage2 } = graphState.current;
    if (!stage2) return;

    log("info", "Keeper: Stage 2 condition TRUE (ETH $1,700 > $1,200) — triggering rebuy…");
    await publicClient!.waitForTransactionReceipt({ hash: await walletClient.writeContract({
      address: ADDRESSES.EnvelopeRegistry as `0x${string}`,
      abi: REGISTRY_ABI,
      functionName: "trigger",
      args: [
        stage2.envelopeHash,
        stage2.conditions as never,
        stage2.position as never,
        stage2.intent as never,
        stage2.spendCap as never,
        stage2.capSig,
        stage2.intentSig,
      ],
    })});

    // At $1,700: wethOut = 1700e6 * 1e20 / 1700e8 = 1e18 WETH
    const wethOut = (STAGE1_USDC_OUT * BigInt(1e20)) / (BigInt(REBUY_PRICE) * 10n ** 8n);
    setWethFinal(wethOut);
    log("success", `Stage 2 executed: ${formatUnits(STAGE1_USDC_OUT, 6)} USDC → ${formatEther(wethOut)} WETH`);
    log("success", "Full cycle complete. Both stages ran autonomously with no agent key.");
    setStage2Done(true);
    setStep(5);
  });

  const statusFor = (s: number): "done" | "active" | "pending" =>
    step > s ? "done" : step === s ? "active" : "pending";

  // ── Talking points data ───────────────────────────────────────────────────
  const comparison = [
    { feature: "Session key", can: false, desc: "Needs key online for EVERY stage" },
    { feature: "Gelato/Chainlink", can: false, desc: "Single condition, no chaining" },
    { feature: "Gnosis Safe", can: false, desc: "Requires human confirmation each step" },
    { feature: "Atlas envelope chain", can: true, desc: "Pre-committed, keeper-triggered, no agent needed" },
  ];

  return (
    <div className="flex gap-6 w-full">
      {/* ── Main flow ───────────────────────────────────────────────────── */}
      <div className="flex-1 min-w-0 flex flex-col gap-4">

        {/* Hero */}
        <div className="rounded-xl border border-emerald-700 bg-emerald-950/20 p-5">
          <div className="flex items-center gap-3 mb-2">
            <span className="text-2xl">🔗</span>
            <div>
              <h2 className="text-lg font-bold text-emerald-300">Chained Strategy Graph</h2>
              <p className="text-xs text-slate-400">Multi-stage autonomous execution • Zero agent liveness • Pre-committed graph</p>
            </div>
          </div>
          <p className="text-sm text-slate-300 mt-2">
            Agent pre-commits a <span className="text-emerald-300 font-medium">complete 2-stage strategy</span> in one session.
            Stage 1 sells WETH on a crash. Stage 2 rebuys at the dip — all pre-authorized, keeper-triggered, no agent ever online again.
          </p>

          {/* Strategy graph visualization */}
          <div className="mt-4 flex items-center gap-2 text-xs overflow-x-auto pb-1">
            {[
              { icon: "🤖", label: "Agent Setup", sub: "sign once", color: "border-slate-600 text-slate-300", active: step >= 1 },
              { icon: "→", label: "", sub: "", color: "border-transparent text-slate-600", active: true },
              { icon: "🛡️", label: "Stage 1", sub: "WETH→USDC", color: `border-orange-700 ${stage1Done || step >= 3 ? "bg-orange-950/40 text-orange-300" : "text-slate-400"}`, active: step >= 3 },
              { icon: "→", label: "", sub: "", color: "border-transparent text-slate-600", active: true },
              { icon: "🔗", label: "Auto-chain", sub: "register S2", color: `border-violet-700 ${stage1Done ? "bg-violet-950/40 text-violet-300" : "text-slate-400"}`, active: stage1Done },
              { icon: "→", label: "", sub: "", color: "border-transparent text-slate-600", active: true },
              { icon: "📈", label: "Stage 2", sub: "USDC→WETH", color: `border-emerald-700 ${stage2Done ? "bg-emerald-950/40 text-emerald-300" : "text-slate-400"}`, active: stage2Done },
            ].map((node, i) => (
              <div key={i} className="flex-shrink-0">
                {node.label ? (
                  <div className={`rounded-lg border px-3 py-2 text-center min-w-[70px] transition-all ${node.color} ${node.active ? "opacity-100" : "opacity-40"}`}>
                    <div className="text-base">{node.icon}</div>
                    <div className="font-medium">{node.label}</div>
                    <div className="text-zinc-500">{node.sub}</div>
                  </div>
                ) : (
                  <span className={`text-xl ${node.active ? "text-slate-500" : "text-slate-700"}`}>{node.icon}</span>
                )}
              </div>
            ))}
          </div>

          {/* Oracle status */}
          <div className={`mt-3 flex items-center gap-3 px-3 py-2 rounded-lg border text-xs ${
            oraclePrice < 1800 ? "border-red-800 bg-red-950/20 text-red-400" : "border-zinc-800 bg-zinc-900/30 text-zinc-400"
          }`}>
            <span className="text-lg">{oraclePrice < 1800 ? "📉" : "📈"}</span>
            <span>Oracle: <strong>${oraclePrice.toLocaleString()}</strong></span>
            {oraclePrice < 1800 && <span className="text-orange-400">⚡ Stage 1 condition: ETH &lt; $1,800 = TRUE</span>}
            {oraclePrice < 1800 && oraclePrice > 1200 && <span className="text-emerald-400 ml-2">⚡ Stage 2 condition: ETH &gt; $1,200 = TRUE</span>}
          </div>
        </div>

        {/* Steps */}
        <StepCard step={0} title="Mint 2 WETH" subtitle="Get mock WETH representing the agent's holdings" status={statusFor(0)}>
          <TxButton label="Mint 2 WETH" onClick={mintWETH} disabled={step !== 0 || busy} />
        </StepCard>

        <StepCard step={1} title="Deposit + Sign entire strategy graph" subtitle="Fixes oracle at $1,700, deposits 1 WETH, then pre-signs BOTH stages in one session" status={statusFor(1)}>
          <div className="text-xs text-slate-500 space-y-1 mb-3 ml-2">
            <p>Stage 1: 1 WETH → USDC if ETH &lt; $1,800 (6 EIP-712 sigs)</p>
            <p>Stage 2: USDC → WETH if ETH &gt; $1,200, signed against <span className="text-violet-400">pre-computed S1 output hash</span></p>
            <p className="text-violet-400">This is the key: both signed BEFORE either fires.</p>
          </div>
          <TxButton label="Deposit + Sign Graph" onClick={prepareAndDeposit} disabled={step !== 1 || busy} />
        </StepCard>

        {step >= 2 && (
          <StepCard step={2} title="Register Stage 1 envelope on-chain" subtitle="Position encumbered. Strategy monitoring begins. Agent can go offline." status={statusFor(2)}>
            <TxButton label="Register Stage 1" onClick={registerStage1} disabled={step !== 2 || busy} />
          </StepCard>
        )}

        {step >= 3 && !stage1Done && (
          <StepCard step={3} title="Keeper: trigger Stage 1 + auto-chain Stage 2" subtitle="Oracle $1,700 < $1,800 → condition TRUE. Execute Stage 1, then register Stage 2 atomically." status={statusFor(3)}>
            <div className="text-xs text-slate-500 space-y-1 mb-3 ml-2">
              <p>1. Trigger Stage 1 → 1 WETH → 1,700 USDC</p>
              <p>2. Auto-register Stage 2 using pre-signed data</p>
              <p className="text-emerald-400">Both happen in 2 sequential txs. No agent key.</p>
            </div>
            <TxButton label="Trigger Stage 1 + Chain Stage 2" onClick={triggerStage1AndChain} disabled={step !== 3 || busy} />
          </StepCard>
        )}

        {step >= 4 && stage1Done && !stage2Done && (
          <StepCard step={4} title="Keeper: trigger Stage 2 (rebuy the dip)" subtitle="Oracle $1,700 > $1,200 → condition TRUE. Execute Stage 2 — USDC back to WETH." status={statusFor(4)}>
            <TxButton label="Trigger Stage 2 (Complete Cycle)" onClick={triggerStage2} disabled={step !== 4 || busy} />
          </StepCard>
        )}

        {stage2Done && (
          <div className="rounded-xl border border-emerald-500 bg-emerald-950/30 p-5">
            <div className="text-3xl mb-2 text-center">✅</div>
            <div className="text-emerald-300 font-bold text-lg text-center">Strategy Cycle Complete</div>
            <div className="mt-3 grid grid-cols-3 gap-3 text-center text-xs">
              <div className="rounded-lg bg-zinc-800/60 p-2">
                <div className="text-slate-500">Started</div>
                <div className="text-slate-200 font-bold font-mono">1.000 WETH</div>
              </div>
              <div className="rounded-lg bg-zinc-800/60 p-2">
                <div className="text-slate-500">Mid-cycle</div>
                <div className="text-orange-300 font-bold font-mono">{formatUnits(STAGE1_USDC_OUT, 6)} USDC</div>
              </div>
              <div className="rounded-lg bg-zinc-800/60 p-2">
                <div className="text-slate-500">Final</div>
                <div className="text-emerald-300 font-bold font-mono">{formatEther(wethFinal)} WETH</div>
              </div>
            </div>
            <p className="text-xs text-slate-500 text-center mt-3">
              Both stages ran without any agent key interaction after the initial setup.
            </p>
          </div>
        )}

        <LogPanel entries={logs} />
      </div>

      {/* ── Right panel ──────────────────────────────────────────────────── */}
      <div className="w-80 flex-shrink-0 flex flex-col gap-4">

        {/* Why it's impossible with session keys */}
        <div className="rounded-xl border border-emerald-700 bg-emerald-950/20 p-4 text-xs">
          <h3 className="text-sm font-bold text-emerald-300 mb-3">Why session keys can't do this</h3>
          <div className="space-y-2">
            {comparison.map(c => (
              <div key={c.feature} className="flex items-start gap-2">
                <span className={c.can ? "text-emerald-400" : "text-red-500"}>
                  {c.can ? "✓" : "✗"}
                </span>
                <div>
                  <span className={`font-medium ${c.can ? "text-emerald-300" : "text-slate-400"}`}>{c.feature}</span>
                  <span className="text-slate-500"> — {c.desc}</span>
                </div>
              </div>
            ))}
          </div>
        </div>

        {/* The key insight */}
        <div className="rounded-xl border border-violet-800 bg-violet-950/20 p-4 text-xs">
          <h3 className="text-sm font-bold text-violet-300 mb-3">The Deterministic Chain</h3>
          <p className="text-slate-400 mb-2">
            The kernel computes the output position salt as:
          </p>
          <code className="block bg-zinc-900 rounded p-2 text-violet-300 text-xs mb-2">
            outputSalt =<br />
            keccak256(nullifier, "output")
          </code>
          <p className="text-slate-400 mb-2">
            Since <code className="text-violet-300">nullifier</code> = <code className="text-violet-300">keccak256(nonce, positionCommitment)</code> and both are chosen at setup time, the agent pre-computes the Stage 2 position hash <strong className="text-white">before Stage 1 ever fires</strong>.
          </p>
          <p className="text-slate-400">
            This is the mechanism that makes infinite pre-committed strategy graphs possible.
          </p>
        </div>

        {/* Strategy parameters */}
        <div className="rounded-xl border border-slate-700 bg-slate-900/50 p-4 text-xs text-slate-400">
          <div className="font-semibold text-slate-300 mb-2">Strategy parameters</div>
          <div className="space-y-1">
            {[
              ["Stage 1 trigger",  "ETH/USD < $1,800"],
              ["Stage 1 action",   "1 WETH → USDC"],
              ["Stage 1 floor",    "min $1,500 USDC"],
              ["Stage 2 trigger",  "ETH/USD > $1,200"],
              ["Stage 2 action",   "USDC → WETH"],
              ["Stage 2 floor",    "min 0.8 WETH"],
              ["Pre-auth sigs",    "6 EIP-712 total"],
              ["Agent liveness",   "not required"],
            ].map(([k, v]) => (
              <div key={k} className="flex justify-between gap-2">
                <span className="text-slate-500">{k}</span>
                <span className="text-slate-300 font-mono text-right">{v}</span>
              </div>
            ))}
          </div>
        </div>

        {/* Talking points */}
        <div className="rounded-xl border border-slate-700 bg-slate-900/50 p-4 text-xs text-slate-400">
          <div className="font-semibold text-slate-300 mb-2">Investor talking points</div>
          <ul className="space-y-1.5">
            <li>✓ Entire policy committed at deployment — auditable from day one</li>
            <li>✓ Graph runs forever without human or agent intervention</li>
            <li>✓ Cannot deviate from pre-committed execution path</li>
            <li>✓ oracle manipulation → early trigger, NOT a bad fill (minReturn floor)</li>
            <li>✓ Chaining mechanism: deterministic output salt enables infinite pre-signing</li>
          </ul>
        </div>
      </div>
    </div>
  );
}
