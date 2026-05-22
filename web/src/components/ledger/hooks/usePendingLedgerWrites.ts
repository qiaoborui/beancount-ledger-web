import { useCallback, useEffect, useMemo, useState } from "react";
import { readJson } from "@/lib/clientFetch";
import type { BalanceAssertion, ParsedTransaction } from "@/lib/schemas";
import { haptic } from "../haptics";
import {
  mergePendingOperation,
  migrateLegacyPendingWrites,
  type PendingEntry,
  type PendingLedgerOperation,
} from "../pendingLedgerOperations";
import type { Txn } from "../types";

const pendingOperationsKey = "ledger_pending_operations";
const legacyPendingWritesKey = "ledger_pending_writes";
const pendingWritesChangeEvent = "ledger-pending-writes-change";

function makeId() {
  return typeof crypto !== "undefined" && "randomUUID" in crypto
    ? crypto.randomUUID()
    : `${Date.now()}-${Math.random().toString(36).slice(2)}`;
}

function readJsonArray(key: string): unknown[] {
  if (typeof window === "undefined") return [];
  try {
    const raw = localStorage.getItem(key);
    const parsed = raw ? JSON.parse(raw) : [];
    return Array.isArray(parsed) ? parsed : [];
  } catch {
    return [];
  }
}

function readPendingOperations(): PendingLedgerOperation[] {
  if (typeof window === "undefined") return [];
  const operations = readJsonArray(pendingOperationsKey) as PendingLedgerOperation[];
  const legacy = migrateLegacyPendingWrites(readJsonArray(legacyPendingWritesKey));
  if (legacy.length) {
    const next = [...legacy, ...operations];
    writePendingOperations(next);
    try {
      localStorage.removeItem(legacyPendingWritesKey);
    } catch {
      // The migrated operations have already been mirrored in memory.
    }
    return next;
  }
  return operations.filter((item) => item?.id && item?.kind && typeof item.createdAt === "number");
}

function writePendingOperations(operations: PendingLedgerOperation[]) {
  if (typeof window === "undefined") return;
  try {
    localStorage.setItem(pendingOperationsKey, JSON.stringify(operations));
    window.dispatchEvent(new Event(pendingWritesChangeEvent));
  } catch {
    // Keep the in-memory queue even if localStorage is unavailable.
  }
}

function appendOperation(entry: PendingEntry): PendingLedgerOperation {
  return { id: makeId(), createdAt: Date.now(), kind: "append", entry };
}

function updateOperation(source: Txn["source"], entry: ParsedTransaction): PendingLedgerOperation {
  return { id: makeId(), createdAt: Date.now(), kind: "update-transaction", source, entry };
}

function deleteOperation(source: Txn["source"], reason: string): PendingLedgerOperation {
  return { id: makeId(), createdAt: Date.now(), kind: "delete-transaction", source, reason };
}

export async function syncOperation(operation: PendingLedgerOperation) {
  if (operation.kind === "append") {
    const res = await fetch("/api/ledger/append", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(operation.entry) });
    const data = await readJson<{ error?: string }>(res);
    if (!res.ok) throw new Error(data.error || "同步失败");
    return;
  }

  if (operation.kind === "update-transaction") {
    let res = await fetch("/api/ledger/transactions", { method: "PUT", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ source: operation.source, entry: operation.entry }) });
    let data = await readJson<{ error?: string }>(res);
    if (!res.ok && operation.source.hash && data.error?.includes("找不到原交易")) {
      const source = { file: operation.source.file, line: operation.source.line };
      res = await fetch("/api/ledger/transactions", { method: "PUT", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ source, entry: operation.entry }) });
      data = await readJson<{ error?: string }>(res);
    }
    if (!res.ok) throw new Error(data.error || "修改同步失败");
    return;
  }

  let res = await fetch("/api/ledger/transactions", { method: "DELETE", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ source: operation.source, reason: operation.reason }) });
  let data = await readJson<{ error?: string }>(res);
  if (!res.ok && operation.source.hash && data.error?.includes("找不到原交易")) {
    const source = { file: operation.source.file, line: operation.source.line };
    res = await fetch("/api/ledger/transactions", { method: "DELETE", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ source, reason: operation.reason }) });
    data = await readJson<{ error?: string }>(res);
  }
  if (!res.ok) throw new Error(data.error || "删除同步失败");
}

export function usePendingLedgerWrites({ load, refreshGitStatus, showToast }: { load: (forceFresh?: boolean) => void | Promise<void>; refreshGitStatus: () => void | Promise<void>; showToast: (kind: "info" | "success" | "error", text: string) => void }) {
  const [pendingOperations, setPendingOperations] = useState<PendingLedgerOperation[]>(() => readPendingOperations());
  const [syncingPendingWrites, setSyncingPendingWrites] = useState(false);

  useEffect(() => {
    const refresh = () => setPendingOperations(readPendingOperations());
    window.addEventListener("storage", refresh);
    window.addEventListener(pendingWritesChangeEvent, refresh);
    window.addEventListener("online", refresh);
    return () => {
      window.removeEventListener("storage", refresh);
      window.removeEventListener(pendingWritesChangeEvent, refresh);
      window.removeEventListener("online", refresh);
    };
  }, []);

  const persist = useCallback((next: PendingLedgerOperation[]) => {
    setPendingOperations(next);
    writePendingOperations(next);
  }, []);

  const enqueueOperation = useCallback((operation: PendingLedgerOperation) => {
    setPendingOperations((current) => {
      const next = mergePendingOperation(current, operation);
      writePendingOperations(next);
      return next;
    });
    haptic([8, 30, 8]);
  }, []);

  const enqueuePendingWrites = useCallback((entries: PendingEntry[]) => {
    if (!entries.length) return;
    setPendingOperations((current) => {
      const next = [...current, ...entries.map(appendOperation)];
      writePendingOperations(next);
      return next;
    });
    haptic([8, 30, 8]);
  }, []);

  const enqueueTransactionUpdate = useCallback((source: Txn["source"], entry: ParsedTransaction) => {
    enqueueOperation(updateOperation(source, entry));
  }, [enqueueOperation]);

  const enqueueTransactionDelete = useCallback((source: Txn["source"], reason: string) => {
    enqueueOperation(deleteOperation(source, reason));
  }, [enqueueOperation]);

  const syncPendingWrites = useCallback(async () => {
    const current = readPendingOperations();
    if (!current.length || syncingPendingWrites) return;
    if (typeof navigator !== "undefined" && !navigator.onLine) {
      showToast("info", `仍处于离线状态，${current.length} 条待同步操作已保留`);
      return;
    }

    setSyncingPendingWrites(true);
    showToast("info", `正在同步 ${current.length} 条待同步操作`);
    let syncedCount = 0;
    try {
      while (true) {
        const latest = readPendingOperations();
        if (!latest.length) break;
        const item = latest[0];
        await syncOperation(item);
        syncedCount += 1;
        persist(readPendingOperations().filter((operation) => operation.id !== item.id));
      }
      haptic([6, 24, 10]);
      showToast("success", `已同步 ${syncedCount} 条待同步操作`);
      await load(true);
      await refreshGitStatus();
    } catch (error) {
      const remaining = readPendingOperations();
      persist(remaining);
      showToast("error", error instanceof Error ? error.message : `同步中断，剩余 ${remaining.length} 条`);
    } finally {
      setSyncingPendingWrites(false);
    }
  }, [load, persist, refreshGitStatus, showToast, syncingPendingWrites]);

  useEffect(() => {
    const syncWhenOnline = () => {
      void syncPendingWrites();
    };
    window.addEventListener("online", syncWhenOnline);
    return () => window.removeEventListener("online", syncWhenOnline);
  }, [syncPendingWrites]);

  useEffect(() => {
    if (!pendingOperations.length || syncingPendingWrites) return;
    if (typeof navigator !== "undefined" && !navigator.onLine) return;
    const timer = window.setTimeout(() => {
      void syncPendingWrites();
    }, 300);
    return () => window.clearTimeout(timer);
  }, [pendingOperations.length, syncPendingWrites, syncingPendingWrites]);

  const pendingWriteCount = pendingOperations.length;
  const pendingWriteSummary = useMemo(() => {
    if (!pendingOperations.length) return "";
    const oldest = new Date(Math.min(...pendingOperations.map((item) => item.createdAt))).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
    return `${pendingOperations.length} 条待同步，最早 ${oldest}`;
  }, [pendingOperations]);

  return {
    pendingOperations,
    pendingWrites: pendingOperations,
    pendingWriteCount,
    pendingWriteSummary,
    enqueuePendingWrites,
    enqueueTransactionUpdate,
    enqueueTransactionDelete,
    syncPendingWrites,
    syncingPendingWrites,
  };
}
