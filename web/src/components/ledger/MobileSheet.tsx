"use client";

import { useEffect, useRef, useState, type PointerEvent, type ReactNode } from "react";
import { createPortal } from "react-dom";
import { haptic } from "./haptics";

type MobileSheetProps = {
  open: boolean;
  title: ReactNode;
  children: ReactNode;
  footer?: ReactNode;
  onClose: () => void;
  shouldClose?: () => boolean;
  size?: "md" | "lg" | "xl";
  align?: "right" | "center";
  bodyClassName?: string;
  panelClassName?: string;
  closeLabel?: string;
  zIndexClassName?: string;
};

export function MobileSheet({ open, title, children, footer, onClose, shouldClose, size = "lg", align = "right", bodyClassName = "", panelClassName = "", closeLabel = "关闭", zIndexClassName = "z-[100]" }: MobileSheetProps) {
  const [mounted, setMounted] = useState(false);
  const [dragY, setDragY] = useState(0);
  const dragStartRef = useRef({ y: 0, lastY: 0, lastTime: 0, dragging: false });

  const requestClose = () => {
    if (shouldClose && !shouldClose()) return;
    haptic(5);
    onClose();
  };

  function handleDragStart(event: PointerEvent<HTMLDivElement>) {
    if (event.pointerType === "mouse" && event.button !== 0) return;
    event.currentTarget.setPointerCapture(event.pointerId);
    const y = event.clientY;
    dragStartRef.current = { y, lastY: y, lastTime: performance.now(), dragging: true };
    setDragY(0);
  }

  function handleDragMove(event: PointerEvent<HTMLDivElement>) {
    if (!dragStartRef.current.dragging) return;
    const nextY = Math.max(0, event.clientY - dragStartRef.current.y);
    dragStartRef.current.lastY = event.clientY;
    dragStartRef.current.lastTime = performance.now();
    setDragY(Math.min(180, nextY));
  }

  function handleDragEnd(event: PointerEvent<HTMLDivElement>) {
    if (!dragStartRef.current.dragging) return;
    dragStartRef.current.dragging = false;
    if (event.currentTarget.hasPointerCapture(event.pointerId)) event.currentTarget.releasePointerCapture(event.pointerId);
    const finalY = Math.max(0, event.clientY - dragStartRef.current.y);
    const elapsed = Math.max(1, performance.now() - dragStartRef.current.lastTime);
    const velocity = (event.clientY - dragStartRef.current.lastY) / elapsed;
    const shouldDismiss = finalY > 96 || (finalY > 42 && velocity > 0.45);
    setDragY(0);
    if (shouldDismiss) requestClose();
  }

  useEffect(() => setMounted(true), []);

  useEffect(() => {
    if (!open) return;
    const originalOverflow = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.key === "Escape") requestClose();
    };
    window.addEventListener("keydown", handleKeyDown);
    return () => {
      document.body.style.overflow = originalOverflow;
      window.removeEventListener("keydown", handleKeyDown);
    };
  }, [open, requestClose]);

  if (!mounted || !open) return null;

  const maxWidth = size === "xl" ? "sm:max-w-6xl" : size === "md" ? "sm:max-w-2xl" : "sm:max-w-xl";
  const desktopAlign = align === "center" ? "sm:items-center sm:justify-center sm:p-4" : "sm:items-stretch sm:justify-end";
  const desktopRadius = align === "center" ? "sm:h-auto sm:max-h-[90dvh] sm:rounded-3xl" : "sm:h-full sm:rounded-none";

  return createPortal(
    <div className={`sheet-backdrop fixed inset-0 ${zIndexClassName} flex items-end bg-ink/35 p-0 ${desktopAlign}`} onClick={requestClose}>
      <div className={`mobile-sheet kami-float flex h-[92dvh] max-h-[calc(100dvh-env(safe-area-inset-top)-0.75rem)] w-full min-w-0 flex-col overflow-hidden rounded-t-[28px] bg-paper ${maxWidth} ${desktopRadius} ${panelClassName}`} style={{ transform: dragY > 0 ? `translate3d(0, ${dragY}px, 0)` : undefined }} onClick={(event) => event.stopPropagation()} role="dialog" aria-modal="true">
        <div className="shrink-0 border-b border-line bg-paper/95 px-4 pb-3 pt-3 backdrop-blur sm:px-5 sm:pt-[calc(env(safe-area-inset-top)+1.25rem)]">
          <div
            className="mx-auto mb-3 h-1.5 w-12 cursor-grab rounded-full bg-line active:cursor-grabbing sm:hidden"
            onPointerDown={handleDragStart}
            onPointerMove={handleDragMove}
            onPointerUp={handleDragEnd}
            onPointerCancel={handleDragEnd}
            aria-hidden="true"
          />
          <div className="flex items-center justify-between gap-3">
            <h2 className="min-w-0 truncate font-serif text-[1.65rem] leading-tight sm:text-2xl">{title}</h2>
            <button className="shrink-0 rounded-xl border border-line px-3 py-1 text-sm" onClick={requestClose}>{closeLabel}</button>
          </div>
        </div>
        <div className={`min-h-0 min-w-0 flex-1 overflow-y-auto px-4 py-4 sm:px-5 ${bodyClassName}`}>{children}</div>
        {footer && <div className="shrink-0 border-t border-line bg-paper/95 px-4 py-3 pb-[calc(env(safe-area-inset-bottom)+0.75rem)] backdrop-blur sm:px-5">{footer}</div>}
      </div>
    </div>,
    document.body,
  );
}
