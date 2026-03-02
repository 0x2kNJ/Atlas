import { useEffect, useState } from "react";

const TIER_NAMES   = ["NEW", "BRONZE", "SILVER", "GOLD", "PLATINUM"] as const;
const TIER_COLORS  = ["text-zinc-400", "text-amber-500", "text-slate-300", "text-yellow-400", "text-cyan-300"] as const;
const TIER_BG      = ["bg-zinc-900", "bg-amber-900/60", "bg-slate-800/80", "bg-yellow-900/60", "bg-cyan-900/60"] as const;
const TIER_BORDER  = ["border-zinc-700", "border-amber-600", "border-slate-400", "border-yellow-500", "border-cyan-500"] as const;
const TIER_MAXBORROW = [500, 2000, 10000, 50000, 100000] as const;

interface Props {
  tier: number;         // new tier index
  prevTier: number;     // previous tier
  onDismiss: () => void;
}

export function TierUpgradeOverlay({ tier, prevTier, onDismiss }: Props) {
  const [visible, setVisible] = useState(true);
  const [animIn, setAnimIn]   = useState(false);

  useEffect(() => {
    // trigger entrance animation
    const t1 = setTimeout(() => setAnimIn(true), 50);
    // auto-dismiss after 5s
    const t2 = setTimeout(() => {
      setAnimIn(false);
      setTimeout(() => { setVisible(false); onDismiss(); }, 400);
    }, 5000);
    return () => { clearTimeout(t1); clearTimeout(t2); };
  }, [onDismiss]);

  if (!visible) return null;

  const t = Math.min(tier, 4) as 0|1|2|3|4;
  const prevT = Math.min(prevTier, 4) as 0|1|2|3|4;

  return (
    <div className={`fixed inset-0 z-50 flex items-center justify-center transition-all duration-400 ${animIn ? "bg-black/70 backdrop-blur-sm" : "bg-transparent"}`}>
      <div className={`transition-all duration-400 ${animIn ? "opacity-100 scale-100 translate-y-0" : "opacity-0 scale-90 translate-y-4"}`}>
        <div className={`rounded-3xl border-2 ${TIER_BORDER[t]} ${TIER_BG[t]} px-16 py-10 text-center max-w-md mx-4 shadow-2xl`}>

          {/* Sparkle */}
          <div className="text-4xl mb-2 animate-bounce">✨</div>

          <div className="text-xs text-zinc-400 uppercase tracking-widest mb-2">Credit Tier Upgraded</div>

          {/* Tier transition */}
          <div className="flex items-center justify-center gap-3 mb-5">
            <span className={`text-lg font-bold ${TIER_COLORS[prevT]} opacity-60`}>{TIER_NAMES[prevT]}</span>
            <span className="text-zinc-500 text-xl">→</span>
            <span className={`text-3xl font-extrabold ${TIER_COLORS[t]}`}>{TIER_NAMES[t]}</span>
          </div>

          {/* New max borrow */}
          <div className={`rounded-2xl border ${TIER_BORDER[t]} bg-black/20 px-6 py-4 mb-6`}>
            <div className="text-xs text-zinc-400 mb-1">New borrowing limit</div>
            <div className={`text-4xl font-extrabold ${TIER_COLORS[t]}`}>
              ${TIER_MAXBORROW[t].toLocaleString()}
            </div>
            <div className="text-xs text-zinc-500 mt-1">USDC per cycle</div>
          </div>

          <p className="text-xs text-zinc-500 mb-5 leading-relaxed">
            On-chain ZK proof verified. ReceiptAccumulator confirmed repayment.
            Credit tier recorded on CreditVerifier contract.
          </p>

          <button
            onClick={() => { setAnimIn(false); setTimeout(() => { setVisible(false); onDismiss(); }, 300); }}
            className="px-6 py-2 rounded-xl bg-zinc-800 hover:bg-zinc-700 text-zinc-200 text-sm font-medium transition-colors"
          >
            Continue →
          </button>
        </div>
      </div>
    </div>
  );
}
