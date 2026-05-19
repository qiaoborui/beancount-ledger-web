"use client";

import { useEffect, useState, type ReactNode } from "react";
import { createPortal } from "react-dom";

type MobileSheetProps = {
  open: boolean;
  title: ReactNode;
  children: ReactNode;
  footer?: ReactNode;
  onClose: () => void;
  size?: "md" | "lg";
  align?: "right" | "center";
  closeLabel?: string;
  zIndexClassName?: string;
};

export function MobileSheet({ open, title, children, footer, onClose, size = "lg", align = "right", closeLabel = "关闭", zIndexClassName = "z-[100]" }: MobileSheetProps) {
  const [mounted, setMounted] = useState(false);

  useEffect(() => setMounted(true), []);

  useEffect(() => {
    if (!open) return;
    const originalOverflow = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.key === "Escape") onClose();
    };
    window.addEventListener("keydown", handleKeyDown);
    return () => {
      document.body.style.overflow = originalOverflow;
      window.removeEventListener("keydown", handleKeyDown);
    };
  }, [onClose, open]);

  if (!mounted || !open) return null;

  const maxWidth = size === "md" ? "sm:max-w-2xl" : "sm:max-w-xl";
  const desktopAlign = align === "center" ? "sm:items-center sm:justify-center sm:p-4" : "sm:items-stretch sm:justify-end";
  const desktopRadius = align === "center" ? "sm:h-auto sm:max-h-[90dvh] sm:rounded-3xl" : "sm:h-full sm:rounded-none";

  return createPortal(
    <div className={`sheet-backdrop fixed inset-0 ${zIndexClassName} flex items-end bg-ink/35 p-0 ${desktopAlign}`} onClick={onClose}>
      <div className={`mobile-sheet kami-float flex h-[92dvh] w-full flex-col overflow-hidden rounded-t-[28px] bg-paper ${maxWidth} ${desktopRadius}`} onClick={(event) => event.stopPropagation()} role="dialog" aria-modal="true">
        <div className="shrink-0 border-b border-line bg-paper/95 px-5 pb-3 pt-5 backdrop-blur sm:pt-[calc(env(safe-area-inset-top)+1.25rem)]">
          <div className="flex items-center justify-between gap-4">
            <h2 className="min-w-0 font-serif text-2xl">{title}</h2>
            <button className="shrink-0 rounded-xl border border-line px-3 py-1 text-sm" onClick={onClose}>{closeLabel}</button>
          </div>
        </div>
        <div className="min-h-0 flex-1 overflow-y-auto px-5 py-4">{children}</div>
        {footer && <div className="shrink-0 border-t border-line bg-paper/95 px-5 py-3 pb-[calc(env(safe-area-inset-bottom)+0.75rem)] backdrop-blur">{footer}</div>}
      </div>
    </div>,
    document.body,
  );
}
