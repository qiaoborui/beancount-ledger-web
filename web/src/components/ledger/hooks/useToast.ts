import { useState } from "react";

export type LedgerToast = { kind: "info" | "success" | "error"; text: string } | null;

export function useToast() {
  const [toast, setToast] = useState<LedgerToast>(null);

  function showToast(kind: "info" | "success" | "error", text: string) {
    setToast({ kind, text });
    window.setTimeout(() => setToast((current) => current?.text === text ? null : current), kind === "error" ? 6500 : 3200);
  }

  return { toast, setToast, showToast };
}
