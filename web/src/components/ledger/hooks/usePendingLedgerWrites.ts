import { useCallback, useEffect, useMemo, useState } from "react";
import { readJson } from "@/lib/clientFetch";
import type { BalanceAssertion, ParsedTransaction } from "@/lib/schemas";
import { haptic } from "../haptics";

type PendingEntry = ParsedTransaction | BalanceAssertion;

export type PendingLedgerWrite = {
  id: string;
  createdAt: number;
  entry: PendingEntry;
};

const pendingWritesKey = "ledger_pending_writes";

function readPendingWrites(): PendingLedgerWrite[] {
  if (typeof window === "undefined") return [];
  try {
    const raw = localStorage.getItem(pendingWritesKey);
    const parsed = raw ? JSON.parse(raw) : [];
    return Array.isArray(parsed) ? parsed.filter((item) => item?.id && item?.entry) as PendingLedgerWrite[] : [];
  } catch {
    return [];
  }
}

function writePendingWrites(writes: PendingLedgerWrite[]) {
  if (typeof window === "undefined") return;
  try {
    localStorage.setItem(pendingWritesKey, JSON.stringify(writes));
    window.dispatchEvent(new Event("ledger-pending-writes-change"));
  } catch {
    // Keep the in-memory queue even if localStorage is unavailable.
  }
}

function makePendingWrite(entry: PendingEntry): PendingLedgerWrite {
  const id = typeof crypto !== "undefined" && "randomUUID" in crypto ? crypto.randomUUID() : `${Date.now()}-${Math.random().toString(36).slice(2)}`;
  return { id, createdAt: Date.now(), entry };
}

async function appendPendingEntry(entry: PendingEntry) {
  const res = await fetch("/api/ledger/append", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(entry) });
  const data = await readJson<{ error?: string }>(res);
  if (!res.ok) throw new Error(data.error || "同步失败");
}

export function usePendingLedgerWrites({ load, refreshGitStatus, showToast }: { load: (forceFresh?: boolean) => void | Promise<void>; refreshGitStatus: () => void | Promise<void>; showToast: (kind: "info" | "success" | "error", text: string) => void }) {
  const [pendingWrites, setPendingWrites] = useState<PendingLedgerWrite[]>(() => readPendingWrites());
  const [syncingPendingWrites, setSyncingPendingWrites] = useState(false);

  useEffect(() => {
    const refresh = () => setPendingWrites(readPendingWrites());
    window.addEventListener("storage", refresh);
    window.addEventListener("ledger-pending-writes-change", refresh);
    return () => {
      window.removeEventListener("storage", refresh);
      window.removeEventListener("ledger-pending-writes-change", refresh);
    };
  }, []);

  const persist = useCallback((next: PendingLedgerWrite[]) => {
    setPendingWrites(next);
    writePendingWrites(next);
  }, []);

  const enqueuePendingWrites = useCallback((entries: PendingEntry[]) => {
    if (!entries.length) return;
    const queued = entries.map(makePendingWrite);
    setPendingWrites((current) => {
      const next = [...current, ...queued];
      writePendingWrites(next);
      return next;
    });
    haptic([8, 30, 8]);
  }, []);

  const syncPendingWrites = useCallback(async () => {
    const current = readPendingWrites();
    if (!current.length || syncingPendingWrites) return;
    if (typeof navigator !== "undefined" && !navigator.onLine) {
      showToast("info", `仍处于离线状态，${current.length} 条待同步已保留`);
      return;
    }

    setSyncingPendingWrites(true);
    showToast("info", `正在同步 ${current.length} 条待写入记录`);
    const remaining = [...current];
    let syncedCount = 0;
    try {
      while (remaining.length) {
        const item = remaining[0];
        await appendPendingEntry(item.entry);
        syncedCount += 1;
        remaining.shift();
        persist([...remaining]);
      }
      haptic([6, 24, 10]);
      showToast("success", `已同步 ${syncedCount} 条待写入记录`);
      await load(true);
      await refreshGitStatus();
    } catch (error) {
      persist(remaining);
      showToast("error", error instanceof Error ? error.message : `同步中断，剩余 ${remaining.length} 条`);
    } finally {
      setSyncingPendingWrites(false);
    }
  }, [load, persist, refreshGitStatus, showToast, syncingPendingWrites]);

  const pendingWriteCount = pendingWrites.length;
  const pendingWriteSummary = useMemo(() => {
    if (!pendingWrites.length) return "";
    const oldest = new Date(Math.min(...pendingWrites.map((item) => item.createdAt))).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
    return `${pendingWrites.length} 条待同步，最早 ${oldest}`;
  }, [pendingWrites]);

  return { pendingWrites, pendingWriteCount, pendingWriteSummary, enqueuePendingWrites, syncPendingWrites, syncingPendingWrites };
}
