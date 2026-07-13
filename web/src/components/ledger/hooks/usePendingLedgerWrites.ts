import { useCallback, useEffect, useMemo, useState } from "react";
import { deleteIndexedCache, readIndexedCache, writeIndexedCache } from "@/lib/indexedLedgerCache";
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
import { apiEndpointLedgerScope, apiEndpointPreviousLedgerScope, apiEndpointSettingsChangeEvent, apiEndpointStorageKeyForLedgerScope, apiFetch } from "@/lib/apiEndpoints";

const pendingOperationsKey = "ledger_pending_operations";
const indexedPendingOperationsKey = "ledger_pending_operations:v2";
const legacyPendingWritesKey = "ledger_pending_writes";
const pendingOperationsMigrationKey = "ledger_pending_operations:migrated:v3";
const pendingWritesChangeEvent = "ledger-pending-writes-change";

const pendingOperationsWriteChains = new Map<string, Promise<boolean>>();

function pendingStorageKeysForScope(scope: string) {
  return {
    scope,
    local: apiEndpointStorageKeyForLedgerScope(pendingOperationsKey, scope),
    indexed: apiEndpointStorageKeyForLedgerScope(indexedPendingOperationsKey, scope),
  };
}

function pendingStorageKeys() {
  return pendingStorageKeysForScope(apiEndpointLedgerScope());
}

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
  const keys = pendingStorageKeys();
  return normalizePendingLedgerOperations(readJsonArray(keys.local));
}

export async function readPendingLedgerOperations(): Promise<PendingLedgerOperation[]> {
  const keys = pendingStorageKeys();
  await pendingOperationsWriteChains.get(keys.scope)?.catch(() => undefined);
  const local = readLocalPendingOperations();
  const indexed = normalizePendingLedgerOperations(await readIndexedCache<PendingLedgerOperation[]>(keys.indexed));
  const merged = mergeOperationLists(indexed.length ? indexed : local, local);
  const scopeMigration = await migratePreviousSameOriginPendingOperations(merged, keys.scope);
  const migration = await migrateLegacyPendingOperations(scopeMigration.operations, keys.scope);
  if (!scopeMigration.persisted && !migration.persisted && (migration.operations.length || local.length)) await writePendingOperations(migration.operations, false);
  return migration.operations;
}

async function migratePreviousSameOriginPendingOperations(current: PendingLedgerOperation[], scope: string) {
  const previousScope = apiEndpointPreviousLedgerScope();
  if (!previousScope || previousScope === scope) return { operations: current, persisted: false };
  const previousKeys = pendingStorageKeysForScope(previousScope);
  await pendingOperationsWriteChains.get(previousScope)?.catch(() => undefined);
  const previousLocal = normalizePendingLedgerOperations(readJsonArray(previousKeys.local));
  const previousIndexed = normalizePendingLedgerOperations(await readIndexedCache<PendingLedgerOperation[]>(previousKeys.indexed));
  const previous = mergeOperationLists(previousIndexed.length ? previousIndexed : previousLocal, previousLocal).map((operation) => ({
    ...operation,
    ledgerScope: scope,
  }));
  if (!previous.length) return { operations: current, persisted: false };
  const next = mergeOperationLists(current, previous);
  const persisted = await writePendingOperations(next, false);
  if (!persisted) return { operations: next, persisted: false };
  removeLocalStorageKey(previousKeys.local);
  await deleteIndexedCache(previousKeys.indexed);
  return { operations: next, persisted: true };
}

async function writePendingOperations(operations: PendingLedgerOperation[], notify = true) {
  if (typeof window === "undefined") return false;
  const keys = pendingStorageKeys();
  const write = async () => {
    let localStored = false;
    try {
      localStorage.setItem(keys.local, JSON.stringify(operations));
      localStored = true;
    } catch {
      // Keep the in-memory queue even if localStorage is unavailable.
    }
    const indexedStored = await writeIndexedCache(keys.indexed, operations);
    if (notify) window.dispatchEvent(new Event(pendingWritesChangeEvent));
    return localStored || indexedStored;
  };
  const chain = pendingOperationsWriteChains.get(keys.scope) ?? Promise.resolve(true);
  const next = chain.then(write, write);
  pendingOperationsWriteChains.set(keys.scope, next);
  return next;
}

async function migrateLegacyPendingOperations(current: PendingLedgerOperation[], scope: string) {
  if (typeof window === "undefined" || await pendingOperationsMigrationComplete()) return { operations: current, persisted: false };
  const legacyIndexed = normalizePendingLedgerOperations(await readIndexedCache<PendingLedgerOperation[]>(indexedPendingOperationsKey));
  const legacyLocal = normalizePendingLedgerOperations(readJsonArray(pendingOperationsKey));
  const legacyWrites = migrateLegacyPendingWrites(readJsonArray(legacyPendingWritesKey));
  const legacy = mergeOperationLists(legacyIndexed, [...legacyLocal, ...legacyWrites]).map((operation) => ({
    ...operation,
    ledgerScope: operation.ledgerScope ?? scope,
  }));
  const next = mergeOperationLists(current, legacy);
  if (!legacy.length) {
    await markPendingOperationsMigrationComplete();
    return { operations: current, persisted: false };
  }
  const persisted = await writePendingOperations(next, false);
  if (!persisted) return { operations: next, persisted: false };
  const marked = await markPendingOperationsMigrationComplete();
  const localCleaned = removeLegacyLocalPendingOperations();
  const indexedCleaned = await deleteIndexedCache(indexedPendingOperationsKey);
  if (!marked && !(localCleaned && indexedCleaned)) {
    return { operations: next, persisted: true };
  }
  return { operations: next, persisted: true };
}

async function pendingOperationsMigrationComplete() {
  try {
    if (localStorage.getItem(pendingOperationsMigrationKey) === "1") return true;
  } catch {
    // Fall through to the IndexedDB marker.
  }
  return Boolean(await readIndexedCache<boolean>(pendingOperationsMigrationKey));
}

async function markPendingOperationsMigrationComplete() {
  let localMarked = false;
  try {
    localStorage.setItem(pendingOperationsMigrationKey, "1");
    localMarked = localStorage.getItem(pendingOperationsMigrationKey) === "1";
  } catch {
    // IndexedDB provides the fallback migration marker.
  }
  const indexedMarked = await writeIndexedCache(pendingOperationsMigrationKey, true);
  return localMarked || indexedMarked;
}

function removeLegacyLocalPendingOperations() {
  try {
    localStorage.removeItem(legacyPendingWritesKey);
    localStorage.removeItem(pendingOperationsKey);
    return localStorage.getItem(legacyPendingWritesKey) == null && localStorage.getItem(pendingOperationsKey) == null;
  } catch {
    return false;
  }
}

function removeLocalStorageKey(key: string) {
  try {
    localStorage.removeItem(key);
    return localStorage.getItem(key) == null;
  } catch {
    return false;
  }
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
  return { id: makeId(), createdAt: now, updatedAt: now, kind: "append", entry, baseLedgerVersion, status: "pending", ledgerScope: apiEndpointLedgerScope() };
}

function updateOperation(source: Txn["source"], entry: ParsedTransaction, baseLedgerVersion?: LedgerVersion | null): PendingLedgerOperation {
  const now = Date.now();
  return { id: makeId(), createdAt: now, updatedAt: now, kind: "update-transaction", source, entry, baseLedgerVersion, status: "pending", ledgerScope: apiEndpointLedgerScope() };
}

function deleteOperation(source: Txn["source"], reason: string, baseLedgerVersion?: LedgerVersion | null): PendingLedgerOperation {
  const now = Date.now();
  return { id: makeId(), createdAt: now, updatedAt: now, kind: "delete-transaction", source, reason, baseLedgerVersion, status: "pending", ledgerScope: apiEndpointLedgerScope() };
}

export function isPendingLedgerConflict(message: string) {
  return message.includes("找不到原交易") || message.includes("交易来源");
}

export function discardPendingLedgerOperation(operations: PendingLedgerOperation[], id: string) {
  return operations.filter((operation) => operation.id !== id);
}

export function hasPendingOperationsToSync(operations: PendingLedgerOperation[]) {
  return operations.some((operation) => operation.status !== "conflict");
}

export async function syncOperation(operation: PendingLedgerOperation) {
  if (operation.ledgerScope && operation.ledgerScope !== apiEndpointLedgerScope()) {
    throw new Error("待同步操作属于另一个账本，已停止同步");
  }
  if (operation.kind === "append") {
    const res = await apiFetch("/api/ledger/append", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(operation.entry) }, { kind: "write" });
    const data = await readJson<{ error?: string }>(res);
    if (!res.ok) throw new Error(data.error || "同步失败");
    return;
  }

  if (operation.kind === "update-transaction") {
    const res = await apiFetch("/api/ledger/transactions", { method: "PUT", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ source: operation.source, entry: operation.entry }) }, { kind: "write" });
    const data = await readJson<{ error?: string }>(res);
    if (!res.ok) throw new Error(data.error || "修改同步失败");
    return;
  }

  const res = await apiFetch("/api/ledger/transactions", { method: "DELETE", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ source: operation.source, reason: operation.reason }) }, { kind: "write" });
  const data = await readJson<{ error?: string }>(res);
  if (!res.ok) throw new Error(data.error || "删除同步失败");
}

export function usePendingLedgerWrites({ load, showToast, ledgerVersion }: { load: (forceFresh?: boolean) => void | Promise<void>; showToast: (kind: "info" | "success" | "error", text: string) => void; ledgerVersion?: LedgerVersion | null }) {
  const [pendingOperations, setPendingOperations] = useState<PendingLedgerOperation[]>([]);
  const [syncingPendingWrites, setSyncingPendingWrites] = useState(false);

  useEffect(() => {
    const refresh = () => {
      void readPendingLedgerOperations().then(setPendingOperations);
    };
    refresh();
    window.addEventListener("storage", refresh);
    window.addEventListener(pendingWritesChangeEvent, refresh);
    window.addEventListener("online", refresh);
    window.addEventListener(apiEndpointSettingsChangeEvent, refresh);
    return () => {
      window.removeEventListener("storage", refresh);
      window.removeEventListener(pendingWritesChangeEvent, refresh);
      window.removeEventListener("online", refresh);
      window.removeEventListener(apiEndpointSettingsChangeEvent, refresh);
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

  const syncPendingWrites = useCallback(async ({ userInitiated = false }: { userInitiated?: boolean } = {}) => {
    const current = await readPendingLedgerOperations();
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
        const latest = await readPendingLedgerOperations();
        if (!latest.length) break;
        const syncIndex = latest.findIndex((operation) => operation.status !== "conflict");
        if (syncIndex < 0) break;
        const item = { ...latest[syncIndex], status: "syncing" as const, lastAttemptAt: Date.now(), updatedAt: Date.now() };
        persist(latest.map((operation, index) => index === syncIndex ? item : operation));
        try {
          await syncOperation(item);
          syncedCount += 1;
          persist((await readPendingLedgerOperations()).filter((operation) => operation.id !== item.id));
        } catch (error) {
          const message = error instanceof Error ? error.message : "同步中断";
          const remaining = await readPendingLedgerOperations();
          const failedIndex = remaining.findIndex((operation) => operation.id === item.id);
          const status = isPendingLedgerConflict(message) ? "conflict" : "error";
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
      if (userInitiated) haptic([6, 24, 10]);
      const remaining = await readPendingLedgerOperations();
      if (syncedCount > 0) {
        showToast("success", remaining.length ? `已同步 ${syncedCount} 条，仍有 ${remaining.length} 条待处理` : `已同步 ${syncedCount} 条待同步操作`);
        await load(true);
      } else {
        showToast(interruptedMessage ? "error" : "info", interruptedMessage || `仍有 ${remaining.length} 条待处理`);
      }
    } finally {
      setSyncingPendingWrites(false);
    }
  }, [load, persist, showToast, syncingPendingWrites]);

  const discardPendingOperation = useCallback((id: string) => {
    setPendingOperations((current) => {
      const next = discardPendingLedgerOperation(current, id);
      void writePendingOperations(next);
      return next;
    });
  }, []);

  useEffect(() => {
    const syncWhenOnline = () => {
      void syncPendingWrites();
    };
    window.addEventListener("online", syncWhenOnline);
    return () => window.removeEventListener("online", syncWhenOnline);
  }, [syncPendingWrites]);

  useEffect(() => {
    if (!hasPendingOperationsToSync(pendingOperations) || syncingPendingWrites) return;
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
    discardPendingOperation,
  };
}
