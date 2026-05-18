export function Toast({ toast }: { toast: { kind: "info" | "success" | "error"; text: string } | null }) {
  if (!toast) return null;
  const dot = toast.kind === "error" ? "bg-[var(--danger)]" : toast.kind === "success" ? "bg-[var(--success)]" : "bg-brand";
  return <div className="kami-float fixed right-4 z-50 flex max-w-sm items-start gap-2 rounded-2xl border border-line bg-panel px-4 py-3 text-sm text-warm" style={{ top: `calc(5rem + env(safe-area-inset-top))` }}><span className={`mt-1.5 h-2 w-2 shrink-0 rounded-full ${dot}`} />{toast.text}</div>;
}

export function HiddenPanel({ text }: { text: string }) {
  return <div className="rounded-2xl border border-line bg-panel p-6 text-center text-sm leading-6 text-stone">{text}</div>;
}

export function Metric({ label, value, cls }: { label: string; value: string; cls: string }) {
  return <div className="min-w-0"><div className="text-[11px] uppercase tracking-[0.14em] text-stone">{label}</div><div className={`mt-1 truncate font-serif font-medium ${cls}`}>{value}</div></div>;
}
