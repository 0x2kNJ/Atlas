import React, { useState, useCallback, useEffect, useRef } from "react";
import { useAccount, useWalletClient, usePublicClient, useBalance } from "wagmi";
import { toHex, parseUnits } from "viem";

import { ADDRESSES, ANVIL_CHAIN_ID } from "./contracts/addresses";
import {
  ERC20_ABI,
  CLAWLOAN_POOL_ABI,
  VAULT_ABI,
  REGISTRY_ABI,
} from "./contracts/abis";
import { triggerEnvelope }   from "./lib/triggerEnvelope";
import { submitCreditProof as runCreditProof } from "./lib/creditProof";
import { useChainState } from "./hooks/useChainState";
import { StatusBar }          from "./components/StatusBar";
import { StepCard }           from "./components/StepCard";
import { TxButton }           from "./components/TxButton";
import { LogPanel }           from "./components/LogPanel";
import { HeroSection }        from "./components/HeroSection";
import { TierUpgradeOverlay } from "./components/TierUpgradeOverlay";
import { KeeperNetworkPanel } from "./components/KeeperNetworkPanel";
import { WithoutAtlasCard }   from "./components/WithoutAtlasCard";
import { InvestorBriefModal } from "./components/InvestorBriefModal";
import { KeeperModeView }     from "./components/KeeperModeView";
import { LenderPanel }        from "./components/LenderPanel";
import { ScenarioNav }        from "./components/ScenarioNav";
import type { ScenarioId }    from "./components/ScenarioNav";
import { isStrategyGraph }    from "./components/ScenarioNav";
import { CapitalProviderScenario }  from "./scenarios/CapitalProviderScenario";
import { DeadMansSwitchScenario }  from "./scenarios/DeadMansSwitchScenario";
import { SubAgentScenario }        from "./scenarios/SubAgentScenario";
import { StopLossScenario }        from "./scenarios/StopLossScenario";
import { PublishKeyScenario }      from "./scenarios/PublishKeyScenario";
import { LiquidationScenario }     from "./scenarios/LiquidationScenario";
import { ZKPassportScenario }      from "./scenarios/ZKPassportScenario";
import { MofNScenario }            from "./scenarios/MofNScenario";
import { ChainedStrategyScenario }    from "./scenarios/ChainedStrategyScenario";
import { LeveragedLongScenario }      from "./scenarios/sg/LeveragedLongScenario";
import { DegradeLadderScenario }      from "./scenarios/sg/DegradeLadderScenario";
import { SelfRepayingLoanScenario }   from "./scenarios/sg/SelfRepayingLoanScenario";
import { CollateralRotationScenario } from "./scenarios/sg/CollateralRotationScenario";
import { RefinancePipelineScenario }  from "./scenarios/sg/RefinancePipelineScenario";
import { LeveragedDCAScenario }       from "./scenarios/sg/LeveragedDCAScenario";
import type { LogEntry }      from "./components/LogPanel";

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

// ─── Demo constants ───────────────────────────────────────────────────────────
const BOT_ID       = 1n;
const BORROW_AMT   = parseUnits("500", 6);   // 500 USDC
const EARNINGS_AMT = parseUnits("1000", 6);  // 1,000 USDC (agent task earnings)
const LOAN_WINDOW  = 7 * 24 * 60 * 60;      // 7 days in seconds

// ─── BigInt-safe localStorage serialization ──────────────────────────────────
function bigintReplacer(_: string, v: unknown) {
  return typeof v === "bigint" ? { __bigint: v.toString() } : v;
}
const ENVELOPE_KEY = "atlas_pending_envelopes";

// ─── State held between steps ────────────────────────────────────────────────
interface DemoState {
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
  posSalt?:        `0x${string}`;
}

export default function App() {
  // ── Keeper-mode routing via URL param ────────────────────────────────────────
  const params   = new URLSearchParams(window.location.search);
  const role     = params.get("role");
  if (role === "keeper") return <KeeperModeView />;

  return <ScenarioRouter />;
}

const ALL_SCENARIO_IDS: ScenarioId[] = [
  "clawloan", "capital-provider",
  "dms", "orchestration", "stoploss",
  "publishkey", "liquidation", "zkpassport", "mofn",
  "sg-chained", "sg-leveraged-long", "sg-deleverage",
  "sg-self-repaying", "sg-collateral-rotation", "sg-refi", "sg-dca",
];

function ScenarioRouter() {
  const [scenario, setScenario] = useState<ScenarioId>(() => {
    const params = new URLSearchParams(window.location.search);
    const s = params.get("scenario") as ScenarioId | null;
    if (s && ALL_SCENARIO_IDS.includes(s)) return s;
    return "clawloan";
  });

  const handleScenarioChange = (id: ScenarioId) => {
    setScenario(id);
    const url = new URL(window.location.href);
    url.searchParams.set("scenario", id);
    window.history.pushState({}, "", url.toString());
  };

  const SG = ({ children }: { children: React.ReactNode }) => (
    <div className="max-w-7xl mx-auto w-full px-6 py-6">{children}</div>
  );

  const ScenarioContent = () => {
    switch (scenario) {
      case "clawloan":           return <AgentModeApp />;
      case "capital-provider":   return <CapitalProviderScenario />;
      case "dms":           return <DeadMansSwitchScenario />;
      case "orchestration": return <SubAgentScenario />;
      case "stoploss":      return <div className="max-w-7xl mx-auto w-full px-6 py-6"><StopLossScenario /></div>;
      case "publishkey":    return <div className="max-w-7xl mx-auto w-full px-6 py-6"><PublishKeyScenario /></div>;
      case "liquidation":   return <div className="max-w-7xl mx-auto w-full px-6 py-6"><LiquidationScenario /></div>;
      case "zkpassport":    return <div className="max-w-7xl mx-auto w-full px-6 py-6"><ZKPassportScenario /></div>;
      case "mofn":                    return <SG><MofNScenario /></SG>;
      // Strategy Graph sub-scenarios
      case "sg-chained":             return <SG><ChainedStrategyScenario /></SG>;
      case "sg-leveraged-long":      return <SG><LeveragedLongScenario /></SG>;
      case "sg-deleverage":          return <SG><DegradeLadderScenario /></SG>;
      case "sg-self-repaying":       return <SG><SelfRepayingLoanScenario /></SG>;
      case "sg-collateral-rotation": return <SG><CollateralRotationScenario /></SG>;
      case "sg-refi":                return <SG><RefinancePipelineScenario /></SG>;
      case "sg-dca":                 return <SG><LeveragedDCAScenario /></SG>;
      default:                       return <AgentModeApp />;
    }
  };

  return (
    <div className="min-h-screen bg-zinc-950 text-zinc-100 flex flex-col">
      <SharedHeader />
      <ScenarioNav active={scenario} onChange={handleScenarioChange} />
      <ScenarioContent />
    </div>
  );
}

function SharedHeader() {
  return (
    <header className="border-b border-zinc-800 px-6 py-4 flex items-center justify-between">
      <div className="flex items-center gap-3">
        <span className="text-2xl">🦞</span>
        <div>
          <h1 className="text-lg font-bold tracking-tight">
            Atlas Protocol <span className="text-zinc-500 font-normal">×</span> ClawLoan
          </h1>
          <p className="text-xs text-zinc-500 mt-0.5">
            Liveness-independent execution for AI agents
          </p>
        </div>
      </div>
      <div className="flex items-center gap-2 text-xs">
        <a
          href="?role=keeper"
          target="_blank"
          rel="noopener noreferrer"
          className="px-3 py-1.5 rounded-lg bg-emerald-900/40 hover:bg-emerald-800/50 text-emerald-400 transition-colors border border-emerald-800/50"
        >
          Keeper Mode →
        </a>
        <span className="flex items-center gap-1.5 text-zinc-500 border-l border-zinc-800 pl-2">
          <span className="w-1.5 h-1.5 rounded-full bg-emerald-500 inline-block animate-pulse" />
          Anvil :8545
        </span>
      </div>
    </header>
  );
}

function AgentModeApp() {
  const { address, isConnected } = useAccount();
  const { data: walletClient }   = useWalletClient();
  const publicClient             = usePublicClient();
  const [showInvestorBrief, setShowInvestorBrief] = useState(false);

  const [demo,   setDemo]   = useState<DemoState>({});
  const [logs,   setLogs]   = useState<LogEntry[]>([]);
  const [busy,   setBusy]   = useState<Record<string, boolean>>({});
  const logId = useRef(0);

  // ── UI states ─────────────────────────────────────────────────────────────────
  const [showHero,          setShowHero]          = useState(true);
  const [agentOffline,      setAgentOffline]      = useState(false);
  const [keeperFeeEarned,   setKeeperFeeEarned]   = useState<bigint>(0n);
  const [triggerTx,         setTriggerTx]         = useState<string | undefined>();
  const [tierUpgrade,       setTierUpgrade]       = useState<{ from: number; to: number } | null>(null);
  const prevTierRef = useRef<number>(0);

  const chain = useChainState(demo.positionHash, demo.envelopeHash, demo.capabilityHash);

  // ── Detect credit tier upgrade ────────────────────────────────────────────────
  useEffect(() => {
    if (chain.creditTier > prevTierRef.current) {
      setTierUpgrade({ from: prevTierRef.current, to: chain.creditTier });
    }
    prevTierRef.current = chain.creditTier;
  }, [chain.creditTier]);

  // ── Auto-airdrop on wallet connect ───────────────────────────────────────────
  const { data: ethBalance } = useBalance({ address });
  const airdropped = useRef<string | null>(null);

  useEffect(() => {
    if (!address || !isConnected) return;
    if (airdropped.current === address) return;
    if (ethBalance && ethBalance.value >= parseUnits("1", 18)) return; // already has gas

    airdropped.current = address;
    fetch("http://127.0.0.1:8545", {
      method:  "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        jsonrpc: "2.0", id: 1,
        method:  "anvil_setBalance",
        params:  [address, toHex(parseUnits("10", 18))],
      }),
    })
      .then(r => r.json())
      .then((j: { error?: { message: string } }) => {
        if (j.error) throw new Error(j.error.message);
        setLogs(prev => [...prev, { id: ++logId.current, ts: Date.now(), level: "success", message: `Auto-airdropped 10 ETH to ${address.slice(0, 8)}… — refresh MetaMask balance` }]);
      })
      .catch(() => {
        // fetch blocked — ETH was already sent manually or will be sent via cast
        setLogs(prev => [...prev, { id: ++logId.current, ts: Date.now(), level: "warn", message: `Could not auto-airdrop — run: cast send ${address} --value 10ether --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 --rpc-url http://127.0.0.1:8545` }]);
      });
  }, [address, isConnected, ethBalance]);

  // ── Logging ─────────────────────────────────────────────────────────────────
  const log = useCallback((level: LogEntry["level"], message: string) => {
    setLogs(prev => [...prev, { id: ++logId.current, ts: Date.now(), level, message }]);
  }, []);

  const withBusy = useCallback(async (key: string, fn: () => Promise<void>) => {
    setBusy(b => ({ ...b, [key]: true }));
    try { await fn(); }
    catch (e: unknown) {
      const msg = e instanceof Error ? e.message : String(e);
      console.error("[Atlas demo]", e);
      log("error", msg.slice(0, 300));
    }
    finally { setBusy(b => ({ ...b, [key]: false })); }
  }, [log]);


  // ── Step 0: mint test USDC ───────────────────────────────────────────────────
  async function mintUsdc() {
    await withBusy("mint", async () => {
      if (!walletClient || !address) throw new Error("wallet not connected");
      const amt = Number(EARNINGS_AMT) / 1e6;
      log("info", `Minting ${amt} USDC to ${address.slice(0, 8)}…`);
      const hash = await walletClient.writeContract({
        address: ADDRESSES.MockUSDC as `0x${string}`,
        abi: ERC20_ABI,
        functionName: "mint",
        args: [address, EARNINGS_AMT],
      });
      await publicClient!.waitForTransactionReceipt({ hash });
      log("success", `Minted ${amt} USDC — tx ${hash.slice(0, 10)}…`);
    });
  }

  // ── Step 1: borrow from Clawloan pool ───────────────────────────────────────
  async function borrow() {
    await withBusy("borrow", async () => {
      if (!walletClient || !address) throw new Error("wallet not connected");

      // Live check — polled chain.debt can lag up to 2 s, so read on-chain directly.
      const liveDebt = await publicClient!.readContract({
        address: ADDRESSES.MockClawloanPool as `0x${string}`,
        abi: CLAWLOAN_POOL_ABI,
        functionName: "getDebt",
        args: [BOT_ID],
      }) as bigint;
      if (liveDebt > 0n) {
        throw new Error(
          `Outstanding debt: ${(Number(liveDebt) / 1e6).toFixed(2)} USDC. ` +
          `Trigger the envelope to repay it first, then click "New cycle →" before borrowing again.`
        );
      }

      const borrowAmt = Number(BORROW_AMT) / 1e6;
      log("info", `Borrowing ${borrowAmt} USDC from Clawloan pool (credit-based, no collateral)…`);
      const hash = await walletClient.writeContract({
        address: ADDRESSES.MockClawloanPool as `0x${string}`,
        abi: CLAWLOAN_POOL_ABI,
        functionName: "borrow",
        args: [BOT_ID, BORROW_AMT],
      });
      await publicClient!.waitForTransactionReceipt({ hash });
      log("success", `Borrowed ${borrowAmt} USDC (bot #${BOT_ID}) — tx ${hash.slice(0, 10)}…`);
    });
  }

  // ── Step 2: approve + deposit earnings ──────────────────────────────────────
  async function deposit() {
    await withBusy("deposit", async () => {
      if (!walletClient || !address) throw new Error("wallet not connected");

      // Always use live reads — polled chain state can lag by up to 2 s and cause false approvals.
      const [liveBalance, liveAllowance] = await Promise.all([
        publicClient!.readContract({
          address: ADDRESSES.MockUSDC as `0x${string}`,
          abi: ERC20_ABI,
          functionName: "balanceOf",
          args: [address],
        }) as Promise<bigint>,
        publicClient!.readContract({
          address: ADDRESSES.MockUSDC as `0x${string}`,
          abi: ERC20_ABI,
          functionName: "allowance",
          args: [address, ADDRESSES.SingletonVault as `0x${string}`],
        }) as Promise<bigint>,
      ]);

      if (liveBalance < EARNINGS_AMT) {
        throw new Error(
          `Insufficient USDC: wallet has ${(Number(liveBalance) / 1e6).toFixed(2)} USDC but deposit needs ${Number(EARNINGS_AMT) / 1e6}. ` +
          `Click "Mint 15 USDC" first.`
        );
      }

      if (liveAllowance < EARNINGS_AMT) {
        log("info", "Approving vault for USDC…");
        const approveTx = await walletClient.writeContract({
          address: ADDRESSES.MockUSDC as `0x${string}`,
          abi: ERC20_ABI,
          functionName: "approve",
          args: [ADDRESSES.SingletonVault as `0x${string}`, BigInt("0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff")],
        });
        await publicClient!.waitForTransactionReceipt({ hash: approveTx });
        log("success", "Vault approved");
      }

      const salt = randomSalt();
      const earnAmt = Number(EARNINGS_AMT) / 1e6;
      log("info", `Depositing ${earnAmt} USDC task earnings into Atlas vault (salt: ${salt.slice(0, 10)}…)`);

      // Simulate before sending — surfaces the real revert reason (e.g. PositionAlreadyExists,
      // TokenNotAllowlisted, ZeroAmount) rather than a raw TX hash.
      try {
        await publicClient!.simulateContract({
          address: ADDRESSES.SingletonVault as `0x${string}`,
          abi: VAULT_ABI,
          functionName: "deposit",
          args: [ADDRESSES.MockUSDC as `0x${string}`, EARNINGS_AMT, salt],
          account: address,
        });
      } catch (simErr: unknown) {
        const msg = simErr instanceof Error ? simErr.message : String(simErr);
        throw new Error(`Vault deposit simulation failed — check contracts are deployed: ${msg.slice(0, 300)}`);
      }

      const hash = await walletClient.writeContract({
        address: ADDRESSES.SingletonVault as `0x${string}`,
        abi: VAULT_ABI,
        functionName: "deposit",
        args: [ADDRESSES.MockUSDC as `0x${string}`, EARNINGS_AMT, salt],
      });
      const receipt = await publicClient!.waitForTransactionReceipt({ hash });
      if (receipt.status === "reverted") throw new Error(`Deposit TX reverted: ${hash}`);

      // Compute positionHash client-side
      const pos: Position = {
        owner:  address,
        asset:  ADDRESSES.MockUSDC as `0x${string}`,
        amount: EARNINGS_AMT,
        salt,
      };
      const posHash = hashPosition(pos);

      log("success", `Deposited ${Number(EARNINGS_AMT) / 1e6} USDC — position ${posHash.slice(0, 10)}… tx ${hash.slice(0, 10)}…`);
      setDemo(d => ({ ...d, positionHash: posHash, position: pos, posSalt: salt }));

      void receipt;
    });
  }

  // ── Step 3: sign + register envelope ────────────────────────────────────────
  async function registerEnvelope() {
    await withBusy("register", async () => {
      if (!walletClient || !address || !demo.position || !demo.positionHash) {
        throw new Error("complete step 2 first");
      }

      // Use on-chain block.timestamp as base — Anvil may be time-warped from a prior run.
      // Using Date.now() would produce deadlines already in the past from the chain's perspective,
      // causing EnvelopeRegistry.register() to revert with EnvelopeNotActive().
      const latestBlock = await publicClient!.getBlock({ blockTag: "latest" });
      const now      = latestBlock.timestamp;
      const deadline = now + BigInt(LOAN_WINDOW);
      const capExpiry = now + BigInt(30 * 24 * 60 * 60); // 30 days

      // Build vault.spend capability
      const capNonce    = randomSalt();
      const intentNonce = randomSalt();
      const manageNonce = randomSalt();

      // Read live debt at registration time — use it as the debtCap so the adapter
      // always has the exact cap it needs regardless of how much was borrowed.
      const liveDebtNow = await publicClient!.readContract({
        address: ADDRESSES.MockClawloanPool as `0x${string}`,
        abi: CLAWLOAN_POOL_ABI,
        functionName: "getDebt",
        args: [BOT_ID],
      }) as bigint;

      if (liveDebtNow === 0n) {
        throw new Error("No outstanding debt — borrow from Clawloan first (Step 1).");
      }
      const minReturn = parseUnits("10", 6); // 10 USDC min profit floor on $1000 deposit
      if (liveDebtNow + minReturn > EARNINGS_AMT) {
        throw new Error(
          `Live debt (${(Number(liveDebtNow) / 1e6).toFixed(2)} USDC) + minReturn (2 USDC) ` +
          `exceeds vault deposit (${(Number(EARNINGS_AMT) / 1e6).toFixed(2)} USDC). ` +
          `Click "New cycle →", re-trigger the pending loan, then borrow once before depositing.`
        );
      }
      log("info", `Live debt: ${(Number(liveDebtNow) / 1e6).toFixed(2)} USDC — using as debtCap`);

      const adapterData = clawloanRepayLive(
        ADDRESSES.MockClawloanPool as `0x${string}`,
        BOT_ID,
        liveDebtNow   // always matches the actual debt — no hardcoded cap mismatch
      );

      const spendCap = buildCapability({
        issuer:  address,
        grantee: address, // in this demo the operator acts as both operator + agent
        expiry:  capExpiry,
        nonce:   capNonce,
        constraints: {
          maxSpendPerPeriod: 0n,
          periodDuration:    0n,
          minReturnBps:      0n,
          allowedAdapters:   [ADDRESSES.ClawloanRepayAdapter as `0x${string}`],
          allowedTokensIn:   [ADDRESSES.MockUSDC as `0x${string}`],
          allowedTokensOut:  [ADDRESSES.MockUSDC as `0x${string}`],
        },
      });

      const intent = buildIntent({
        position:     demo.position,
        capability:   spendCap,
        adapter:      ADDRESSES.ClawloanRepayAdapter as `0x${string}`,
        adapterData,
        minReturn:    parseUnits("10", 6), // at least 10 USDC profit floor
        deadline:     capExpiry,
        nonce:        intentNonce,
        outputToken:  ADDRESSES.MockUSDC as `0x${string}`,
        returnTo:     ZERO_ADDRESS,  // address(0) = route output to position.owner (default)
        submitter:    ADDRESSES.EnvelopeRegistry as `0x${string}`,
        solverFeeBps: 10,
      });

      const manageCap = buildManageCapability({
        issuer:  address,
        grantee: address,
        expiry:  capExpiry,
        nonce:   manageNonce,
      });

      const conditions: Conditions = {
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
        position:           demo.position,
        conditions,
        intent,
        manageCapability:   manageCap,
        expiry:             deadline + BigInt(24 * 60 * 60),
        keeperRewardBps:    10,
        minKeeperRewardWei: 0n,
      });

      // Sign both capabilities and the intent
      log("info", "Sign vault.spend capability (1/3)…");
      const capSig = await signCapability(
        walletClient,
        spendCap,
        ADDRESSES.CapabilityKernel as `0x${string}`,
        ANVIL_CHAIN_ID
      );

      log("info", "Sign intent (2/3)…");
      const intentSig = await signIntent(
        walletClient,
        intent,
        ADDRESSES.CapabilityKernel as `0x${string}`,
        ANVIL_CHAIN_ID
      );

      log("info", "Sign envelope.manage capability (3/3)…");
      const manageCapSig = await signManageCapability(
        walletClient,
        manageCap,
        ADDRESSES.EnvelopeRegistry as `0x${string}`,
        ANVIL_CHAIN_ID
      );

      log("info", "Registering envelope on-chain…");

      // Simulate to catch EnvelopeRegistry-level reverts (ConditionsMismatch, wrong sig, etc.)
      try {
        await publicClient!.simulateContract({
          address: ADDRESSES.EnvelopeRegistry as `0x${string}`,
          abi: REGISTRY_ABI,
          functionName: "register",
          args: [envelope as never, manageCap as never, manageCapSig, demo.position as never],
          account: address,
        });
      } catch (simErr: unknown) {
        const msg = simErr instanceof Error ? simErr.message : String(simErr);
        throw new Error(`Register simulation failed — contracts may need redeployment: ${msg.slice(0, 300)}`);
      }

      const hash = await walletClient.writeContract({
        address: ADDRESSES.EnvelopeRegistry as `0x${string}`,
        abi: REGISTRY_ABI,
        functionName: "register",
        args: [
          envelope     as never,
          manageCap    as never,
          manageCapSig,
          demo.position as never,
        ],
      });
      const regReceipt = await publicClient!.waitForTransactionReceipt({ hash });
      if (regReceipt.status === "reverted") {
        throw new Error(`Register TX reverted: ${hash}`);
      }

      // Compute envelope hash — must match HashLib.hashEnvelope() (includes ENVELOPE_TYPEHASH).
      const envelopeHash = hashEnvelope(envelope);

      log("success", `Envelope registered — ${envelopeHash.slice(0, 10)}… tx ${hash.slice(0, 10)}…`);
      log("info", `Loan deadline: ${new Date(Number(deadline) * 1000).toLocaleString()}`);
      log("warn", "Agent can now go offline — keeper will trigger at deadline autonomously");
      log("info", "Envelope saved to localStorage — open ?role=keeper in another tab to simulate a keeper");

      const capHash = hashCapability(spendCap);

      // Persist envelope data to localStorage so the Keeper Mode tab can read it.
      const stored = JSON.parse(localStorage.getItem(ENVELOPE_KEY) || "[]");
      stored.push(JSON.parse(
        JSON.stringify({
          envelopeHash,
          capabilityHash: capHash,
          positionHash: demo.positionHash,
          conditions,
          position: demo.position,
          intent,
          spendCap,
          capSig,
          intentSig,
          loanDeadline: deadline,
          agentAddress: address,
          registeredAt: Date.now(),
          triggered: false,
        }, bigintReplacer)
      ));
      localStorage.setItem(ENVELOPE_KEY, JSON.stringify(stored));

      setAgentOffline(true);
      setDemo(d => ({
        ...d,
        envelopeHash,
        capabilityHash: capHash,
        spendCap,
        intent,
        capSig,
        intentSig,
        conditions,
        loanDeadline: deadline,
      }));
    });
  }

  // ── Step 4: keeper trigger ───────────────────────────────────────────────────
  async function keeperTrigger() {
    await withBusy("trigger", async () => {
      if (!walletClient || !address || !demo.envelopeHash || !demo.conditions || !demo.position || !demo.intent || !demo.spendCap || !demo.capSig || !demo.intentSig) {
        throw new Error("complete step 3 first");
      }
      const { triggerTx: tx, feeEarned } = await triggerEnvelope({
        publicClient: publicClient!,
        walletClient,
        address,
        envelopeHash:  demo.envelopeHash,
        conditions:    demo.conditions,
        position:      demo.position,
        intent:        demo.intent,
        spendCap:      demo.spendCap,
        capSig:        demo.capSig,
        intentSig:     demo.intentSig,
        loanDeadline:  demo.loanDeadline ?? 0n,
        positionAmount: EARNINGS_AMT,
        keeperRewardBps: 10n,
        log,
      });
      setKeeperFeeEarned(feeEarned);
      setTriggerTx(tx);
    });
  }

  // ── Step 5: submit credit proof (real Binius64 proof) ───────────────────────
  async function submitCreditProof() {
    await withBusy("credit", async () => {
      if (!walletClient) throw new Error("wallet not connected");
      if (!demo.capabilityHash) throw new Error("No capabilityHash — complete step 3 first");
      await runCreditProof({
        publicClient:   publicClient!,
        walletClient,
        capabilityHash: demo.capabilityHash,
        adapterAddr:    ADDRESSES.ClawloanRepayAdapter as `0x${string}`,
        log,
      });
    });
  }

  // ── Reset demo state for a new cycle ────────────────────────────────────────
  // Preserves capabilityHash so the credit proof step stays functional even after
  // the user clicks "New cycle →" before submitting the proof.
  function resetCycle() {
    setDemo(d => ({ capabilityHash: d.capabilityHash }));
    setAgentOffline(false);
    setKeeperFeeEarned(0n);
    setTriggerTx(undefined);
    log("info", "Demo state cleared — ready for a new cycle");
  }

  // ── Auto-simulate: trigger + credit proof in one click ───────────────────────
  async function autoSimulate() {
    await withBusy("simulate", async () => {
      if (!walletClient || !address || !demo.envelopeHash || !demo.conditions || !demo.position || !demo.intent || !demo.spendCap || !demo.capSig || !demo.intentSig) {
        throw new Error("complete step 3 first");
      }

      // Skip the trigger if the position was already spent by a parallel click.
      const positionKey = (demo.positionHash ?? "0x" + "0".repeat(64)) as `0x${string}`;
      const posAlreadySpent = !(await publicClient!.readContract({
        address: ADDRESSES.SingletonVault as `0x${string}`,
        abi: VAULT_ABI,
        functionName: "positionExists",
        args: [positionKey],
      }) as boolean);

      if (posAlreadySpent) {
        log("info", "Position already spent (trigger ran in parallel) — skipping to credit proof…");
      } else {
        const { triggerTx: tx, feeEarned } = await triggerEnvelope({
          publicClient:    publicClient!,
          walletClient,
          address,
          envelopeHash:   demo.envelopeHash,
          conditions:     demo.conditions,
          position:       demo.position,
          intent:         demo.intent,
          spendCap:       demo.spendCap,
          capSig:         demo.capSig,
          intentSig:      demo.intentSig,
          loanDeadline:   demo.loanDeadline ?? 0n,
          positionAmount: EARNINGS_AMT,
          keeperRewardBps: 10n,
          log,
        });
        setKeeperFeeEarned(feeEarned);
        setTriggerTx(tx);
      }

      if (!demo.capabilityHash) { log("warn", "No capabilityHash — skipping credit proof"); return; }
      await runCreditProof({
        publicClient:   publicClient!,
        walletClient,
        capabilityHash: demo.capabilityHash,
        adapterAddr:    ADDRESSES.ClawloanRepayAdapter as `0x${string}`,
        log,
      });
    });
  }

  // ── Step status helpers ──────────────────────────────────────────────────────
  const hasBalance  = chain.walletUsdc >= EARNINGS_AMT;
  const hasBorrowed = chain.debt > 0n;
  const hasDeposit  = !!demo.positionHash;
  const hasEnvelope = !!demo.envelopeHash;
  const positionSpent = !!demo.positionHash && !chain.positionExists;
  const loanRepaid = hasEnvelope && positionSpent && !hasBorrowed;
  const canSubmitProof = chain.receiptCount > 0n && chain.creditTier === 0;
  const cycleComplete = loanRepaid && chain.creditTier > 0;

  // ── Credit tier helpers ───────────────────────────────────────────────────────
  const TIER_NAMES     = ["NEW", "BRONZE", "SILVER", "GOLD", "PLATINUM"] as const;
  const TIER_COLORS    = ["text-zinc-400", "text-amber-500", "text-slate-300", "text-yellow-400", "text-cyan-300"] as const;
  const TIER_BG        = ["bg-zinc-800", "bg-amber-900/40", "bg-slate-800/60", "bg-yellow-900/40", "bg-cyan-900/40"] as const;
  const TIER_BORDER    = ["border-zinc-700", "border-amber-700", "border-slate-500", "border-yellow-600", "border-cyan-600"] as const;
  const TIER_THRESHOLDS = [0, 1, 6, 21, 50] as const;
  const TIER_MAXBORROW  = [500, 2000, 10000, 50000, 100000] as const;

  const curTier   = chain.creditTier;
  const nextTier  = Math.min(curTier + 1, 4);
  const curCount  = Number(chain.receiptCount);
  const nextThreshold = TIER_THRESHOLDS[nextTier];
  const moreNeeded    = Math.max(0, nextThreshold - curCount);
  const progressPct   = nextTier <= 4
    ? Math.min(100, Math.round(
        ((curCount - TIER_THRESHOLDS[curTier]) /
         Math.max(1, nextThreshold - TIER_THRESHOLDS[curTier])) * 100
      ))
    : 100;

  const nextCycleLabel = curTier >= 4
    ? "Run another cycle →"
    : moreNeeded === 1
    ? `1 more cycle → ${TIER_NAMES[nextTier]} ($${TIER_MAXBORROW[nextTier]})`
    : `${moreNeeded} more cycles → ${TIER_NAMES[nextTier]} ($${TIER_MAXBORROW[nextTier]})`;

  return (
    <div className="flex flex-col">
      {/* Tier upgrade overlay */}
      {tierUpgrade && (
        <TierUpgradeOverlay
          tier={tierUpgrade.to}
          prevTier={tierUpgrade.from}
          onDismiss={() => setTierUpgrade(null)}
        />
      )}

      {/* Investor brief modal */}
      {showInvestorBrief && <InvestorBriefModal onClose={() => setShowInvestorBrief(false)} />}

      {/* Clawloan sub-header */}
      <div className="border-b border-zinc-800/50 bg-zinc-900/30 px-6 py-2 flex items-center gap-3 text-xs">
        <span className="text-zinc-500">Clawloan × Atlas —</span>
        <span className="text-zinc-400">Credit-based AI lending with liveness-independent repayment</span>
        <div className="ml-auto flex items-center gap-2">
          <button
            onClick={() => setShowInvestorBrief(true)}
            className="px-3 py-1.5 rounded-lg bg-zinc-800 hover:bg-zinc-700 text-zinc-400 hover:text-zinc-200 transition-colors border border-zinc-700"
          >
            Investor Brief
          </button>
        </div>
      </div>

      {/* Status bar */}
      <StatusBar
        walletUsdc={chain.walletUsdc}
        debt={chain.debt}
        vaultUsdc={chain.vaultUsdc}
        creditTier={chain.creditTier}
        maxBorrow={chain.maxBorrow}
        receiptCount={chain.receiptCount}
      />

      {/* Main layout */}
      <main className="flex-1 p-6 grid grid-cols-1 lg:grid-cols-3 gap-6 max-w-7xl mx-auto w-full">

        {/* Left: steps */}
        <div className="lg:col-span-2 flex flex-col gap-4">

          {/* Hero section — investor pitch, dismissible */}
          {showHero && <HeroSection onDismiss={() => setShowHero(false)} />}

          {/* Connect prompt */}
          {!isConnected && !showHero && (
            <div className="rounded-2xl border border-indigo-800 bg-indigo-950/30 p-6 text-center">
              <p className="text-zinc-300 mb-1 font-medium">Connect your wallet to begin</p>
              <p className="text-zinc-500 text-sm">Add Anvil (chainId 31337, RPC http://127.0.0.1:8545) to MetaMask, then connect above.</p>
            </div>
          )}

          {/* Without Atlas context — always visible after hero dismissed */}
          {!showHero && <WithoutAtlasCard />}

          {/* Step 0 — Mint test USDC */}
          <StepCard
            step={0}
            title="Simulate task completion — earn USDC"
            subtitle={`Agent completes an on-chain task. Simulate by minting ${Number(EARNINGS_AMT) / 1e6} USDC representing task revenue.`}
            status={!isConnected ? "pending" : hasBalance ? "done" : "ready"}
          >
            <div className="flex items-center gap-3 flex-wrap">
              <TxButton
                label={`Mint ${Number(EARNINGS_AMT) / 1e6} USDC`}
                onClick={mintUsdc}
                loading={busy["mint"]}
                disabled={!isConnected || hasBalance}
              />
              {hasBalance
                ? <span className="text-xs text-emerald-400">Wallet has {(Number(chain.walletUsdc) / 1e6).toFixed(2)} USDC — ready to borrow</span>
                : isConnected && <span className="text-xs text-zinc-500">Wallet: {(Number(chain.walletUsdc) / 1e6).toFixed(2)} USDC (need {(Number(EARNINGS_AMT) / 1e6).toFixed(0)})</span>
              }
            </div>
          </StepCard>

          {/* Step 1 — Borrow */}
          <StepCard
            step={1}
            title="Borrow from Clawloan — no collateral"
            subtitle={`Credit-based lending: ${Number(BORROW_AMT) / 1e6} USDC loan granted based on agent identity. No collateral. Defaults build credit history.`}
            status={!isConnected ? "pending" : loanRepaid ? "done" : hasBorrowed ? "done" : hasBalance ? "ready" : "pending"}
          >
            <div className="flex items-center gap-3 flex-wrap">
              <TxButton
                label={`Borrow ${Number(BORROW_AMT) / 1e6} USDC`}
                onClick={borrow}
                loading={busy["borrow"]}
                disabled={!isConnected || !hasBalance || hasBorrowed || hasEnvelope}
              />
              {hasBorrowed && !loanRepaid && <span className="text-xs text-red-400">⚠ Debt: {(Number(chain.debt) / 1e6).toFixed(2)} USDC outstanding — trigger envelope to repay before borrowing again</span>}
              {loanRepaid  && <span className="text-xs text-emerald-400">Loan repaid — receipt recorded on-chain</span>}
              {!hasBorrowed && hasEnvelope && <span className="text-xs text-zinc-500">Clear active envelope first (click &ldquo;New cycle →&rdquo; below)</span>}
            </div>
          </StepCard>

          {/* Step 2 — Deposit */}
          <StepCard
            step={2}
            title="Lock task earnings in Atlas vault"
            subtitle="Earnings deposited as a UTXO-style position commitment. This backing guarantees the keeper can repay the loan at deadline."
            status={!isConnected ? "pending" : hasDeposit ? "done" : hasBorrowed ? "ready" : "pending"}
          >
            <div className="flex items-center gap-3 flex-wrap">
              <TxButton
                label={`Deposit ${Number(EARNINGS_AMT) / 1e6} USDC`}
                onClick={deposit}
                loading={busy["deposit"]}
                disabled={!isConnected || !hasBorrowed || hasDeposit || hasEnvelope}
              />
              {demo.positionHash && (
                <span className="text-xs text-zinc-400 font-mono break-all">
                  pos: {demo.positionHash.slice(0, 18)}…
                </span>
              )}
            </div>
          </StepCard>

          {/* Step 3 — Register envelope */}
          <StepCard
            step={3}
            title="Pre-authorize repayment — agent goes offline"
            subtitle="Sign repayment intent once. Atlas enforces it permissionlessly at deadline. Agent can disconnect after this step."
            status={!isConnected ? "pending" : hasEnvelope ? "done" : hasDeposit ? "ready" : "pending"}
          >
            <div className="flex flex-col gap-3">
              <div className="text-xs text-zinc-500 space-y-0.5">
                <div>Condition: <span className="text-zinc-300">block.timestamp &gt; loanDeadline (+7 days)</span></div>
                <div>Adapter: <span className="text-zinc-300">ClawloanRepayAdapter — repays debt, returns surplus to vault</span></div>
                <div>Keeper reward: <span className="text-zinc-300">0.1% of {Number(EARNINGS_AMT)/1e6} USDC = {Number(EARNINGS_AMT)*10/10000/1e6} USDC per trigger</span></div>
              </div>
              <div className="flex items-center gap-3 flex-wrap">
                <TxButton
                  label="Sign & Register Envelope"
                  onClick={registerEnvelope}
                  loading={busy["register"]}
                  disabled={!isConnected || !hasDeposit || hasEnvelope}
                />
                {demo.envelopeHash && (
                  <span className="text-xs text-emerald-400">
                    Registered — repayment guaranteed regardless of agent liveness
                  </span>
                )}
              </div>
              {/* Agent offline badge */}
              {agentOffline && (
                <div className="rounded-xl border border-amber-800/40 bg-amber-950/20 px-4 py-2.5 flex items-center gap-3">
                  <span className="text-lg">📴</span>
                  <div>
                    <p className="text-xs font-medium text-amber-300">Agent is now offline</p>
                    <p className="text-xs text-zinc-600 mt-0.5">
                      The keeper doesn't need the agent's involvement. Open{" "}
                      <a href="?role=keeper" target="_blank" rel="noopener noreferrer" className="text-emerald-400 hover:underline">Keeper Mode →</a>
                      {" "}in a new tab to trigger from a different wallet, or use the buttons below.
                    </p>
                  </div>
                </div>
              )}
            </div>
          </StepCard>

          {/* Step 4 — Keeper trigger */}
          <StepCard
            step={4}
            title="Keeper triggers repayment — autonomous execution"
            subtitle="Any address calls trigger() once condition is met. No agent key, no agent signature, no agent availability required."
            status={!isConnected ? "pending" : positionSpent ? "done" : hasEnvelope ? "ready" : "pending"}
          >
            <div className="flex flex-col gap-3">
              <div className="text-xs text-zinc-500">
                Warps Anvil time past the loan deadline, then calls{" "}
                <span className="font-mono text-zinc-300">registry.trigger()</span>.{" "}
                Keeper verifies conditions on-chain and executes the pre-committed intent —
                loan repaid, surplus returned to vault, receipt emitted.
              </div>
              <div className="flex items-center gap-3 flex-wrap">
                <TxButton
                  label="Trigger as Keeper (this wallet)"
                  onClick={keeperTrigger}
                  loading={busy["trigger"]}
                  disabled={!isConnected || !hasEnvelope || positionSpent}
                  variant="keeper"
                />
                <TxButton
                  label="⚡ Auto-simulate rest"
                  onClick={autoSimulate}
                  loading={busy["simulate"]}
                  disabled={!isConnected || !hasEnvelope || positionSpent}
                  variant="secondary"
                />
              </div>
              {keeperFeeEarned > 0n && (
                <div className="rounded-lg border border-emerald-800/30 bg-emerald-950/20 px-3 py-2 text-xs flex items-center justify-between">
                  <span className="text-zinc-500">Keeper fee earned</span>
                  <span className="text-emerald-400 font-medium">{(Number(keeperFeeEarned) / 1e6).toFixed(2)} USDC</span>
                </div>
              )}
              {positionSpent && keeperFeeEarned === 0n && <span className="text-xs text-emerald-400">Loan repaid — receipt added to accumulator</span>}
            </div>
          </StepCard>

          {/* Step 5 — Credit proof (climax) */}
          <StepCard
            step={5}
            title="Prove repayment history → unlock higher credit tier"
            subtitle="Submit ZK proof of on-chain receipts. CreditVerifier upgrades your tier. Borrow limit increases permanently."
            status={!isConnected ? "pending" : chain.creditTier > 0 ? "done" : canSubmitProof ? "ready" : "pending"}
          >
            <div className="flex flex-col gap-3">
              {/* Tier unlock preview */}
              {canSubmitProof && (
                <div className={`rounded-xl border ${TIER_BORDER[1]} ${TIER_BG[1]} px-4 py-3`}>
                  <div className="flex items-center justify-between mb-2">
                    <div>
                      <span className="text-xs text-zinc-400">About to unlock</span>
                      <div className={`text-lg font-extrabold mt-0.5 ${TIER_COLORS[1]}`}>BRONZE</div>
                    </div>
                    <div className="text-right">
                      <span className="text-xs text-zinc-400">New borrow limit</span>
                      <div className={`text-lg font-extrabold mt-0.5 ${TIER_COLORS[1]}`}>$2,000</div>
                    </div>
                  </div>
                  <p className="text-xs text-zinc-600">
                    Phase 1 uses MockCircuit1Verifier (same interface as UltraHonk ZK verifier — Phase 2).
                    Repayment proof verified on-chain.
                  </p>
                </div>
              )}
              {/* Tier unlocked confirmation */}
              {chain.creditTier > 0 && (
                <div className={`rounded-xl border ${TIER_BORDER[curTier]} ${TIER_BG[curTier]} px-4 py-3`}>
                  <div className="flex items-center justify-between">
                    <div>
                      <span className="text-xs text-zinc-400">Current tier</span>
                      <div className={`text-lg font-extrabold mt-0.5 ${TIER_COLORS[curTier]}`}>
                        {TIER_NAMES[curTier]}
                      </div>
                    </div>
                    <div className="text-right">
                      <span className="text-xs text-zinc-400">Max borrow</span>
                      <div className={`text-lg font-extrabold mt-0.5 ${TIER_COLORS[curTier]}`}>
                        ${TIER_MAXBORROW[curTier].toLocaleString()}
                      </div>
                    </div>
                  </div>
                  {curTier < 4 && (
                    <p className="text-xs text-zinc-500 mt-2">
                      {moreNeeded} more repayment{moreNeeded !== 1 ? "s" : ""} to reach{" "}
                      <span className={TIER_COLORS[nextTier]}>{TIER_NAMES[nextTier]}</span>{" "}
                      (${TIER_MAXBORROW[nextTier].toLocaleString()} max)
                    </p>
                  )}
                </div>
              )}
              <div className="flex items-center gap-3">
                <TxButton
                  label="Submit Credit Proof"
                  onClick={submitCreditProof}
                  loading={busy["credit"]}
                  disabled={!isConnected || !canSubmitProof}
                  variant="secondary"
                />
              </div>
            </div>
          </StepCard>

          {/* New-cycle banner */}
          {loanRepaid && (
            <div className="rounded-2xl border border-emerald-700 bg-emerald-950/30 p-5 flex items-center justify-between gap-4">
              <div>
                <p className="text-emerald-300 font-semibold text-sm">
                  {cycleComplete ? "✓ Cycle complete — credit tier upgraded!" : "Loan repaid autonomously!"}
                </p>
                <p className="text-emerald-600 text-xs mt-1">
                  {cycleComplete
                    ? nextCycleLabel
                    : "Submit the credit proof above to record the repayment, then start a new cycle."}
                </p>
              </div>
              <TxButton
                label={cycleComplete ? nextCycleLabel : "New cycle →"}
                onClick={resetCycle}
                loading={false}
                disabled={false}
                variant="secondary"
              />
            </div>
          )}

        </div>

        {/* Right: credit profile + keeper network + log */}
        <div className="flex flex-col gap-4">

          {/* Agent Persona Card */}
          <div className="rounded-2xl border border-zinc-700 bg-zinc-900 p-5">
            <div className="flex items-center gap-3 mb-4">
              <div className="w-10 h-10 rounded-full bg-indigo-900/60 border border-indigo-700/50 flex items-center justify-center text-lg">🤖</div>
              <div>
                <div className="text-sm font-semibold text-zinc-200">Atlas Bot #1</div>
                <div className="text-xs text-zinc-500 font-mono">
                  {address ? `${address.slice(0, 10)}…${address.slice(-6)}` : "not connected"}
                </div>
              </div>
              <div className={`ml-auto px-2 py-0.5 rounded-full text-xs font-medium ${agentOffline ? "bg-amber-900/40 text-amber-400 border border-amber-800/40" : "bg-emerald-900/40 text-emerald-400 border border-emerald-800/40"}`}>
                {agentOffline ? "📴 offline" : "● online"}
              </div>
            </div>

            {/* Tier badge */}
            <div className={`rounded-xl border ${TIER_BORDER[curTier]} ${TIER_BG[curTier]} p-4 mb-4`}>
              <div className="flex items-center justify-between mb-1">
                <span className={`text-xl font-extrabold tracking-wide ${TIER_COLORS[curTier]}`}>
                  {TIER_NAMES[curTier]}
                </span>
                <span className={`text-sm font-bold ${TIER_COLORS[curTier]}`}>
                  ${TIER_MAXBORROW[curTier].toLocaleString()} USDC
                </span>
              </div>
              <div className="text-xs text-zinc-500 mb-3">max borrow limit</div>

              {curTier < 4 && (
                <>
                  <div className="w-full h-1.5 bg-zinc-700 rounded-full overflow-hidden mb-1.5">
                    <div
                      className={`h-full rounded-full transition-all duration-700 ${
                        curTier === 0 ? "bg-amber-500" :
                        curTier === 1 ? "bg-slate-300" :
                        curTier === 2 ? "bg-yellow-400" : "bg-cyan-400"
                      }`}
                      style={{ width: `${progressPct}%` }}
                    />
                  </div>
                  <div className="flex justify-between text-xs text-zinc-500">
                    <span>{curCount} repayment{curCount !== 1 ? "s" : ""} proven</span>
                    <span>
                      {moreNeeded > 0 ? `${moreNeeded} more to ` : "→ "}
                      <span className={TIER_COLORS[nextTier]}>{TIER_NAMES[nextTier]}</span>
                    </span>
                  </div>
                </>
              )}
              {curTier === 4 && <div className="text-xs text-cyan-400">Maximum tier — PLATINUM achieved</div>}
            </div>

            {/* Tier roadmap */}
            <div className="space-y-1.5 mb-4">
              {TIER_NAMES.map((name, i) => (
                <div key={name} className={`flex items-center justify-between text-xs rounded-lg px-3 py-1.5 ${
                  i === curTier ? `${TIER_BG[i]} border ${TIER_BORDER[i]}` : ""
                }`}>
                  <div className="flex items-center gap-2">
                    <span className={i <= curTier ? TIER_COLORS[i] : "text-zinc-700"}>
                      {i < curTier ? "✓" : i === curTier ? "●" : "○"}
                    </span>
                    <span className={i <= curTier ? TIER_COLORS[i] : "text-zinc-600"}>{name}</span>
                  </div>
                  <div className="flex items-center gap-3">
                    <span className={i <= curTier ? "text-zinc-400" : "text-zinc-700"}>
                      {TIER_THRESHOLDS[i]}+ repay
                    </span>
                    <span className={`font-mono ${i <= curTier ? TIER_COLORS[i] : "text-zinc-700"}`}>
                      ${TIER_MAXBORROW[i].toLocaleString()}
                    </span>
                  </div>
                </div>
              ))}
            </div>

            {/* Live stats */}
            <div className="border-t border-zinc-800 pt-3 space-y-1.5 text-xs">
              <StateRow label="Receipts on-chain"  value={chain.receiptCount.toString()} />
              <StateRow label="Wallet USDC"        value={`${(Number(chain.walletUsdc) / 1e6).toFixed(2)}`} />
              <StateRow label="Vault USDC"         value={`${(Number(chain.vaultUsdc)  / 1e6).toFixed(2)}`} />
              <StateRow label="Loan debt"          value={`${(Number(chain.debt) / 1e6).toFixed(2)}`} highlight={chain.debt > 0n} />
              {keeperFeeEarned > 0n && (
                <StateRow label="Keeper fee earned" value={`${(Number(keeperFeeEarned) / 1e6).toFixed(2)} USDC`} />
              )}
              <StateRow label="Position"           value={demo.positionHash ? demo.positionHash.slice(0, 12) + "…" : "—"} mono />
              <StateRow label="Encumbered"         value={chain.isEncumbered ? "yes" : "no"} />
            </div>
          </div>

          {/* Keeper network — visible after envelope registered */}
          <KeeperNetworkPanel
            envelopeRegistered={hasEnvelope}
            triggered={positionSpent}
            triggerTx={triggerTx}
            address={address}
          />

          {/* Lender perspective panel (Phase 1 enhancement) */}
          <LenderPanel
            loanAmount={BORROW_AMT}
            debt={chain.debt}
            positionSpent={positionSpent}
            envelopeActive={hasEnvelope}
            keeperFeeEarned={keeperFeeEarned}
          />

          {/* Contracts (collapsible) */}
          <details className="rounded-2xl border border-zinc-800 bg-zinc-900">
            <summary className="px-4 py-3 text-xs font-semibold text-zinc-400 cursor-pointer select-none">
              Deployed contracts
            </summary>
            <div className="px-4 pb-3 space-y-1.5 text-xs font-mono">
              {Object.entries(ADDRESSES).map(([name, addr]) => (
                <div key={name} className="flex justify-between gap-2">
                  <span className="text-zinc-500 shrink-0">{name.replace("Mock", "")}</span>
                  <span className="text-zinc-400 truncate">{(addr as string).slice(0, 10)}…</span>
                </div>
              ))}
            </div>
          </details>

          {/* Log */}
          <div>
            <h2 className="text-sm font-semibold text-zinc-300 mb-2">Activity Log</h2>
            <LogPanel entries={logs} />
          </div>
        </div>
      </main>
    </div>
  );
}

function StateRow({ label, value, mono, highlight }: { label: string; value: string; mono?: boolean; highlight?: boolean }) {
  return (
    <div className="flex justify-between gap-2 items-baseline">
      <span className="text-zinc-500 text-xs">{label}</span>
      <span className={`text-xs ${mono ? "font-mono" : ""} ${highlight ? "text-red-400" : "text-zinc-200"}`}>{value}</span>
    </div>
  );
}
