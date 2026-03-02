import { useEffect, useState } from "react";

const KEEPERS = [
  { name: "Atlas Keeper #1",   addr: "0x742d35Cc6634C0532925a3b8D4C9F3" },
  { name: "Gelato Network",    addr: "0x8fA15Ce3e4D6ECF85BEf2e09A83D7A" },
  { name: "Chainlink Keeper",  addr: "0x23c5d9E8E89e14bA3D7E08d6F3E291" },
  { name: "You (this wallet)", addr: null },  // filled with real address
] as const;

interface Props {
  envelopeRegistered: boolean;
  triggered: boolean;
  triggerTx?: string;
  address?: string;
}

export function KeeperNetworkPanel({ envelopeRegistered, triggered, triggerTx, address }: Props) {
  const [firingIndex, setFiringIndex] = useState<number | null>(null);
  const [showFired, setShowFired]     = useState(false);

  useEffect(() => {
    if (triggered && firingIndex === null) {
      // "You" (index 3) fires
      setFiringIndex(3);
      setTimeout(() => setShowFired(true), 300);
    }
  }, [triggered, firingIndex]);

  if (!envelopeRegistered && !triggered) return null;

  return (
    <div className="rounded-2xl border border-zinc-800 bg-zinc-900 p-5">
      <div className="flex items-center justify-between mb-3">
        <h2 className="text-sm font-semibold text-zinc-300 flex items-center gap-2">
          <span className="w-2 h-2 rounded-full bg-emerald-500 animate-pulse" />
          Keeper Network
        </h2>
        {!triggered && (
          <span className="text-xs text-zinc-600 font-mono">watching envelope…</span>
        )}
        {triggered && (
          <span className="text-xs text-emerald-400">executed</span>
        )}
      </div>

      <div className="space-y-2 mb-3">
        {KEEPERS.map((k, i) => {
          const isFiring = i === firingIndex;
          const displayAddr = k.addr === null
            ? (address ? `${address.slice(0, 14)}…` : "0x???")
            : `${k.addr.slice(0, 14)}…`;

          return (
            <div
              key={k.name}
              className={`flex items-center justify-between rounded-lg px-3 py-2 transition-all duration-500 text-xs ${
                isFiring && showFired
                  ? "bg-emerald-900/40 border border-emerald-700"
                  : "bg-zinc-800/50 border border-zinc-800"
              }`}
            >
              <div className="flex items-center gap-2">
                <span className={`w-1.5 h-1.5 rounded-full ${
                  triggered
                    ? (isFiring ? "bg-emerald-400" : "bg-zinc-600")
                    : "bg-amber-400 animate-pulse"
                }`} />
                <span className={isFiring && showFired ? "text-emerald-300 font-medium" : "text-zinc-400"}>
                  {k.name}
                </span>
              </div>
              <div className="flex items-center gap-2">
                <span className="font-mono text-zinc-600">{displayAddr}</span>
                {isFiring && showFired && (
                  <span className="text-emerald-400 font-semibold">fired ⚡</span>
                )}
                {!triggered && (
                  <span className="text-zinc-600">watching</span>
                )}
                {triggered && !isFiring && (
                  <span className="text-zinc-700">missed</span>
                )}
              </div>
            </div>
          );
        })}
      </div>

      {showFired && triggerTx && (
        <div className="rounded-lg bg-emerald-950/30 border border-emerald-800/30 px-3 py-2 text-xs">
          <span className="text-zinc-500">Trigger tx: </span>
          <span className="font-mono text-emerald-400">{triggerTx.slice(0, 18)}…</span>
        </div>
      )}

      {!triggered && (
        <p className="text-xs text-zinc-600 mt-2 leading-relaxed">
          Any of these addresses can call{" "}
          <span className="font-mono text-zinc-500">registry.trigger()</span> once the
          condition is met. No coordination required.
        </p>
      )}
    </div>
  );
}
