import type { ReactNode } from "react";

interface Props {
  label?:     string;
  children?:  ReactNode;
  onClick:    () => void;
  disabled?:  boolean;
  loading?:   boolean;
  variant?:   "primary" | "secondary" | "danger" | "keeper";
}

const VARIANTS = {
  primary:   "bg-indigo-600 hover:bg-indigo-500 text-white disabled:bg-zinc-700 disabled:text-zinc-400",
  secondary: "bg-zinc-700 hover:bg-zinc-600 text-zinc-200 disabled:opacity-40",
  danger:    "bg-red-900/60 hover:bg-red-800/70 text-red-200 border border-red-700 disabled:opacity-40",
  keeper:    "bg-emerald-800/80 hover:bg-emerald-700/90 text-emerald-100 border border-emerald-600 disabled:opacity-40",
};

export function TxButton({ label, children, onClick, disabled, loading, variant = "primary" }: Props) {
  const content = children ?? label;
  return (
    <button
      onClick={onClick}
      disabled={disabled || loading}
      className={`px-4 py-2 rounded-lg text-sm font-semibold transition-colors cursor-pointer disabled:cursor-not-allowed ${VARIANTS[variant]}`}
    >
      {loading ? (
        <span className="flex items-center gap-2">
          <span className="w-3.5 h-3.5 border-2 border-current border-t-transparent rounded-full animate-spin" />
          {content}
        </span>
      ) : content}
    </button>
  );
}
