/**
 * Phase 3 — Sub-agent Orchestration Scenario
 *
 * Narrative: An orchestrator AI agent manages a $3,000 USDC budget across two
 * specialised sub-agents (Alpha: yield-farming bot, Beta: arbitrage bot). Each
 * sub-agent operates independently under a capped budget slice, runs its own
 * Clawloan credit cycle, and reports back to the orchestrator hub. Atlas enforces
 * that no sub-agent can spend beyond its allocation.
 *
 * Architecture:
 *  - MockSubAgentHub: on-chain allocation ledger (orchestrator budget + per-agent slices)
 *  - MockClawloanPool: provides credit to each bot independently (botId 2 = Alpha, botId 3 = Beta)
 *  - EnvelopeRegistry: enforces repayment for both agents
 *  - CapabilityKernel: checks parentCapabilityHash (depth=0 in Phase 1, full chain in Phase 2)
 *
 * Sub-agent flow (identical for Alpha and Beta):
 *   1. Hub.registerAgent()  — allocate budget slice
 *   2. pool.borrow()        — take on credit
 *   3. Hub.recordBorrow()   — update orchestrator ledger
 *   4. Mint earnings + deposit into vault
 *   5. Sign + register envelope
 *   6. Keeper trigger (repay loan)
 *   7. Hub.recordRepay()    — update orchestrator ledger
 *   8. Submit credit proof
 */
import { useState, useCallback, useEffect, useRef } from "react";
import { useAccount, useWalletClient, usePublicClient, useBalance } from "wagmi";
import { toHex, parseUnits } from "viem";

import { ADDRESSES, ANVIL_CHAIN_ID } from "../contracts/addresses";
import {
  ERC20_ABI,
  CLAWLOAN_POOL_ABI,
  VAULT_ABI,
  REGISTRY_ABI,
  CREDIT_VERIFIER_ABI,
  ACCUMULATOR_ABI,
  SUB_AGENT_HUB_ABI,
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
  hashPosition,
  hashCapability,
  hashEnvelope,
  ZERO_ADDRESS,
  ComparisonOp,
  LogicOp,
} from "@atlas-protocol/sdk";
import type { Position, Capability, Intent, Conditions } from "@atlas-protocol/sdk";
import { encodeAbiParameters } from "viem";

// ─── Constants ────────────────────────────────────────────────────────────────
const ORCH_BUDGET = parseUnits("3000", 6);   // $3,000 total orchestrator budget
const BORROW_AMT  = parseUnits("500", 6);    // $500 per sub-agent borrow
const EARN_AMT    = parseUnits("1000", 6);   // $1,000 per sub-agent earnings
const BUDGET_A    = parseUnits("1500", 6);   // Alpha's slice
const BUDGET_B    = parseUnits("1500", 6);   // Beta's slice
const LOAN_WIN    = 7 * 24 * 60 * 60;       // 7-day loan window

const SUB_AGENTS = [
  { id: 2, key: "alpha" as const, name: "Sub-agent Alpha", icon: "⚡", task: "Yield-farming bot",   color: "text-cyan-400",   bg: "bg-cyan-950/40",   border: "border-cyan-700",   budget: BUDGET_A },
  { id: 3, key: "beta"  as const, name: "Sub-agent Beta",  icon: "🔀", task: "Arbitrage bot",       color: "text-violet-400", bg: "bg-violet-950/40", border: "border-violet-700", budget: BUDGET_B },
] as const;
type AgentKey = "alpha" | "beta";

interface AgentDemoState {
  positionHash?:   `0x${string}`;
  envelopeHash?:   `0x${string}`;
  capabilityHash?: `0x${string}`;
  position?:       Position;
  spendCap?:       Capability;
  intent?:         Intent;
  capSig?:         `0x${string}`;
  intentSig?:      `0x${string}`;
  conditions?:     Conditions;
  loanDeadline?:   bigint;
  registered?:     boolean;
  borrowed?:       boolean;
  repaid?:         boolean;
  credited?:       boolean;
}

interface HubMetrics {
  orchestratorBudget: bigint;
  totalAllocated:     bigint;
  totalBorrowed:      bigint;
  totalRepaid:        bigint;
  totalProfit:        bigint;
  agentCount:         bigint;
}

export function SubAgentScenario() {
  const { address, isConnected }  = useAccount();
  const { data: walletClient }    = useWalletClient();
  const publicClient              = usePublicClient();

  const [agents, setAgents] = useState<Record<AgentKey, AgentDemoState>>({ alpha: {}, beta: {} });
  const [hub, setHub]       = useState<HubMetrics>({
    orchestratorBudget: ORCH_BUDGET,
    totalAllocated: 0n,
    totalBorrowed: 0n,
    totalRepaid: 0n,
    totalProfit: 0n,
    agentCount: 0n,
  });
  const [logs,  setLogs]  = useState<LogEntry[]>([]);
  const [busy,  setBusy]  = useState<Record<string, boolean>>({});
  const logId = useRef(0);

  const log = useCallback((level: LogEntry["level"], message: string) => {
    setLogs(prev => [...prev, { id: ++logId.current, ts: Date.now(), level, message }]);
  }, []);

  const withBusy = useCallback(async (key: string, fn: () => Promise<void>) => {
    setBusy(b => ({ ...b, [key]: true }));
    try { await fn(); }
    catch (e: unknown) {
      const msg = e instanceof Error ? e.message : String(e);
      console.error("[SubAgent]", e);
      log("error", msg.slice(0, 300));
    }
    finally { setBusy(b => ({ ...b, [key]: false })); }
  }, [log]);

  // Auto-airdrop ETH
  const { data: ethBalance } = useBalance({ address });
  const airdropped = useRef<string | null>(null);
  useEffect(() => {
    if (!address || !isConnected) return;
    if (airdropped.current === address) return;
    if (ethBalance && ethBalance.value >= parseUnits("1", 18)) return;
    airdropped.current = address;
    fetch("http://127.0.0.1:8545", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "anvil_setBalance", params: [address, toHex(parseUnits("10", 18))] }),
    }).catch(() => {});
  }, [address, isConnected, ethBalance]);

  // Poll hub metrics
  const pollHub = useCallback(async () => {
    if (!publicClient) return;
    try {
      const [budget, allocated, borrowed, repaid, profit, count] = await Promise.all([
        publicClient.readContract({ address: ADDRESSES.MockSubAgentHub as `0x${string}`, abi: SUB_AGENT_HUB_ABI, functionName: "orchestratorBudget" }) as Promise<bigint>,
        publicClient.readContract({ address: ADDRESSES.MockSubAgentHub as `0x${string}`, abi: SUB_AGENT_HUB_ABI, functionName: "totalAllocated" }) as Promise<bigint>,
        publicClient.readContract({ address: ADDRESSES.MockSubAgentHub as `0x${string}`, abi: SUB_AGENT_HUB_ABI, functionName: "totalBorrowed" }) as Promise<bigint>,
        publicClient.readContract({ address: ADDRESSES.MockSubAgentHub as `0x${string}`, abi: SUB_AGENT_HUB_ABI, functionName: "totalRepaid" }) as Promise<bigint>,
        publicClient.readContract({ address: ADDRESSES.MockSubAgentHub as `0x${string}`, abi: SUB_AGENT_HUB_ABI, functionName: "totalProfit" }) as Promise<bigint>,
        publicClient.readContract({ address: ADDRESSES.MockSubAgentHub as `0x${string}`, abi: SUB_AGENT_HUB_ABI, functionName: "agentCount" }) as Promise<bigint>,
      ]);
      setHub({ orchestratorBudget: budget, totalAllocated: allocated, totalBorrowed: borrowed, totalRepaid: repaid, totalProfit: profit, agentCount: count });
    } catch { /* Hub not deployed yet */ }
  }, [publicClient]);

  useEffect(() => {
    pollHub();
    const t = setInterval(pollHub, 4000);
    return () => clearInterval(t);
  }, [pollHub]);

  const setAgent = (key: AgentKey, updater: (prev: AgentDemoState) => AgentDemoState) => {
    setAgents(a => ({ ...a, [key]: updater(a[key]) }));
  };

  // ── Register sub-agent in hub ───────────────────────────────────────────────
  async function registerInHub(agentDef: typeof SUB_AGENTS[number]) {
    await withBusy(`reg_${agentDef.key}`, async () => {
      if (!walletClient || !address) throw new Error("wallet not connected");

      log("info", `[${agentDef.name}] Registering in orchestrator hub with $${Number(agentDef.budget) / 1e6} budget…`);
      const hash = await walletClient.writeContract({
        address: ADDRESSES.MockSubAgentHub as `0x${string}`,
        abi: SUB_AGENT_HUB_ABI,
        functionName: "registerAgent",
        args: [BigInt(agentDef.id), address, agentDef.name, agentDef.budget],
      });
      await publicClient!.waitForTransactionReceipt({ hash });
      log("success", `[${agentDef.name}] Registered — budget $${Number(agentDef.budget) / 1e6} allocated from orchestrator's $${Number(ORCH_BUDGET) / 1e6}`);
      setAgent(agentDef.key, a => ({ ...a, registered: true }));
      await pollHub();
    });
  }

  // ── Full Clawloan cycle for a sub-agent ────────────────────────────────────
  async function runCycle(agentDef: typeof SUB_AGENTS[number]) {
    await withBusy(`cycle_${agentDef.key}`, async () => {
      if (!walletClient || !address) throw new Error("wallet not connected");
      const botId = BigInt(agentDef.id);

      // 1. Borrow from pool
      log("info", `[${agentDef.name}] Borrowing $${Number(BORROW_AMT) / 1e6} from Clawloan (botId ${botId})…`);
      const borrowHash = await walletClient.writeContract({
        address: ADDRESSES.MockClawloanPool as `0x${string}`,
        abi: CLAWLOAN_POOL_ABI,
        functionName: "borrow",
        args: [botId, BORROW_AMT],
      });
      await publicClient!.waitForTransactionReceipt({ hash: borrowHash });

      // 2. Record borrow in hub
      await walletClient.writeContract({
        address: ADDRESSES.MockSubAgentHub as `0x${string}`,
        abi: SUB_AGENT_HUB_ABI,
        functionName: "recordBorrow",
        args: [botId, BORROW_AMT],
      });
      log("success", `[${agentDef.name}] Borrowed $${Number(BORROW_AMT) / 1e6} — orchestrator ledger updated`);
      setAgent(agentDef.key, a => ({ ...a, borrowed: true }));
      await pollHub();

      // 3. Mint task earnings
      log("info", `[${agentDef.name}] Minting $${Number(EARN_AMT) / 1e6} task earnings…`);
      const mintHash = await walletClient.writeContract({
        address: ADDRESSES.MockUSDC as `0x${string}`,
        abi: ERC20_ABI,
        functionName: "mint",
        args: [address, EARN_AMT],
      });
      await publicClient!.waitForTransactionReceipt({ hash: mintHash });

      // 4. Approve vault
      const allowance = await publicClient!.readContract({
        address: ADDRESSES.MockUSDC as `0x${string}`,
        abi: ERC20_ABI,
        functionName: "allowance",
        args: [address, ADDRESSES.SingletonVault as `0x${string}`],
      }) as bigint;
      if (allowance < EARN_AMT) {
        const approveHash = await walletClient.writeContract({
          address: ADDRESSES.MockUSDC as `0x${string}`,
          abi: ERC20_ABI,
          functionName: "approve",
          args: [ADDRESSES.SingletonVault as `0x${string}`, BigInt("0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff")],
        });
        await publicClient!.waitForTransactionReceipt({ hash: approveHash });
      }

      // 5. Deposit into vault
      const salt = randomSalt();
      log("info", `[${agentDef.name}] Depositing $${Number(EARN_AMT) / 1e6} into vault…`);
      const depositHash = await walletClient.writeContract({
        address: ADDRESSES.SingletonVault as `0x${string}`,
        abi: VAULT_ABI,
        functionName: "deposit",
        args: [ADDRESSES.MockUSDC as `0x${string}`, EARN_AMT, salt],
      });
      const depositReceipt = await publicClient!.waitForTransactionReceipt({ hash: depositHash });
      if (depositReceipt.status === "reverted") throw new Error("Deposit reverted");

      const pos: Position = { owner: address, asset: ADDRESSES.MockUSDC as `0x${string}`, amount: EARN_AMT, salt };
      const posHash = hashPosition(pos);

      // 6. Build + sign envelope — use on-chain timestamp, not Date.now().
      // Anvil may have been time-warped by a prior demo run; Date.now() would produce
      // a deadline already in the past, causing register() to throw EnvelopeNotActive().
      const latestBlock = await publicClient!.getBlock({ blockTag: "latest" });
      const now        = latestBlock.timestamp;
      const deadline   = now + BigInt(LOAN_WIN);
      const capExpiry  = now + BigInt(30 * 24 * 60 * 60);
      const capNonce   = randomSalt();
      const intentNonce = randomSalt();
      const manageNonce = randomSalt();

      const liveDebt = await publicClient!.readContract({
        address: ADDRESSES.MockClawloanPool as `0x${string}`,
        abi: CLAWLOAN_POOL_ABI,
        functionName: "getDebt",
        args: [botId],
      }) as bigint;

      const adapterData = clawloanRepayLive(ADDRESSES.MockClawloanPool as `0x${string}`, botId, liveDebt);

      const spendCap = buildCapability({
        issuer: address, grantee: address, expiry: capExpiry, nonce: capNonce,
        constraints: {
          maxSpendPerPeriod: 0n, periodDuration: 0n, minReturnBps: 0n,
          allowedAdapters:  [ADDRESSES.ClawloanRepayAdapter as `0x${string}`],
          allowedTokensIn:  [ADDRESSES.MockUSDC as `0x${string}`],
          allowedTokensOut: [ADDRESSES.MockUSDC as `0x${string}`],
        },
      });

      const intent = buildIntent({
        position: pos, capability: spendCap,
        adapter: ADDRESSES.ClawloanRepayAdapter as `0x${string}`, adapterData,
        minReturn: parseUnits("10", 6), deadline: capExpiry, nonce: intentNonce,
        outputToken: ADDRESSES.MockUSDC as `0x${string}`, returnTo: ZERO_ADDRESS,
        submitter: ADDRESSES.EnvelopeRegistry as `0x${string}`, solverFeeBps: 10,
      });

      const manageCap = buildManageCapability({
        issuer: address, grantee: address, expiry: capExpiry, nonce: manageNonce,
      });

      const conditions: Conditions = {
        priceOracle: ADDRESSES.MockTimestampOracle as `0x${string}`,
        baseToken: ZERO_ADDRESS, quoteToken: ZERO_ADDRESS,
        triggerPrice: deadline, op: ComparisonOp.GREATER_THAN,
        secondaryOracle: ZERO_ADDRESS, secondaryTriggerPrice: 0n,
        secondaryOp: ComparisonOp.LESS_THAN, logicOp: LogicOp.AND,
      };

      const envelope = buildEnvelope({
        position: pos, conditions, intent, manageCapability: manageCap,
        expiry: deadline + BigInt(24 * 60 * 60), keeperRewardBps: 10, minKeeperRewardWei: 0n,
      });

      log("info", `[${agentDef.name}] Signing 3 authorization messages…`);
      const capSig       = await signCapability(walletClient, spendCap, ADDRESSES.CapabilityKernel as `0x${string}`, ANVIL_CHAIN_ID);
      const intentSig    = await signIntent(walletClient, intent, ADDRESSES.CapabilityKernel as `0x${string}`, ANVIL_CHAIN_ID);
      const manageCapSig = await signManageCapability(walletClient, manageCap, ADDRESSES.EnvelopeRegistry as `0x${string}`, ANVIL_CHAIN_ID);

      // 7. Register envelope
      log("info", `[${agentDef.name}] Registering repayment envelope…`);

      try {
        await publicClient!.simulateContract({
          address: ADDRESSES.EnvelopeRegistry as `0x${string}`,
          abi: REGISTRY_ABI,
          functionName: "register",
          args: [envelope as never, manageCap as never, manageCapSig, pos as never],
          account: address,
        });
      } catch (simErr: unknown) {
        const msg = simErr instanceof Error ? simErr.message : String(simErr);
        throw new Error(`Register sim: ${msg.slice(0, 200)}`);
      }

      const regHash = await walletClient.writeContract({
        address: ADDRESSES.EnvelopeRegistry as `0x${string}`,
        abi: REGISTRY_ABI,
        functionName: "register",
        args: [envelope as never, manageCap as never, manageCapSig, pos as never],
      });
      await publicClient!.waitForTransactionReceipt({ hash: regHash });

      const envelopeHash = hashEnvelope(envelope);
      const capHash      = hashCapability(spendCap);

      setAgent(agentDef.key, a => ({ ...a, positionHash: posHash, position: pos, spendCap, intent, capSig, intentSig, conditions, loanDeadline: deadline, envelopeHash, capabilityHash: capHash }));
      log("success", `[${agentDef.name}] Envelope ${envelopeHash.slice(0, 10)}… registered — agent can go offline`);

      // 8. Warp time + trigger
      log("info", `[${agentDef.name}] Keeper: warping time past deadline…`);
      const latestBlockWarp = await publicClient!.getBlock({ blockTag: "latest" });
      const minTs           = latestBlockWarp.timestamp + 1n;
      const targetTs    = deadline + 1n > minTs ? deadline + 1n : minTs;
      await publicClient!.request({ method: "evm_setNextBlockTimestamp" as never, params: [toHex(targetTs)] as never });
      await publicClient!.request({ method: "evm_mine" as never, params: [] as never });

      try {
        await publicClient!.simulateContract({
          address: ADDRESSES.EnvelopeRegistry as `0x${string}`,
          abi: REGISTRY_ABI,
          functionName: "trigger",
          args: [envelopeHash, conditions as never, pos as never, intent as never, spendCap as never, capSig, intentSig],
          account: address,
        });
      } catch (simErr: unknown) {
        const msg = simErr instanceof Error ? simErr.message : String(simErr);
        throw new Error(`Trigger sim: ${msg.slice(0, 200)}`);
      }

      const triggerHash = await walletClient.writeContract({
        address: ADDRESSES.EnvelopeRegistry as `0x${string}`,
        abi: REGISTRY_ABI,
        functionName: "trigger",
        args: [envelopeHash, conditions as never, pos as never, intent as never, spendCap as never, capSig, intentSig],
      });
      const triggerReceipt = await publicClient!.waitForTransactionReceipt({ hash: triggerHash });
      if (triggerReceipt.status === "reverted") throw new Error("Trigger reverted");

      // 9. Record repay in hub
      await walletClient.writeContract({
        address: ADDRESSES.MockSubAgentHub as `0x${string}`,
        abi: SUB_AGENT_HUB_ABI,
        functionName: "recordRepay",
        args: [botId, liveDebt],
      });
      log("success", `[${agentDef.name}] Loan repaid — keeper fee earned, surplus back to vault`);
      setAgent(agentDef.key, a => ({ ...a, repaid: true }));
      await pollHub();

      // 10. Submit credit proof
      const receiptHashes = await publicClient!.readContract({
        address: ADDRESSES.ReceiptAccumulator as `0x${string}`,
        abi: ACCUMULATOR_ABI,
        functionName: "getReceiptHashes",
        args: [capHash],
      }) as `0x${string}`[];

      const nullifiers = await publicClient!.readContract({
        address: ADDRESSES.ReceiptAccumulator as `0x${string}`,
        abi: ACCUMULATOR_ABI,
        functionName: "getNullifiers",
        args: [capHash],
      }) as `0x${string}`[];

      const n = BigInt(receiptHashes.length);
      if (n > 0n) {
        const adapters   = Array(receiptHashes.length).fill(ADDRESSES.ClawloanRepayAdapter);
        const amountsIn  = Array(receiptHashes.length).fill(EARN_AMT);
        const amountsOut = Array(receiptHashes.length).fill(parseUnits("3", 6));

        const proof = encodeAbiParameters(
          [{ type: "bytes32[]" }, { type: "bytes32[]" }, { type: "address[]" }, { type: "uint256[]" }, { type: "uint256[]" }],
          [receiptHashes, nullifiers, adapters as `0x${string}`[], amountsIn, amountsOut]
        );

        const creditHash = await walletClient.writeContract({
          address: ADDRESSES.CreditVerifier as `0x${string}`,
          abi: CREDIT_VERIFIER_ABI,
          functionName: "submitProof",
          args: [capHash, n, ADDRESSES.ClawloanRepayAdapter as `0x${string}`, 0n, proof],
        });
        await publicClient!.waitForTransactionReceipt({ hash: creditHash });
        log("success", `[${agentDef.name}] Credit tier upgraded — proof verified on-chain`);
        setAgent(agentDef.key, a => ({ ...a, credited: true }));
      } else {
        log("warn", `[${agentDef.name}] No receipts found — credit proof skipped`);
      }
    });
  }

  function resetAll() {
    setAgents({ alpha: {}, beta: {} });
    setLogs([]);
    log("info", "All sub-agents reset — orchestrator metrics will refresh shortly");
  }

  const allDone = SUB_AGENTS.every(a => agents[a.key].credited);
  const anyRepaid = SUB_AGENTS.some(a => agents[a.key].repaid);

  return (
    <div className="flex-1 p-6 max-w-7xl mx-auto w-full space-y-6">

      {/* Header explainer */}
      <div className="rounded-2xl border border-cyan-800/40 bg-cyan-950/20 p-5">
        <div className="flex items-start gap-4">
          <span className="text-3xl mt-0.5">🤖</span>
          <div>
            <h2 className="text-lg font-bold text-cyan-300 mb-1">Sub-agent Fleet Orchestration</h2>
            <p className="text-sm text-zinc-400 leading-relaxed">
              An orchestrator controls a <strong className="text-white">$3,000 USDC</strong> budget and
              deploys two specialised sub-agents, each with a <strong className="text-white">$1,500 USDC</strong>{" "}
              allocation slice. Each sub-agent independently borrows from Clawloan, completes a task,
              and has its repayment auto-enforced by Atlas — all under the orchestrator's budget cap.
            </p>
            <div className="mt-3 grid grid-cols-3 gap-2 text-xs">
              <div className="rounded-lg bg-zinc-800/50 p-2 text-center">
                <div className="text-cyan-300 font-bold">Budget-bound</div>
                <div className="text-zinc-500">Hub enforces per-agent caps</div>
              </div>
              <div className="rounded-lg bg-zinc-800/50 p-2 text-center">
                <div className="text-cyan-300 font-bold">Parallel execution</div>
                <div className="text-zinc-500">Both agents operate simultaneously</div>
              </div>
              <div className="rounded-lg bg-zinc-800/50 p-2 text-center">
                <div className="text-cyan-300 font-bold">Aggregated credit</div>
                <div className="text-zinc-500">Each agent builds independent history</div>
              </div>
            </div>
          </div>
        </div>
      </div>

      {/* Orchestrator dashboard */}
      <div className="rounded-2xl border border-zinc-700 bg-zinc-900 p-5">
        <h3 className="text-sm font-semibold text-zinc-200 mb-4 flex items-center gap-2">
          <span>🧠</span> Orchestrator Dashboard
          <span className="ml-auto text-xs text-zinc-600">MockSubAgentHub on-chain</span>
        </h3>

        <div className="grid grid-cols-2 md:grid-cols-5 gap-3 mb-4">
          <OrchestratorMetric label="Total Budget" value={`$${Number(hub.orchestratorBudget) / 1e6}`} color="text-zinc-200" />
          <OrchestratorMetric label="Allocated" value={`$${Number(hub.totalAllocated) / 1e6}`} color="text-indigo-400" />
          <OrchestratorMetric label="Outstanding Debt" value={`$${Number(hub.totalBorrowed) / 1e6}`} color={hub.totalBorrowed > 0n ? "text-red-400" : "text-zinc-500"} />
          <OrchestratorMetric label="Total Repaid" value={`$${Number(hub.totalRepaid) / 1e6}`} color="text-emerald-400" />
          <OrchestratorMetric label="Fleet P&L" value={`+$${Number(hub.totalProfit) / 1e6}`} color={hub.totalProfit > 0n ? "text-cyan-400" : "text-zinc-500"} />
        </div>

        {/* Budget utilisation bar */}
        <div className="space-y-1.5">
          <div className="flex justify-between text-xs text-zinc-500">
            <span>Budget utilisation</span>
            <span>{hub.orchestratorBudget > 0n ? Math.round(Number(hub.totalAllocated) * 100 / Number(hub.orchestratorBudget)) : 0}% allocated</span>
          </div>
          <div className="w-full h-2 bg-zinc-700 rounded-full overflow-hidden">
            <div
              className="h-full bg-gradient-to-r from-cyan-600 to-cyan-400 transition-all duration-700"
              style={{ width: hub.orchestratorBudget > 0n ? `${Math.min(100, Number(hub.totalAllocated) * 100 / Number(hub.orchestratorBudget))}%` : "0%" }}
            />
          </div>
          <div className="flex justify-between text-xs text-zinc-600">
            <span>$0</span>
            <span className="text-cyan-600">Allocated: ${Number(hub.totalAllocated) / 1e6}</span>
            <span>${Number(hub.orchestratorBudget) / 1e6}</span>
          </div>
        </div>
      </div>

      {/* Sub-agent cards */}
      <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
        {SUB_AGENTS.map(agentDef => {
          const ag = agents[agentDef.key];
          return (
            <SubAgentCard
              key={agentDef.key}
              agentDef={agentDef}
              state={ag}
              isConnected={isConnected}
              busy={busy}
              onRegister={() => registerInHub(agentDef)}
              onRunCycle={() => runCycle(agentDef)}
            />
          );
        })}
      </div>

      {/* Delegation architecture */}
      <div className="rounded-2xl border border-zinc-800 bg-zinc-900 p-5">
        <h3 className="text-sm font-semibold text-zinc-200 mb-4 flex items-center gap-2">
          <span>🔗</span> Capability Delegation Architecture
        </h3>
        <div className="flex items-stretch gap-0">
          {/* Orchestrator node */}
          <div className="flex-1 rounded-xl border border-zinc-600 bg-zinc-800/60 p-4 flex flex-col items-center gap-2">
            <div className="w-10 h-10 rounded-full bg-zinc-700 border border-zinc-600 flex items-center justify-center text-xl">🧠</div>
            <div className="text-xs font-semibold text-zinc-200">Orchestrator</div>
            <div className="text-xs text-zinc-500 text-center">depth=0 capability<br/>$3,000 USDC budget</div>
            <div className="text-xs text-indigo-400 font-mono text-center">parentHash = 0x0</div>
          </div>

          {/* Arrow */}
          <div className="flex flex-col items-center justify-center px-3 gap-1">
            <div className="text-zinc-600 text-xs">delegates</div>
            <div className="text-zinc-500 text-lg">→</div>
            <div className="text-zinc-600 text-xs">to each</div>
          </div>

          {/* Sub-agents */}
          <div className="flex-1 flex flex-col gap-2">
            {SUB_AGENTS.map(a => (
              <div key={a.key} className={`rounded-xl border ${a.border} ${a.bg} p-3 flex items-center gap-3`}>
                <span className="text-xl">{a.icon}</span>
                <div className="flex-1 min-w-0">
                  <div className={`text-xs font-semibold ${a.color}`}>{a.name}</div>
                  <div className="text-xs text-zinc-500">depth=0 · $1,500 USDC slice</div>
                  <div className="text-xs text-zinc-600 font-mono">botId={a.id}</div>
                </div>
                <div className={`text-xs font-medium ${agents[a.key].credited ? "text-emerald-400" : agents[a.key].repaid ? "text-amber-400" : agents[a.key].registered ? a.color : "text-zinc-600"}`}>
                  {agents[a.key].credited ? "✓ done" : agents[a.key].repaid ? "⟳ proving" : agents[a.key].borrowed ? "● active" : agents[a.key].registered ? "● ready" : "○ idle"}
                </div>
              </div>
            ))}
          </div>

          {/* Phase 2 note */}
          <div className="flex flex-col items-center justify-center px-3">
            <div className="text-xs text-zinc-700 text-center leading-relaxed">
              Phase 2:<br/>
              <span className="text-zinc-600">parentHash chain<br/>enforced on-chain</span>
            </div>
          </div>
        </div>
        <p className="text-xs text-zinc-600 mt-3">
          Phase 1: MockSubAgentHub enforces budget at the application layer.{" "}
          Phase 2+: CapabilityKernel will verify the full delegation chain on-chain
          using <span className="font-mono">parentCapabilityHash</span> and <span className="font-mono">delegationDepth</span>.
        </p>
      </div>

      {/* All done */}
      {allDone && (
        <div className="rounded-2xl border border-cyan-700 bg-cyan-950/30 p-5 flex items-center justify-between gap-4">
          <div>
            <p className="text-cyan-300 font-semibold text-sm">✓ All sub-agents completed their cycles</p>
            <p className="text-zinc-400 text-xs mt-1">
              Fleet P&L: +${Number(hub.totalProfit) / 1e6} USDC · {Number(hub.agentCount)} agents ·{" "}
              Both credit tiers upgraded independently.
            </p>
          </div>
          <button
            onClick={resetAll}
            className="text-xs px-4 py-2 rounded-xl bg-zinc-800 hover:bg-zinc-700 text-zinc-300 border border-zinc-700 transition-colors shrink-0"
          >
            Reset fleet →
          </button>
        </div>
      )}

      {/* Log */}
      <div>
        <h2 className="text-sm font-semibold text-zinc-300 mb-2">Fleet Activity Log</h2>
        <LogPanel entries={logs} />
      </div>

      {void anyRepaid}
    </div>
  );
}

// ── Sub-agent card ─────────────────────────────────────────────────────────────

interface SubAgentCardProps {
  agentDef:    typeof SUB_AGENTS[number];
  state:       AgentDemoState;
  isConnected: boolean;
  busy:        Record<string, boolean>;
  onRegister:  () => void;
  onRunCycle:  () => void;
}

function SubAgentCard({ agentDef, state, isConnected, busy, onRegister, onRunCycle }: SubAgentCardProps) {
  const steps = [
    { label: "Registered in hub",   done: !!state.registered },
    { label: "Borrowed from pool",  done: !!state.borrowed },
    { label: "Envelope registered", done: !!state.envelopeHash },
    { label: "Loan repaid",         done: !!state.repaid },
    { label: "Credit proof",        done: !!state.credited },
  ];

  const completed = steps.filter(s => s.done).length;
  const pct = Math.round((completed / steps.length) * 100);

  return (
    <div className={`rounded-2xl border ${agentDef.border} bg-zinc-900 p-5`}>
      {/* Header */}
      <div className="flex items-center gap-3 mb-4">
        <div className={`w-10 h-10 rounded-full ${agentDef.bg} border ${agentDef.border} flex items-center justify-center text-xl`}>
          {agentDef.icon}
        </div>
        <div className="flex-1">
          <div className={`text-sm font-semibold ${agentDef.color}`}>{agentDef.name}</div>
          <div className="text-xs text-zinc-500">{agentDef.task} · botId={agentDef.id}</div>
        </div>
        <div className={`text-xs font-mono px-2 py-0.5 rounded-full border ${agentDef.border} ${agentDef.bg} ${agentDef.color}`}>
          ${Number(agentDef.budget) / 1e6} cap
        </div>
      </div>

      {/* Progress bar */}
      <div className="mb-4">
        <div className="flex justify-between text-xs text-zinc-500 mb-1.5">
          <span>Cycle progress</span>
          <span>{completed}/{steps.length} steps</span>
        </div>
        <div className="w-full h-1.5 bg-zinc-700 rounded-full overflow-hidden">
          <div
            className={`h-full rounded-full transition-all duration-700 ${
              state.credited ? "bg-emerald-400" :
              state.repaid   ? "bg-amber-400" :
              state.borrowed ? agentDef.key === "alpha" ? "bg-cyan-400" : "bg-violet-400" :
              "bg-zinc-500"
            }`}
            style={{ width: `${pct}%` }}
          />
        </div>
      </div>

      {/* Step checklist */}
      <div className="space-y-1.5 mb-4">
        {steps.map(s => (
          <div key={s.label} className="flex items-center gap-2 text-xs">
            <span className={s.done ? "text-emerald-400" : "text-zinc-700"}>
              {s.done ? "✓" : "○"}
            </span>
            <span className={s.done ? "text-zinc-300" : "text-zinc-600"}>{s.label}</span>
          </div>
        ))}
      </div>

      {/* Actions */}
      <div className="flex flex-col gap-2">
        {!state.registered && (
          <TxButton
            label={`Register ${agentDef.name} in hub`}
            onClick={onRegister}
            loading={busy[`reg_${agentDef.key}`]}
            disabled={!isConnected}
          />
        )}
        {state.registered && !state.credited && (
          <TxButton
            label={`⚡ Run full cycle (${agentDef.name})`}
            onClick={onRunCycle}
            loading={busy[`cycle_${agentDef.key}`]}
            disabled={!isConnected || !!state.credited}
            variant="keeper"
          />
        )}
        {state.credited && (
          <div className={`rounded-xl border ${agentDef.border} ${agentDef.bg} px-3 py-2 text-xs text-center ${agentDef.color} font-medium`}>
            ✓ Cycle complete — credit tier upgraded
          </div>
        )}
      </div>

      {/* Envelope hash if available */}
      {state.envelopeHash && (
        <div className="mt-3 text-xs text-zinc-600 font-mono truncate">
          env: {state.envelopeHash.slice(0, 18)}…
        </div>
      )}
    </div>
  );
}

// ── Helper components ─────────────────────────────────────────────────────────

function OrchestratorMetric({ label, value, color }: { label: string; value: string; color: string }) {
  return (
    <div className="rounded-lg bg-zinc-800/50 p-3 text-center">
      <div className="text-xs text-zinc-500 mb-1">{label}</div>
      <div className={`text-base font-bold ${color}`}>{value}</div>
    </div>
  );
}
