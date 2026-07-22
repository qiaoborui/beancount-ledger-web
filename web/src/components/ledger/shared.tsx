import { CircleCheck, Info, TriangleAlert, X } from "lucide-react";
import type { ReactNode } from "react";
import { createPortal } from "react-dom";
import { cn } from "@/lib/utils";
import type { LedgerToast } from "./hooks/useToast";

export function Toast({ toast, onClose }: { toast: LedgerToast; onClose: () => void }) {
  if (!toast || typeof document === "undefined") return null;
  const Icon = toast.kind === "error" ? TriangleAlert : toast.kind === "success" ? CircleCheck : Info;
  const tone = toast.kind === "error" ? "text-[var(--danger)]" : toast.kind === "success" ? "text-[var(--success)]" : "text-brand";
  return createPortal(
    <div className="pointer-events-none fixed inset-x-0 z-[200] flex justify-center px-3 sm:justify-end sm:px-4" style={{ top: `calc(4.75rem + env(safe-area-inset-top))` }}>
      <div key={toast.id} className="ledger-toast kami-float pointer-events-auto flex w-full max-w-sm items-start gap-3 rounded-2xl border border-line bg-panel px-4 py-3 text-sm text-warm" role={toast.kind === "error" ? "alert" : "status"} aria-live={toast.kind === "error" ? "assertive" : "polite"}>
        <Icon className={`mt-0.5 h-4 w-4 shrink-0 ${tone}`} aria-hidden="true" />
        <span className="min-w-0 flex-1 whitespace-pre-wrap leading-5">{toast.text}</span>
        <button type="button" className="-my-1.5 -mr-2 grid h-10 w-10 shrink-0 place-items-center rounded-xl text-stone hover:bg-tag hover:text-ink focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand" onClick={onClose} aria-label="关闭提示">
          <X className="h-4 w-4" />
        </button>
      </div>
    </div>,
    document.body,
  );
}

export function HiddenPanel({ text }: { text: string }) {
  return <div className="rounded-2xl border border-line bg-panel p-6 text-center text-sm leading-6 text-stone">{text}</div>;
}

export function Metric({ label, value, cls }: { label: string; value: string; cls: string }) {
  return <div className="min-w-0"><div className="text-[11px] font-semibold uppercase tracking-[0.08em] text-stone">{label}</div><div className={`mt-1 truncate font-serif font-medium ${cls}`} title={value}>{value}</div></div>;
}

export function ResponsiveValueRow({
  label,
  value,
  detail,
  className,
  contentClassName,
  labelClassName,
  valueClassName,
  detailClassName,
  valueTitle,
}: {
  label: ReactNode;
  value: ReactNode;
  detail?: ReactNode;
  className?: string;
  contentClassName?: string;
  labelClassName?: string;
  valueClassName?: string;
  detailClassName?: string;
  valueTitle?: string;
}) {
  return (
    <div className={cn("@container min-w-0 max-w-full", className)}>
      <div className={cn("grid min-w-0 grid-cols-1 gap-x-3 gap-y-0.5 @sm:grid-cols-[minmax(0,1fr)_auto] @sm:items-baseline", contentClassName)}>
        <div className={cn("min-w-0 [overflow-wrap:anywhere]", labelClassName)}>{label}</div>
        <div className={cn("min-w-0 max-w-full truncate text-left tabular-nums @sm:text-right", valueClassName)} title={valueTitle}>
          {value}
        </div>
      </div>
      {detail != null && <div className={cn("mt-0.5 min-w-0 [overflow-wrap:anywhere]", detailClassName)}>{detail}</div>}
    </div>
  );
}
