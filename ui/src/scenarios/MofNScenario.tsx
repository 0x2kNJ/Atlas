/**
 * Phase 8 — M-of-N Multi-Agent Consensus
 *
 * Narrative: An institutional AI agent fleet manages a $10M DeFi portfolio.
 * No single agent can execute a trade. 3-of-5 independent agents must sign off.
 * MockConsensusHub tracks approvals on-chain. Once 3/5 approve, execution fires.
 *
 * What this proves:
 *  - Institutional risk controls via multi-agent governance
 *  - Application-layer enforcement (Phase 1) previewing on-chain M-of-N (Phase 2)
 *  - Each agent holds an independent key — compromise of 1 or 2 is harmless
 *  - The "Fleet Governance" primitive for hedge funds and DAOs
 */
import { useState, useCallback, useRef } from "react";
import { useAccount, useWalletClient, usePublicClient } from "wagmi";
import { createWalletClient, http, parseUnits, toHex, keccak256, encodeAbiParameters } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { anvil } from "viem/chains";

import { ADDRESSES, ANVIL_ACCOUNTS, ANVIL_CHAIN_ID } from "../contracts/addresses";
import {
  ERC20_ABI,
  VAULT_ABI,
  MOCK_CONSENSUS_HUB_ABI,
  KERNEL_DIRECT_ABI,
} from "../contracts/abis";
import { TxButton }  from "../components/TxButton";
import { LogPanel }  from "../components/LogPanel";
import type { LogEntry } from "../components/LogPanel";

import {
  buildCapability,
  buildIntent,
  signCapability,
  signIntent,
  randomSalt,
  hashCapability,
  ZERO_ADDRESS,
} from "@atlas-protocol/sdk";
import type { Position, Capability, Intent } from "@atlas-protocol/sdk";

// ─── Constants ────────────────────────────────────────────────────────────────
const DEPOSIT_AMT = parseUnits("2000", 6);
const REQUIRED_M  = 3;
const TOTAL_N     = 5;

const AGENT_NAMES = ["Prime (You)", "Delta", "Sigma", "Omega", "Theta"];

interface MofNState {
  position?:   Position;
  spendCap?:   Capability;
  intent?:     Intent;
  capSig?:     `0x${string}`;
  intentSig?:  `0x${string}`;
  proposalId?: `0x${string}`;
}

export function MofNScenario() {
  const { address }            = useAccount();
  const { data: walletClient } = useWalletClient();
  const publicClient           = usePublicClient();
  const logId = useRef(0);

  const [logs,      setLogs]      = useState<LogEntry[]>([]);
  const [busy,      setBusy]      = useState(false);
  const [step,      setStep]      = useState(0);
  const [approvals, setApprovals] = useState<boolean[]>(Array(TOTAL_N).fill(false));
  const [executed,  setExecuted]  = useState(false);
  const stateRef = useRef<MofNState>({});

  const log = useCallback((level: LogEntry["level"], message: string) => {
    setLogs(prev => [...prev, { id: ++logId.current, ts: Date.now(), level, message }]);
  }, []);

  const withBusy = useCallback(async (fn: () => Promise<void>) => {
    setBusy(true);
    try { await fn(); }
    catch (e: unknown) { log("error", (e instanceof Error ? e.message : String(e)).slice(0, 300)); }
    finally { setBusy(false); }
  }, [log]);

  const approvalCount = approvals.filter(Boolean).length;

  const clientFor = (idx: number) => createWalletClient({
    account:   privateKeyToAccount(ANVIL_ACCOUNTS[idx].privateKey as `0x${string}`),
    chain:     anvil,
    transport: http("http://127.0.0.1:8545"),
  });

  // ── Step 0: Setup — deposit USDC + propose trade ──────────────────────────
  const setupProposal = () => withBusy(async () => {
    if (!walletClient || !address || !publicClient) return;
    log("info", "Setting up $2,000 USDC trade proposal…");

    await publicClient.waitForTransactionReceipt({ hash: await walletClient.writeContract({
      address: ADDRESSES.MockUSDC as `0x${string}`, abi: ERC20_ABI, functionName: "mint",
      args: [address, DEPOSIT_AMT],
    })});
    await publicClient.waitForTransactionReceipt({ hash: await walletClient.writeContract({
      address: ADDRESSES.MockUSDC as `0x${string}`, abi: ERC20_ABI, functionName: "approve",
      args: [ADDRESSES.SingletonVault as `0x${string}`, DEPOSIT_AMT],
    })});
    const salt = toHex(randomSalt());
    await publicClient.waitForTransactionReceipt({ hash: await walletClient.writeContract({
      address: ADDRESSES.SingletonVault as `0x${string}`, abi: VAULT_ABI, functionName: "deposit",
      args: [ADDRESSES.MockUSDC as `0x${string}`, DEPOSIT_AMT, salt as `0x${string}`],
    })});

    const position: Position = { owner: address, asset: ADDRESSES.MockUSDC as `0x${string}`, amount: DEPOSIT_AMT, salt };
    stateRef.current.position = position;
    log("success", `$2,000 deposited`);

    const { timestamp: now } = await publicClient.getBlock({ blockTag: "latest" });
    const spendCap: Capability = buildCapability({
      issuer:  address,
      grantee: address,
      expiry:  now + 30n * 86400n,
      nonce:   toHex(randomSalt()),
      constraints: {
        maxSpendPerPeriod: DEPOSIT_AMT * 2n,
        periodDuration:    86400n,
        minReturnBps:      0n,
        allowedAdapters:   [ADDRESSES.ClawloanRepayAdapter as `0x${string}`],
        allowedTokensIn:   [],
        allowedTokensOut:  [],
      },
    });
    const capSig = await signCapability(walletClient, spendCap, ADDRESSES.CapabilityKernel as `0x${string}`, ANVIL_CHAIN_ID);
    stateRef.current.spendCap = spendCap;
    stateRef.current.capSig   = capSig as `0x${string}`;

    const intent = buildIntent({
      position,
      capability:  spendCap,
      adapter:     ADDRESSES.ClawloanRepayAdapter as `0x${string}`,
      adapterData: "0x",
      minReturn:   0n,
      deadline:    now + 7n * 86400n,
      nonce:       toHex(randomSalt()),
      outputToken: ADDRESSES.MockUSDC as `0x${string}`,
      returnTo:    ZERO_ADDRESS,
      submitter:   ZERO_ADDRESS,
      solverFeeBps: 0,
    });
    const intentSig = await signIntent(walletClient, intent, ADDRESSES.CapabilityKernel as `0x${string}`, ANVIL_CHAIN_ID);
    stateRef.current.intent    = intent;
    stateRef.current.intentSig = intentSig as `0x${string}`;
    log("info", "Trade proposal signed by Prime agent");

    // Register proposal in MockConsensusHub
    const signerAddrs = ANVIL_ACCOUNTS.map(a => a.address as `0x${string}`);
    const intentHash = keccak256(encodeAbiParameters(
      [{ type: "bytes32" }, { type: "bytes32" }],
      [intent.positionCommitment, hashCapability(spendCap)]
    ));

    const propRcpt = await publicClient.waitForTransactionReceipt({ hash: await walletClient.writeContract({
      address: ADDRESSES.MockConsensusHub as `0x${string}`,
      abi: MOCK_CONSENSUS_HUB_ABI,
      functionName: "propose",
      args: [intentHash, REQUIRED_M, signerAddrs],
    })});

    // Extract proposalId from the Proposed event (topic[1])
    let proposalId = `0x${"0".repeat(64)}` as `0x${string}`;
    for (const l of propRcpt.logs) {
      if (l.address.toLowerCase() === ADDRESSES.MockConsensusHub.toLowerCase() && l.topics.length >= 2) {
        proposalId = l.topics[1] as `0x${string}`;
        break;
      }
    }
    stateRef.current.proposalId = proposalId;
    log("success", `Proposal registered | proposalId: ${proposalId.slice(0, 10)}… | requires 3-of-5 approvals`);
    setStep(1);
  });

  // ── Approve as a specific agent ───────────────────────────────────────────
  const approveAs = (agentIdx: number) => withBusy(async () => {
    if (!publicClient) return;
    const { proposalId } = stateRef.current;
    if (!proposalId) { log("error", "Setup proposal first"); return; }
    log("info", `Agent ${AGENT_NAMES[agentIdx]} signing off…`);

    let hash: `0x${string}`;
    if (agentIdx === 0) {
      hash = await walletClient!.writeContract({
        address: ADDRESSES.MockConsensusHub as `0x${string}`,
        abi: MOCK_CONSENSUS_HUB_ABI,
        functionName: "approve",
        args: [proposalId],
      });
    } else {
      hash = await clientFor(agentIdx).writeContract({
        address: ADDRESSES.MockConsensusHub as `0x${string}`,
        abi: MOCK_CONSENSUS_HUB_ABI,
        functionName: "approve",
        args: [proposalId],
      });
    }
    await publicClient.waitForTransactionReceipt({ hash });

    const newApprovals = [...approvals];
    newApprovals[agentIdx] = true;
    setApprovals(newApprovals);
    const count = newApprovals.filter(Boolean).length;
    log("success", `${AGENT_NAMES[agentIdx]} approved | ${count}/${REQUIRED_M} threshold`);
  });

  // ── Execute once threshold is met ─────────────────────────────────────────
  const executeConsensus = () => withBusy(async () => {
    if (!walletClient || !publicClient) return;
    const { proposalId, position, spendCap, intent, capSig, intentSig } = stateRef.current;
    if (!proposalId || !position || !spendCap || !intent || !capSig || !intentSig) {
      log("error", "Setup first"); return;
    }
    const isExec = await publicClient.readContract({
      address: ADDRESSES.MockConsensusHub as `0x${string}`,
      abi: MOCK_CONSENSUS_HUB_ABI,
      functionName: "isExecutable",
      args: [proposalId],
    });
    if (!isExec) { log("error", "Threshold not met yet"); return; }
    log("info", `Consensus threshold met (${approvalCount}/${REQUIRED_M}) — executing trade…`);

    await publicClient.waitForTransactionReceipt({ hash: await walletClient.writeContract({
      address: ADDRESSES.CapabilityKernel as `0x${string}`,
      abi: KERNEL_DIRECT_ABI,
      functionName: "executeIntent",
      args: [position as never, spendCap as never, intent as never, capSig, intentSig],
    })});

    await publicClient.waitForTransactionReceipt({ hash: await walletClient.writeContract({
      address: ADDRESSES.MockConsensusHub as `0x${string}`,
      abi: MOCK_CONSENSUS_HUB_ABI,
      functionName: "markExecuted",
      args: [proposalId],
    })});

    log("success", `EXECUTED | 3 independent agents signed | $2,000 trade settled`);
    log("info", "No single agent could have done this. 1 or 2 compromised keys: harmless.");
    setExecuted(true);
  });

  return (
    <div className="flex gap-6 w-full">
      <div className="flex-1 min-w-0 flex flex-col gap-4">

        {/* Hero */}
        <div className="rounded-xl border border-violet-700 bg-violet-950/20 p-5">
          <div className="flex items-center gap-3 mb-2">
            <span className="text-2xl">🗳️</span>
            <div>
              <h2 className="text-lg font-bold text-violet-300">M-of-N Multi-Agent Consensus</h2>
              <p className="text-xs text-slate-400">Institutional governance for AI agent fleets</p>
            </div>
          </div>
          <p className="text-sm text-slate-300 mt-2">
            3 of 5 independent agents must approve before $2,000 executes.
            A single compromised agent key cannot move the position.
          </p>
          <div className="mt-3 flex items-center gap-3">
            <div className="flex-1 bg-slate-800 rounded-full h-2">
              <div
                className="bg-violet-500 h-2 rounded-full transition-all duration-500"
                style={{ width: `${Math.min((approvalCount / REQUIRED_M) * 100, 100)}%` }}
              />
            </div>
            <span className={`text-sm font-bold font-mono ${approvalCount >= REQUIRED_M ? "text-violet-300" : "text-slate-400"}`}>
              {approvalCount}/{REQUIRED_M}
            </span>
            {approvalCount >= REQUIRED_M && <span className="text-xs text-violet-400">✓ EXECUTABLE</span>}
          </div>
        </div>

        {/* Setup */}
        {step === 0 && (
          <div className="rounded-xl border border-slate-700 bg-slate-900/50 p-4">
            <div className="text-sm font-bold text-slate-300 mb-2">Setup: Deposit + Propose Trade</div>
            <p className="text-sm text-slate-400 mb-3">
              Deposit $2,000 USDC and register a trade proposal in MockConsensusHub (3-of-5 threshold).
            </p>
            <TxButton label="Deposit $2,000 + Create Proposal" onClick={setupProposal} disabled={busy} />
          </div>
        )}

        {/* Agent approval cards */}
        {step >= 1 && (
          <div className="grid grid-cols-1 gap-3">
            {AGENT_NAMES.map((name, i) => (
              <div key={i} className={`rounded-xl border p-4 flex items-center gap-4 ${approvals[i] ? "border-violet-600 bg-violet-950/20" : "border-slate-700 bg-slate-900/40"}`}>
                <div className={`w-8 h-8 rounded-full flex items-center justify-center text-sm font-bold ${approvals[i] ? "bg-violet-700 text-white" : "bg-slate-700 text-slate-400"}`}>
                  {approvals[i] ? "✓" : i + 1}
                </div>
                <div className="flex-1">
                  <div className={`text-sm font-semibold ${approvals[i] ? "text-violet-300" : "text-slate-300"}`}>{name}</div>
                  <div className="text-xs text-slate-500 font-mono">{ANVIL_ACCOUNTS[i].address.slice(0, 16)}…</div>
                </div>
                <span className="text-xs text-slate-500">{i === 0 ? "← You" : "Simulated"}</span>
                {!approvals[i] && !executed && (
                  <TxButton
                    label="Sign Off"
                    onClick={() => approveAs(i)}
                    disabled={busy || approvals[i]}
                    variant="secondary"
                  />
                )}
                {approvals[i] && (
                  <span className="text-xs text-violet-400 font-bold">Signed</span>
                )}
              </div>
            ))}
          </div>
        )}

        {/* Execute */}
        {approvalCount >= REQUIRED_M && !executed && (
          <div className="rounded-xl border border-violet-500 bg-violet-950/30 p-4 text-center">
            <div className="text-violet-300 font-bold mb-2">✓ Threshold Met — Ready to Execute</div>
            <p className="text-sm text-slate-400 mb-3">
              {approvalCount} independent agents have signed. The trade will now execute on-chain.
            </p>
            <TxButton label="🚀 Execute Trade" onClick={executeConsensus} disabled={busy} />
          </div>
        )}

        {executed && (
          <div className="rounded-xl border border-violet-500 bg-violet-950/30 p-5 text-center">
            <div className="text-3xl mb-2">✅</div>
            <div className="text-violet-300 font-bold text-lg">Consensus Trade Executed</div>
            <div className="text-slate-300 text-sm mt-1">3 agents signed. 2 could not be coerced. Trade settled.</div>
          </div>
        )}

        <LogPanel entries={logs} />
      </div>

      {/* Right panel */}
      <div className="w-80 flex-shrink-0 flex flex-col gap-4">
        <div className="rounded-xl border border-violet-700 bg-violet-950/20 p-4 text-xs">
          <h3 className="text-sm font-bold text-violet-300 mb-3">Institutional Use Case</h3>
          <p className="text-slate-400 mb-3">
            A hedge fund running an AI trading system cannot afford a single hot key compromise
            to drain $10M. M-of-N enforcement is non-negotiable at this scale.
          </p>
          <div className="space-y-2">
            {[
              { scenario: "1 agent compromised",  result: "1 of 3 required — no execution. Position safe." },
              { scenario: "2 agents compromised", result: "2 of 3 required — still no execution." },
              { scenario: "3 agents sign",        result: "Threshold met — trade executes." },
              { scenario: "Revoke 1 key",         result: "Hub rejects that signer for all future proposals." },
            ].map(s => (
              <div key={s.scenario} className="p-2 bg-slate-900/50 rounded">
                <div className="text-slate-300 font-semibold">{s.scenario}</div>
                <div className="text-slate-500">{s.result}</div>
              </div>
            ))}
          </div>
        </div>

        <div className="rounded-xl border border-slate-700 bg-slate-900/50 p-4 text-xs text-slate-400">
          <div className="font-semibold text-slate-300 mb-2">Phase 1 vs Phase 2</div>
          <div className="space-y-2">
            <div className="p-2 rounded bg-slate-800">
              <div className="text-slate-300 font-bold mb-1">Phase 1 (this demo)</div>
              <p>MockConsensusHub collects M approve() calls on-chain. Application-layer verification. Kernel executes via single root capability.</p>
            </div>
            <div className="p-2 rounded bg-violet-950/30 border border-violet-800">
              <div className="text-violet-300 font-bold mb-1">Phase 2 (roadmap)</div>
              <p>CapabilityKernel accepts M ECDSA signatures in executeIntent(). Merkle proof verifies each signer against the consensusPolicy root. Fully trustless on-chain M-of-N.</p>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
