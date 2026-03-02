/**
 * Phase 7 — ZK Credit Passport
 *
 * Narrative: An agent builds a compliance history through Atlas Clawloan cycles.
 * Its ZK proofs upgrade its credit tier. The upgraded tier unlocks higher borrow
 * limits at MockCreditGatedLender — a DIFFERENT protocol that has never seen this
 * agent before. The credit proof is portable across any protocol that checks Atlas tiers.
 *
 * What this proves:
 *  - Cross-protocol credit portability ("agent credit score that preserves privacy")
 *  - ZK compliance proofs as portable trust credentials
 *  - The data network effect: Atlas becomes the trust oracle for the ecosystem
 *  - Privacy preserved: lender never sees individual trades, only the tier
 */
import { useState, useCallback, useRef } from "react";
import { useAccount, useWalletClient, usePublicClient } from "wagmi";
import { formatUnits, parseUnits, toHex, encodeAbiParameters, parseAbiParameters } from "viem";

import { ADDRESSES, ANVIL_CHAIN_ID } from "../contracts/addresses";
import {
  ERC20_ABI,
  CLAWLOAN_POOL_ABI,
  VAULT_ABI,
  REGISTRY_ABI,
  CREDIT_VERIFIER_ABI,
  ACCUMULATOR_ABI,
  MOCK_CREDIT_GATED_LENDER_ABI,
} from "../contracts/abis";
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
  clawloanRepayLive,
  randomSalt,
  hashCapability,
  hashEnvelope,
  ZERO_ADDRESS,
  ComparisonOp,
  LogicOp,
} from "@atlas-protocol/sdk";
import type { Position, Capability } from "@atlas-protocol/sdk";

// ─── Constants ────────────────────────────────────────────────────────────────
const BORROW_AMT = parseUnits("500",  6);
const EARN_AMT   = parseUnits("1000", 6);
const LOAN_WIN   = 7n * 24n * 3600n;
const BOT_ID     = 5n;

const TIER_LABELS = ["NEW", "BRONZE", "SILVER", "GOLD", "PLATINUM"];
const TIER_COLORS = ["text-slate-400", "text-amber-600", "text-slate-300", "text-yellow-400", "text-cyan-300"];
const TIER_LIMITS = [100, 500, 2000, 5000, 10000];

interface ZKState {
  capHash?: `0x${string}`;
  cycle:    number;
}

export function ZKPassportScenario() {
  const { address }            = useAccount();
  const { data: walletClient } = useWalletClient();
  const publicClient           = usePublicClient();
  const logId = useRef(0);

  const [logs,             setLogs]             = useState<LogEntry[]>([]);
  const [busy,             setBusy]             = useState(false);
  const [tier,             setTier]             = useState(0);
  const [phase,            setPhase]            = useState<"setup" | "cycle" | "proof" | "lend">("setup");
  const [creditLenderDebt, setCreditLenderDebt] = useState(0n);
  const stateRef = useRef<ZKState>({ cycle: 0 });

  const log = useCallback((level: LogEntry["level"], message: string) => {
    setLogs(prev => [...prev, { id: ++logId.current, ts: Date.now(), level, message }]);
  }, []);

  const withBusy = useCallback(async (fn: () => Promise<void>) => {
    setBusy(true);
    try { await fn(); }
    catch (e: unknown) { log("error", (e instanceof Error ? e.message : String(e)).slice(0, 300)); }
    finally { setBusy(false); }
  }, [log]);

  const refreshTier = useCallback(async (capHash: `0x${string}`) => {
    if (!publicClient) return;
    try {
      const t = await publicClient.readContract({
        address: ADDRESSES.CreditVerifier as `0x${string}`,
        abi: CREDIT_VERIFIER_ABI,
        functionName: "getCreditTier",
        args: [capHash],
      });
      setTier(Number(t));
    } catch { /* ignore */ }
  }, [publicClient]);

  // ── Run one Clawloan cycle ────────────────────────────────────────────────
  const runCycle = () => withBusy(async () => {
    if (!walletClient || !address || !publicClient) return;
    setPhase("cycle");
    const cycleNum = stateRef.current.cycle + 1;
    log("info", `─── Cycle ${cycleNum}: Clawloan credit ───`);

    await publicClient.waitForTransactionReceipt({ hash: await walletClient.writeContract({
      address: ADDRESSES.MockUSDC as `0x${string}`, abi: ERC20_ABI, functionName: "mint",
      args: [address, EARN_AMT],
    })});
    await publicClient.waitForTransactionReceipt({ hash: await walletClient.writeContract({
      address: ADDRESSES.MockClawloanPool as `0x${string}`, abi: CLAWLOAN_POOL_ABI,
      functionName: "borrow", args: [BOT_ID, BORROW_AMT],
    })});
    log("info", `  Borrowed $500 | bot ID: ${BOT_ID}`);

    await publicClient.waitForTransactionReceipt({ hash: await walletClient.writeContract({
      address: ADDRESSES.MockUSDC as `0x${string}`, abi: ERC20_ABI, functionName: "approve",
      args: [ADDRESSES.SingletonVault as `0x${string}`, EARN_AMT],
    })});
    const salt = toHex(randomSalt());
    await publicClient.waitForTransactionReceipt({ hash: await walletClient.writeContract({
      address: ADDRESSES.SingletonVault as `0x${string}`, abi: VAULT_ABI, functionName: "deposit",
      args: [ADDRESSES.MockUSDC as `0x${string}`, EARN_AMT, salt as `0x${string}`],
    })});

    const position: Position = { owner: address, asset: ADDRESSES.MockUSDC as `0x${string}`, amount: EARN_AMT, salt };

    const { timestamp: now } = await publicClient.getBlock({ blockTag: "latest" });
    const deadline = now + LOAN_WIN;

    const spendCap: Capability = buildCapability({
      issuer:  address,
      grantee: address,
      expiry:  now + 90n * 86400n,
      nonce:   toHex(randomSalt()),
      constraints: {
        maxSpendPerPeriod: EARN_AMT * 2n,
        periodDuration:    86400n,
        minReturnBps:      0n,
        allowedAdapters:   [ADDRESSES.ClawloanRepayAdapter as `0x${string}`],
        allowedTokensIn:   [],
        allowedTokensOut:  [],
      },
    });
    const capSig  = await signCapability(walletClient, spendCap, ADDRESSES.CapabilityKernel as `0x${string}`, ANVIL_CHAIN_ID);
    const capHash = hashCapability(spendCap) as `0x${string}`;

    if (!stateRef.current.capHash) stateRef.current.capHash = capHash;

    const liveDebt = await publicClient.readContract({
      address: ADDRESSES.MockClawloanPool as `0x${string}`, abi: CLAWLOAN_POOL_ABI,
      functionName: "getDebt", args: [BOT_ID],
    }) as bigint;

    const adapterData = clawloanRepayLive(ADDRESSES.MockClawloanPool as `0x${string}`, BOT_ID, liveDebt);
    const intent = buildIntent({
      position,
      capability:  spendCap,
      adapter:     ADDRESSES.ClawloanRepayAdapter as `0x${string}`,
      adapterData,
      minReturn:   EARN_AMT - liveDebt - parseUnits("10", 6),
      deadline,
      nonce:       toHex(randomSalt()),
      outputToken: ADDRESSES.MockUSDC as `0x${string}`,
      returnTo:    ZERO_ADDRESS,
      submitter:   ZERO_ADDRESS,
      solverFeeBps: 0,
    });
    const intentSig = await signIntent(walletClient, intent, ADDRESSES.CapabilityKernel as `0x${string}`, ANVIL_CHAIN_ID);

    const manageCap = buildManageCapability({
      issuer:  address,
      grantee: ADDRESSES.EnvelopeRegistry as `0x${string}`,
      expiry:  now + LOAN_WIN + 3600n,
      nonce:   toHex(randomSalt()),
    });
    const manageCapSig = await signManageCapability(walletClient, manageCap, ADDRESSES.EnvelopeRegistry as `0x${string}`, ANVIL_CHAIN_ID);

    const conditions = {
      priceOracle:           ADDRESSES.MockTimestampOracle as `0x${string}`,
      baseToken:             ZERO_ADDRESS,
      quoteToken:            ZERO_ADDRESS,
      triggerPrice:          deadline,
      op:                    ComparisonOp.GREATER_THAN,
      secondaryOracle:       ZERO_ADDRESS,
      secondaryTriggerPrice: 0n,
      secondaryOp:           ComparisonOp.LESS_THAN,
      logicOp:               LogicOp.AND,
    };

    const envelope = buildEnvelope({
      position, conditions, intent,
      manageCapability: manageCap,
      expiry:           deadline + 3600n,
      keeperRewardBps:  0,
      minKeeperRewardWei: 0n,
    });
    const envHash = hashEnvelope(envelope) as `0x${string}`;

    await publicClient.waitForTransactionReceipt({ hash: await walletClient.writeContract({
      address: ADDRESSES.EnvelopeRegistry as `0x${string}`, abi: REGISTRY_ABI,
      functionName: "register",
      args: [envelope as never, manageCap as never, manageCapSig, position as never],
    })});
    log("info", "  Envelope registered");

    // Warp time + trigger
    await publicClient.request({ method: "evm_setNextBlockTimestamp" as never, params: [`0x${(deadline + 1n).toString(16)}`] as never });
    await publicClient.request({ method: "evm_mine" as never, params: [] as never });

    await publicClient.waitForTransactionReceipt({ hash: await walletClient.writeContract({
      address: ADDRESSES.EnvelopeRegistry as `0x${string}`, abi: REGISTRY_ABI,
      functionName: "trigger",
      args: [envHash, conditions as never, position as never, intent as never, spendCap as never, capSig as `0x${string}`, intentSig as `0x${string}`],
    })});
    log("success", `  Loan repaid | cycle ${cycleNum} complete`);

    stateRef.current.cycle++;
    setPhase("proof");
    log("info", `Ready to submit ZK proof for cycle ${cycleNum}`);
  });

  // ── Submit ZK proof + upgrade tier ───────────────────────────────────────
  const submitProof = () => withBusy(async () => {
    if (!walletClient || !publicClient) return;
    const { capHash } = stateRef.current;
    if (!capHash) { log("error", "Run a cycle first"); return; }
    log("info", "Submitting ZK compliance proof…");

    const adapter = ADDRESSES.ClawloanRepayAdapter as `0x${string}`;

    // Fetch adapter-filtered receipt count (n), hashes, and nullifiers from
    // ReceiptAccumulator. These are the private inputs that the mock verifier
    // replicates the rolling-root computation from (replacing a real ZK proof).
    const [n, receiptHashes, nullifiers] = await Promise.all([
      publicClient.readContract({
        address: ADDRESSES.ReceiptAccumulator as `0x${string}`,
        abi: ACCUMULATOR_ABI,
        functionName: "adapterReceiptCount",
        args: [capHash, adapter],
      }) as Promise<bigint>,
      publicClient.readContract({
        address: ADDRESSES.ReceiptAccumulator as `0x${string}`,
        abi: ACCUMULATOR_ABI,
        functionName: "getAdapterReceiptHashes",
        args: [capHash, adapter],
      }) as Promise<readonly `0x${string}`[]>,
      publicClient.readContract({
        address: ADDRESSES.ReceiptAccumulator as `0x${string}`,
        abi: ACCUMULATOR_ABI,
        functionName: "getAdapterNullifiers",
        args: [capHash, adapter],
      }) as Promise<readonly `0x${string}`[]>,
    ]);

    // adapters[]: all entries are ClawloanRepayAdapter (we're using adapter filter).
    // amountsIn/Out: zeros — minReturnBps is 0 so the mock skips that constraint.
    const count = Number(n);
    const adapters  = Array<`0x${string}`>(count).fill(adapter);
    const amounts   = Array<bigint>(count).fill(0n);

    // MockCircuit1Verifier proof encoding:
    // abi.encode(bytes32[] receiptHashes, bytes32[] nullifiers,
    //            address[] adapters, uint256[] amountsIn, uint256[] amountsOut)
    const proofBytes = encodeAbiParameters(
      parseAbiParameters("bytes32[], bytes32[], address[], uint256[], uint256[]"),
      [
        receiptHashes as `0x${string}`[],
        nullifiers    as `0x${string}`[],
        adapters,
        amounts,
        amounts,
      ],
    );

    log("info", `  Encoding ${count} receipt(s) as mock proof witness…`);

    await publicClient.waitForTransactionReceipt({ hash: await walletClient.writeContract({
      address: ADDRESSES.CreditVerifier as `0x${string}`,
      abi: CREDIT_VERIFIER_ABI,
      functionName: "submitProof",
      args: [capHash, n, adapter, 0n, proofBytes],
    })});

    await refreshTier(capHash);
    const newTier = await publicClient.readContract({
      address: ADDRESSES.CreditVerifier as `0x${string}`,
      abi: CREDIT_VERIFIER_ABI,
      functionName: "getCreditTier",
      args: [capHash],
    }) as number;

    setTier(Number(newTier));
    log("success", `Proof verified | tier: ${TIER_LABELS[newTier]} | new limit: $${TIER_LIMITS[newTier].toLocaleString()}/cycle`);
    setPhase("lend");
  });

  // ── Borrow from MockCreditGatedLender (different protocol) ───────────────
  const borrowFromCreditLender = () => withBusy(async () => {
    if (!walletClient || !publicClient) return;
    const { capHash } = stateRef.current;
    if (!capHash) { log("error", "Build credit history first"); return; }
    const [limit, currentTier] = await publicClient.readContract({
      address: ADDRESSES.MockCreditGatedLender as `0x${string}`,
      abi: MOCK_CREDIT_GATED_LENDER_ABI,
      functionName: "getLimitForCap",
      args: [capHash],
    }) as [bigint, number];

    log("info", `Borrowing from CreditGatedLender (tier: ${TIER_LABELS[currentTier]}, limit: $${formatUnits(limit, 6)})…`);
    await publicClient.waitForTransactionReceipt({ hash: await walletClient.writeContract({
      address: ADDRESSES.MockCreditGatedLender as `0x${string}`,
      abi: MOCK_CREDIT_GATED_LENDER_ABI,
      functionName: "borrow",
      args: [capHash, limit],
    })});
    setCreditLenderDebt(limit);
    log("success", `Borrowed $${formatUnits(limit, 6)} from CreditGatedLender`);
    log("info", "  This lender has never seen this agent before. It trusts the Atlas credit tier.");
  });

  return (
    <div className="flex gap-6 w-full">
      <div className="flex-1 min-w-0 flex flex-col gap-4">

        <div className="rounded-xl border border-purple-700 bg-purple-950/20 p-5">
          <div className="flex items-center gap-3 mb-2">
            <span className="text-2xl">🎫</span>
            <div>
              <h2 className="text-lg font-bold text-purple-300">ZK Credit Passport</h2>
              <p className="text-xs text-slate-400">Cross-protocol agent credit history • Privacy-preserving</p>
            </div>
          </div>
          <p className="text-sm text-slate-300 mt-2">
            Complete Clawloan cycles to build a ZK-verified compliance record. The credit tier unlocks
            higher borrow limits at <strong className="text-purple-300">any</strong> protocol that checks Atlas tiers —
            without revealing individual trades.
          </p>
        </div>

        {/* Tier display */}
        <div className="rounded-xl border border-slate-700 bg-slate-900/50 p-4">
          <div className="text-sm font-bold text-slate-300 mb-3">Current Credit Tier</div>
          <div className="grid grid-cols-5 gap-2">
            {TIER_LABELS.map((label, i) => (
              <div key={label} className={`rounded p-2 text-center text-xs border ${i === tier ? "border-purple-500 bg-purple-950/40" : "border-slate-700 bg-slate-800/30"}`}>
                <div className={`font-bold ${i === tier ? TIER_COLORS[i] : "text-slate-600"}`}>{label}</div>
                <div className={`text-xs mt-1 ${i === tier ? "text-slate-300" : "text-slate-600"}`}>${TIER_LIMITS[i].toLocaleString()}</div>
              </div>
            ))}
          </div>
        </div>

        {/* External lender */}
        {stateRef.current.capHash && (
          <div className="rounded-xl border border-purple-800 bg-purple-950/20 p-4">
            <div className="text-sm font-bold text-purple-300 mb-2">MockCreditGatedLender (external protocol)</div>
            <div className="text-xs text-slate-400 mb-3">
              This lender reads your Atlas credit tier — it has never seen you before, yet it trusts the on-chain proof.
            </div>
            <TxButton
              label={`Borrow Max at ${TIER_LABELS[tier]} Tier ($${TIER_LIMITS[tier].toLocaleString()})`}
              onClick={borrowFromCreditLender}
              disabled={busy || creditLenderDebt > 0n}
              variant="secondary"
            />
            {creditLenderDebt > 0n && (
              <p className="text-xs text-purple-300 mt-2">✓ Borrowed ${formatUnits(creditLenderDebt, 6)} from external lender via Atlas credit tier</p>
            )}
          </div>
        )}

        {/* Cycle runner */}
        <div className="rounded-xl border border-slate-700 bg-slate-900/50 p-4">
          <div className="text-sm font-bold text-slate-300 mb-2">
            Build Credit History — Cycle {stateRef.current.cycle}/3
          </div>
          <p className="text-sm text-slate-400 mb-3">
            Each cycle completes a full Clawloan borrow→repay loop. After each cycle, submit a ZK proof to upgrade your tier.
          </p>
          <div className="flex gap-2">
            <TxButton
              label={`Run Cycle ${stateRef.current.cycle + 1}`}
              onClick={runCycle}
              disabled={busy || phase === "proof"}
            />
            <TxButton
              label="Submit ZK Proof"
              onClick={submitProof}
              disabled={busy || phase !== "proof"}
              variant="secondary"
            />
          </div>
        </div>

        <LogPanel entries={logs} />
      </div>

      {/* Right panel */}
      <div className="w-80 flex-shrink-0 flex flex-col gap-4">
        <div className="rounded-xl border border-purple-700 bg-purple-950/20 p-4 text-xs">
          <h3 className="text-sm font-bold text-purple-300 mb-3">Why this matters</h3>
          <p className="text-slate-400 mb-3">
            Every lending protocol today does trust assessment differently — and agents have no way to
            carry their reputation across protocols. Each integration starts from zero.
          </p>
          <p className="text-slate-400 mb-2">Atlas credit tiers are:</p>
          <ul className="space-y-1 text-slate-400 mb-3">
            <li>✓ <strong className="text-purple-300">Verifiable on-chain</strong> — any protocol can query</li>
            <li>✓ <strong className="text-purple-300">Privacy-preserving</strong> — only tier exposed, not trades</li>
            <li>✓ <strong className="text-purple-300">Cryptographically proven</strong> — ZK proof, not self-reported</li>
            <li>✓ <strong className="text-purple-300">Portable</strong> — follows the agent key, not the platform</li>
          </ul>
          <div className="border-t border-slate-700 pt-2 text-slate-500">
            As more protocols integrate Atlas tier checks, agents are incentivized to build credit history
            through Atlas. The trust layer compounds — this is the data network effect moat.
          </div>
        </div>

        <div className="rounded-xl border border-slate-700 bg-slate-900/50 p-4 text-xs">
          <div className="font-semibold text-slate-300 mb-2">ZK Proof Content</div>
          <p className="text-slate-500 mb-2">The proof attests:</p>
          <ul className="space-y-1 text-slate-400">
            <li>• N intents executed</li>
            <li>• All within capability bounds</li>
            <li>• Constraint violation rate: 0%</li>
            <li>• No individual trade details revealed</li>
          </ul>
          <p className="text-slate-500 mt-2">
            A hedge fund can require a ZK compliance proof before granting a $1M/day capability.
            The agent proves trustworthiness without surveillance.
          </p>
        </div>
      </div>
    </div>
  );
}
