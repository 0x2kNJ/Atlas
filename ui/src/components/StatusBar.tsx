import { useAccount, useConnect, useDisconnect } from "wagmi";
import { injected } from "wagmi/connectors";

const TIER_LABELS  = ["NEW", "BRONZE", "SILVER", "GOLD", "PLATINUM"] as const;
const TIER_COLORS  = ["text-zinc-400", "text-amber-500", "text-slate-300", "text-yellow-400", "text-cyan-300"] as const;
const TIER_MAXBORROW = [500, 2000, 10000, 50000, 100000] as const;

function fmt(usdc: bigint): string {
  return (Number(usdc) / 1e6).toFixed(2);
}

interface Props {
  walletUsdc:   bigint;
  debt:         bigint;
  vaultUsdc:    bigint;
  creditTier:   number;
  maxBorrow:    bigint;
  receiptCount: bigint;
}

export function StatusBar({ walletUsdc, debt, vaultUsdc, creditTier, maxBorrow: _maxBorrow, receiptCount }: Props) {
  const { address, isConnected } = useAccount();
  const { connect }              = useConnect();
  const { disconnect }           = useDisconnect();

  const tier       = Math.min(creditTier, 4) as 0|1|2|3|4;
  const tierLabel  = TIER_LABELS[tier];
  const tierColor  = TIER_COLORS[tier];
  const maxBorrowDisplay = TIER_MAXBORROW[tier];

  return (
    <div className="border-b border-zinc-800 bg-zinc-950 px-6 py-2.5 flex items-center justify-between gap-4 flex-wrap">
      {/* Left: key numbers */}
      <div className="flex items-center gap-5 text-sm">
        {/* Credit tier — most prominent */}
        <div className="flex items-center gap-2">
          <span className="text-zinc-500 text-xs uppercase tracking-wide">Credit</span>
          <span className={`font-bold text-sm ${tierColor}`}>{tierLabel}</span>
          <span className="text-zinc-600 text-xs">·</span>
          <span className={`font-mono text-xs ${tierColor}`}>${maxBorrowDisplay} max</span>
          <span className="text-zinc-600 text-xs">·</span>
          <span className="text-zinc-500 text-xs">{receiptCount.toString()} receipt{receiptCount !== 1n ? "s" : ""}</span>
        </div>

        {/* Divider */}
        <span className="text-zinc-700">|</span>

        <Stat label="Wallet" value={`${fmt(walletUsdc)}`} />
        <Stat label="Vault"  value={`${fmt(vaultUsdc)}`} />
        {debt > 0n && <Stat label="Debt" value={`${fmt(debt)}`} highlight />}
      </div>

      {/* Right: wallet */}
      {isConnected ? (
        <div className="flex items-center gap-3 text-sm">
          <span className="text-zinc-400 font-mono text-xs">{address?.slice(0, 6)}…{address?.slice(-4)}</span>
          <button
            onClick={() => disconnect()}
            className="text-zinc-500 hover:text-zinc-200 transition-colors text-xs"
          >
            disconnect
          </button>
        </div>
      ) : (
        <button
          onClick={() => connect({ connector: injected() })}
          className="px-4 py-1.5 rounded-lg bg-indigo-600 hover:bg-indigo-500 text-white text-sm font-medium transition-colors"
        >
          Connect Wallet
        </button>
      )}
    </div>
  );
}

function Stat({ label, value, highlight }: { label: string; value: string; highlight?: boolean }) {
  return (
    <div className="flex items-center gap-1.5">
      <span className="text-zinc-500 text-xs uppercase tracking-wide">{label}</span>
      <span className={`font-mono text-xs font-medium ${highlight ? "text-red-400" : "text-zinc-200"}`}>
        {value}
      </span>
    </div>
  );
}
