import { useCallback, useEffect, useMemo, useState } from "react";
import { readIndexedCache, writeIndexedCache } from "@/lib/indexedLedgerCache";
import { readJson } from "@/lib/clientFetch";
import type { BalanceAssertion, ParsedTransaction } from "@/lib/schemas";
import { haptic } from "../haptics";
import {
  mergePendingOperation,
  migrateLegacyPendingWrites,
  normalizePendingLedgerOperations,
  type PendingEntry,
  type PendingLedgerOperation,
} from "../pendingLedgerOperations";
import type { LedgerVersion, Txn } from "../types";

const pendingOperationsKey = "ledger_pending_operations";
const indexedPendingOperationsKey = "ledger_pending_operations:v2";
const legacyPendingWritesKey = "ledger_pending_writes";
const pendingWritesChangeEvent = "ledger-pending-writes-change";

let pendingOperationsWriteChain: Promise<void> = Promise.resolve();

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

function readLocalPendingOperations(): PendingLedgerOperation[] {
  if (typeof window === "undefined") return [];
  const operations = normalizePendingLedgerOperations(readJsonArray(pendingOperationsKey));
  const legacy = migrateLegacyPendingWrites(readJsonArray(legacyPendingWritesKey));
  if (legacy.length) {
    const next = [...legacy, ...operations];
    void writePendingOperations(next);
    try {
      localStorage.removeItem(legacyPendingWritesKey);
    } catch {
      // The migrated operations have already been mirrored in memory.
    }
    return next;
  }
  return operations;
}

async function readPendingOperations(): Promise<PendingLedgerOperation[]> {
  await pendingOperationsWriteChain.catch(() => undefined);
  const local = readLocalPendingOperations();
  const indexed = normalizePendingLedgerOperations(await readIndexedCache<PendingLedgerOperation[]>(indexedPendingOperationsKey));
  const merged = mergeOperationLists(indexed.length ? indexed : local, local);
  if (merged.length || local.length) await writePendingOperations(merged, false);
  return merged;
}

async function writePendingOperations(operations: PendingLedgerOperation[], notify = true) {
  if (typeof window === "undefined") return Promise.resolve();
  const write = async () => {
    try {
      localStorage.setItem(pendingOperationsKey, JSON.stringify(operations));
    } catch {
      // Keep the in-memory queue even if localStorage is unavailable.
    }
    await writeIndexedCache(indexedPendingOperationsKey, operations);
    if (notify) window.dispatchEvent(new Event(pendingWritesChangeEvent));
  };
  pendingOperationsWriteChain = pendingOperationsWriteChain.then(write, write);
  return pendingOperationsWriteChain;
}

function mergeOperationLists(primary: PendingLedgerOperation[], secondary: PendingLedgerOperation[]) {
  const seen = new Set<string>();
  const merged: PendingLedgerOperation[] = [];
  for (const operation of [...primary, ...secondary]) {
    if (seen.has(operation.id)) continue;
    seen.add(operation.id);
    merged.push(operation);
  }
  return merged.sort((a, b) => a.createdAt - b.createdAt);
}

function appendOperation(entry: PendingEntry, baseLedgerVersion?: LedgerVersion | null): PendingLedgerOperation {
  const now = Date.now();
  return { id: makeId(), createdAt: now, updatedAt: now, kind: "append", entry, baseLedgerVersion, status: "pending" };
}

function updateOperation(source: Txn["source"], entry: ParsedTransaction, baseLedgerVersion?: LedgerVersion | null): PendingLedgerOperation {
  const now = Date.now();
  return { id: makeId(), createdAt: now, updatedAt: now, kind: "update-transaction", source, entry, baseLedgerVersion, status: "pending" };
}

function deleteOperation(source: Txn["source"], reason: string, baseLedgerVersion?: LedgerVersion | null): PendingLedgerOperation {
  const now = Date.now();
  return { id: makeId(), createdAt: now, updatedAt: now, kind: "delete-transaction", source, reason, baseLedgerVersion, status: "pending" };
}

function ledgerVersionChanged(base?: LedgerVersion | null, current?: LedgerVersion | null) {
  if (!base?.version || !current?.version) return false;
  return base.version !== current.version;
}

async function fetchCurrentLedgerVersion(): Promise<LedgerVersion | null> {
  const res = await fetch("/api/ledger/version");
  const data = await readJson<LedgerVersion & { error?: string }>(res);
  if (!res.ok) throw new Error(data.error || "读取账本版本失败");
  return data;
}

async function assertTransactionBaseVersion(operation: PendingLedgerOperation) {
  if (operation.kind === "append" || !operation.baseLedgerVersion?.version) return;
  const current = await fetchCurrentLedgerVersion();
  if (ledgerVersionChanged(operation.baseLedgerVersion, current)) {
    throw new Error("账本已更新，这条本地修改需要确认后再同步");
  }
}

export async function syncOperation(operation: PendingLedgerOperation) {
  await assertTransactionBaseVersion(operation);
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

export function usePendingLedgerWrites({ load, refreshGitStatus, showToast, ledgerVersion }: { load: (forceFresh?: boolean) => void | Promise<void>; refreshGitStatus: () => void | Promise<void>; showToast: (kind: "info" | "success" | "error", text: string) => void; ledgerVersion?: LedgerVersion | null }) {
  const [pendingOperations, setPendingOperations] = useState<PendingLedgerOperation[]>([]);
  const [syncingPendingWrites, setSyncingPendingWrites] = useState(false);

  useEffect(() => {
    const refresh = () => {
      void readPendingOperations().then(setPendingOperations);
    };
    refresh();
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
    void writePendingOperations(next);
  }, []);

  const enqueueOperation = useCallback((operation: PendingLedgerOperation) => {
    setPendingOperations((current) => {
      const next = mergePendingOperation(current, operation);
      void writePendingOperations(next);
      return next;
    });
    haptic([8, 30, 8]);
  }, []);

  const enqueuePendingWrites = useCallback((entries: PendingEntry[]) => {
    if (!entries.length) return;
    setPendingOperations((current) => {
      const next = [...current, ...entries.map((entry) => appendOperation(entry, ledgerVersion))];
      void writePendingOperations(next);
      return next;
    });
    haptic([8, 30, 8]);
  }, [ledgerVersion]);

  const enqueueTransactionUpdate = useCallback((source: Txn["source"], entry: ParsedTransaction) => {
    enqueueOperation(updateOperation(source, entry, ledgerVersion));
  }, [enqueueOperation, ledgerVersion]);

  const enqueueTransactionDelete = useCallback((source: Txn["source"], reason: string) => {
    enqueueOperation(deleteOperation(source, reason, ledgerVersion));
  }, [enqueueOperation, ledgerVersion]);

  const syncPendingWrites = useCallback(async () => {
    const current = await readPendingOperations();
    if (!current.length || syncingPendingWrites) return;
    if (typeof navigator !== "undefined" && !navigator.onLine) {
      showToast("info", `仍处于离线状态，${current.length} 条待同步操作已保留`);
      return;
    }

    setSyncingPendingWrites(true);
    showToast("info", `正在同步 ${current.length} 条待同步操作`);
    let syncedCount = 0;
    let interruptedMessage = "";
    try {
      while (true) {
        const latest = await readPendingOperations();
        if (!latest.length) break;
        const syncIndex = latest.findIndex((operation) => operation.status !== "conflict");
        if (syncIndex < 0) break;
        const item = { ...latest[syncIndex], status: "syncing" as const, lastAttemptAt: Date.now(), updatedAt: Date.now() };
        persist(latest.map((operation, index) => index === syncIndex ? item : operation));
        try {
          await syncOperation(item);
          syncedCount += 1;
          persist((await readPendingOperations()).filter((operation) => operation.id !== item.id));
        } catch (error) {
          const message = error instanceof Error ? error.message : "同步中断";
          const remaining = await readPendingOperations();
          const failedIndex = remaining.findIndex((operation) => operation.id === item.id);
          const status = message.includes("需要确认") ? "conflict" : "error";
          if (failedIndex >= 0) {
            const failed = remaining[failedIndex];
            persist(remaining.map((operation, index) => index === failedIndex ? {
              ...failed,
              status,
              lastError: message,
              retryCount: (failed.retryCount ?? 0) + 1,
              lastAttemptAt: Date.now(),
              updatedAt: Date.now(),
            } : operation));
          }
          if (status === "conflict") continue;
          interruptedMessage = message;
          break;
        }
      }
      haptic([6, 24, 10]);
      const remaining = await readPendingOperations();
      if (syncedCount > 0) {
        showToast("success", remaining.length ? `已同步 ${syncedCount} 条，仍有 ${remaining.length} 条待处理` : `已同步 ${syncedCount} 条待同步操作`);
        await load(true);
        await refreshGitStatus();
      } else {
        showToast(interruptedMessage ? "error" : "info", interruptedMessage || `仍有 ${remaining.length} 条待处理`);
      }
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
    const conflictCount = pendingOperations.filter((item) => item.status === "conflict").length;
    if (conflictCount) return `${conflictCount} 条需确认，${pendingOperations.length} 条待同步`;
    const errorCount = pendingOperations.filter((item) => item.status === "error").length;
    if (errorCount) return `${errorCount} 条同步失败，${pendingOperations.length} 条待处理`;
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
