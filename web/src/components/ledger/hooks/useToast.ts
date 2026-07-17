import { useCallback, useEffect, useRef, useState } from "react";

export type LedgerToast = { id: number; kind: "info" | "success" | "error"; text: string } | null;

export function useToast() {
  const [toast, setToast] = useState<LedgerToast>(null);
  const timerRef = useRef<number | null>(null);
  const nextIdRef = useRef(0);

  const clearToast = useCallback(() => {
    if (timerRef.current !== null) window.clearTimeout(timerRef.current);
    timerRef.current = null;
    setToast(null);
  }, []);

  const showToast = useCallback((kind: "info" | "success" | "error", text: string) => {
    if (timerRef.current !== null) window.clearTimeout(timerRef.current);
    const id = ++nextIdRef.current;
    setToast({ id, kind, text });
    timerRef.current = window.setTimeout(() => {
      setToast((current) => current?.id === id ? null : current);
      timerRef.current = null;
    }, kind === "error" ? 6500 : 3200);
  }, []);

  useEffect(() => () => {
    if (timerRef.current !== null) window.clearTimeout(timerRef.current);
  }, []);

  return { toast, showToast, clearToast };
}
