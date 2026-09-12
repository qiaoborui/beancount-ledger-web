import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { deleteIndexedCache, readIndexedCache, writeIndexedCache } from "@/lib/indexedLedgerCache";
import { readJson } from "@/lib/clientFetch";
import type { BalanceAssertion, ParsedTransaction } from "@/lib/schemas";
import { haptic } from "../haptics";
import {
  mergePendingOperation,
  createLedgerOperationId,
  migrateLegacyPendingWrites,
  normalizePendingLedgerOperations,
  type PendingEntry,
  type PendingLedgerOperation,
} from "../pendingLedgerOperations";
import type { LedgerVersion, Txn } from "../types";
import { apiEndpointLedgerScope, apiEndpointPreviousLedgerScope, apiEndpointSettingsChangeEvent, apiEndpointStorageKeyForLedgerScope, apiFetch } from "@/lib/apiEndpoints";
import i18n, { supportedLanguages } from "@/i18n";

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

const makeId = createLedgerOperationId;

type PendingQueueSnapshot = {
  version: 1;
  revision: number;
  writer: string;
  operations: PendingLedgerOperation[];
};

function readLocalValue(key: string): unknown {
  if (typeof window === "undefined") return null;
  try {
    const raw = localStorage.getItem(key);
    return raw ? JSON.parse(raw) : null;
  } catch {
    return null;
  }
}

function readJsonArray(key: string): unknown[] {
  const value = readLocalValue(key);
  return Array.isArray(value) ? value : [];
}

function decodeQueueSnapshot(value: unknown): PendingQueueSnapshot {
  const snapshot = value as Partial<PendingQueueSnapshot> | null;
  if (snapshot?.version === 1 && typeof snapshot.revision === "number" && Number.isSafeInteger(snapshot.revision)
    && snapshot.revision > 0 && typeof snapshot.writer === "string" && Array.isArray(snapshot.operations)) {
    return { ...snapshot, operations: normalizePendingLedgerOperations(snapshot.operations) } as PendingQueueSnapshot;
  }
  return { version: 1, revision: 0, writer: "", operations: normalizePendingLedgerOperations(value) };
}

async function readStoredQueue(scope: string): Promise<PendingQueueSnapshot> {
  const keys = pendingStorageKeysForScope(scope);
  const local = decodeQueueSnapshot(readLocalValue(keys.local));
  const indexed = decodeQueueSnapshot(await readIndexedCache<unknown>(keys.indexed));
  // Whole snapshots include deletions. A newer empty queue must win over an older
  // non-empty copy, including legacy arrays left behind by a failed store.
  if (local.revision || indexed.revision) {
    if (local.revision !== indexed.revision) return local.revision > indexed.revision ? local : indexed;
    return local.writer > indexed.writer ? local : indexed;
  }
  return { ...local, operations: mergeOperationLists(indexed.operations, local.operations) };
}

export async function readPendingLedgerOperations(): Promise<PendingLedgerOperation[]> {
  const keys = pendingStorageKeys();
  await pendingOperationsWriteChains.get(keys.scope)?.catch(() => undefined);
  const stored = await readStoredQueue(keys.scope);
  const scopeMigration = await migratePreviousSameOriginPendingOperations(stored.operations, keys.scope);
  const migration = await migrateLegacyPendingOperations(scopeMigration.operations, keys.scope);
  if (!stored.revision && !scopeMigration.persisted && !migration.persisted && migration.operations.length) await writePendingOperations(migration.operations, false, keys.scope);
  return migration.operations;
}

async function migratePreviousSameOriginPendingOperations(current: PendingLedgerOperation[], scope: string) {
  const previousScope = apiEndpointPreviousLedgerScope();
  if (!previousScope || previousScope === scope) return { operations: current, persisted: false };
  await pendingOperationsWriteChains.get(previousScope)?.catch(() => undefined);
  const previous = (await readStoredQueue(previousScope)).operations.map((operation) => ({
    ...operation,
    ledgerScope: scope,
  }));
  if (!previous.length) return { operations: current, persisted: false };
  const next = mergeOperationLists(current, previous);
  const persisted = await writePendingOperations(next, false);
  if (!persisted) return { operations: next, persisted: false };
  await writePendingOperations([], false, previousScope);
  return { operations: next, persisted: true };
}

async function writePendingOperations(operations: PendingLedgerOperation[], notify = true, scope = apiEndpointLedgerScope()) {
  if (typeof window === "undefined") return false;
  const keys = pendingStorageKeysForScope(scope);
  const write = async () => {
    const previous = await readStoredQueue(scope);
    const snapshot: PendingQueueSnapshot = {
      version: 1, revision: Math.max(Date.now(), previous.revision + 1), writer: makeId(), operations,
    };
    let localStored = false;
    try {
      localStorage.setItem(keys.local, JSON.stringify(snapshot));
      localStored = true;
    } catch {
      // Keep the in-memory queue even if localStorage is unavailable.
    }
    const indexedStored = await writeIndexedCache(keys.indexed, snapshot);
    if (notify && (localStored || indexedStored)) window.dispatchEvent(new Event(pendingWritesChangeEvent));
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

function appendOperation(entry: PendingEntry, baseLedgerVersion?: LedgerVersion | null, id = makeId()): PendingLedgerOperation {
  const now = Date.now();
  return { id, createdAt: now, updatedAt: now, kind: "append", entry, baseLedgerVersion, status: "pending", ledgerScope: apiEndpointLedgerScope() };
}

function updateOperation(source: Txn["source"], entry: ParsedTransaction, baseLedgerVersion?: LedgerVersion | null): PendingLedgerOperation {
  const now = Date.now();
  return { id: makeId(), createdAt: now, updatedAt: now, kind: "update-transaction", source, entry, baseLedgerVersion, status: "pending", ledgerScope: apiEndpointLedgerScope() };
}

function deleteOperation(source: Txn["source"], reason: string, baseLedgerVersion?: LedgerVersion | null): PendingLedgerOperation {
  const now = Date.now();
  return { id: makeId(), createdAt: now, updatedAt: now, kind: "delete-transaction", source, reason, baseLedgerVersion, status: "pending", ledgerScope: apiEndpointLedgerScope() };
}

function addTransactionTagsOperation(sources: Txn["source"][], tags: string[], baseLedgerVersion?: LedgerVersion | null): PendingLedgerOperation {
  const now = Date.now();
  return { id: makeId(), createdAt: now, updatedAt: now, kind: "add-transaction-tags", sources, tags, baseLedgerVersion, status: "pending", ledgerScope: apiEndpointLedgerScope() };
}

export function isPendingLedgerConflict(message: string) {
  return supportedLanguages.some((language) => (
    message.includes(i18n.t("pendingWrites.conflictOriginalMissing", { lng: language }))
    || message.includes(i18n.t("pendingWrites.conflictSourceNotUnique", { lng: language }))
  ));
}

export function discardPendingLedgerOperation(operations: PendingLedgerOperation[], id: string) {
  return operations.filter((operation) => operation.id !== id);
}

export function hasPendingOperationsToSync(operations: PendingLedgerOperation[]) {
  return operations.some((operation) => operation.status !== "conflict" && operation.status !== "paused");
}

class PendingWriteError extends Error {
  constructor(message: string, readonly status: number) { super(message); }
}

function canAttempt(operation: PendingLedgerOperation, manual: boolean) {
  return operation.status !== "conflict" && (manual || (operation.status !== "paused" && (operation.nextAttemptAt ?? 0) <= Date.now()));
}

async function readWriteResponse(response: Response, fallback: string) {
  try {
    const data = await readJson<{ error?: string }>(response);
    if (!response.ok) throw new PendingWriteError(data.error || fallback, response.status);
  } catch (error) {
    if (!response.ok && !(error instanceof PendingWriteError)) {
      throw new PendingWriteError(error instanceof Error ? error.message : fallback, response.status);
    }
    throw error;
  }
}

export async function syncOperation(operation: PendingLedgerOperation) {
  if (operation.ledgerScope && operation.ledgerScope !== apiEndpointLedgerScope()) {
    throw new Error(i18n.t("pendingWrites.differentLedger"));
  }
  if (operation.kind === "append") {
    const res = await apiFetch("/api/ledger/append", { method: "POST", headers: { "Content-Type": "application/json", "Idempotency-Key": operation.id }, body: JSON.stringify(operation.entry) }, { kind: "write" });
    await readWriteResponse(res, i18n.t("pendingWrites.syncFailed"));
    return;
  }

  if (operation.kind === "update-transaction") {
    const res = await apiFetch("/api/ledger/transactions", { method: "PUT", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ source: operation.source, entry: operation.entry }) }, { kind: "write" });
    await readWriteResponse(res, i18n.t("pendingWrites.updateSyncFailed"));
    return;
  }

  if (operation.kind === "add-transaction-tags") {
    const res = await apiFetch("/api/ledger/transactions/tags", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ sources: operation.sources, tags: operation.tags }) }, { kind: "write" });
    await readWriteResponse(res, i18n.t("pendingWrites.updateSyncFailed"));
    return;
  }

  const res = await apiFetch("/api/ledger/transactions", { method: "DELETE", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ source: operation.source, reason: operation.reason }) }, { kind: "write" });
  await readWriteResponse(res, i18n.t("pendingWrites.deleteSyncFailed"));
}

export function usePendingLedgerWrites({ load, showToast, ledgerVersion }: { load: (forceFresh?: boolean) => void | Promise<void>; showToast: (kind: "info" | "success" | "error", text: string) => void; ledgerVersion?: LedgerVersion | null }) {
  const [pendingOperations, setPendingOperations] = useState<PendingLedgerOperation[]>([]);
  const [syncingPendingWrites, setSyncingPendingWrites] = useState(false);
  const [storageUnavailable, setStorageUnavailable] = useState(false);
  const unsavedRef = useRef(new Map<string, PendingLedgerOperation[]>());
  const mutationChainRef = useRef<Promise<unknown>>(Promise.resolve());
  const syncingRef = useRef(false);

  const readQueue = useCallback(async (scope = apiEndpointLedgerScope()) => {
    if (scope !== apiEndpointLedgerScope()) return [];
    const stored = await readPendingLedgerOperations();
    return unsavedRef.current.get(scope) ?? stored;
  }, []);

  const refresh = useCallback(async () => {
    const scope = apiEndpointLedgerScope();
    const operations = await readQueue(scope);
    if (scope !== apiEndpointLedgerScope()) return;
    setPendingOperations(operations);
    setStorageUnavailable(unsavedRef.current.has(scope));
  }, [readQueue]);

  useEffect(() => {
    const onChange = () => { void refresh(); };
    onChange();
    window.addEventListener("storage", onChange);
    window.addEventListener(pendingWritesChangeEvent, onChange);
    window.addEventListener("online", onChange);
    window.addEventListener(apiEndpointSettingsChangeEvent, onChange);
    return () => {
      window.removeEventListener("storage", onChange);
      window.removeEventListener(pendingWritesChangeEvent, onChange);
      window.removeEventListener("online", onChange);
      window.removeEventListener(apiEndpointSettingsChangeEvent, onChange);
    };
  }, [refresh]);

  // Serialize read/modify/write as well as the disk writes. A failed snapshot stays
  // authoritative in memory until a later successful save or an explicit discard.
  const mutate = useCallback((change: (operations: PendingLedgerOperation[]) => PendingLedgerOperation[], scope = apiEndpointLedgerScope()) => {
    const run = async () => {
      if (scope !== apiEndpointLedgerScope()) return false;
      const current = await readQueue(scope);
      if (scope !== apiEndpointLedgerScope()) return false;
      const next = change(current);
      unsavedRef.current.set(scope, next);
      setPendingOperations(next);
      const saved = await writePendingOperations(next, true, scope);
      if (saved) unsavedRef.current.delete(scope);
      if (scope === apiEndpointLedgerScope()) {
        setStorageUnavailable(!saved);
        setPendingOperations(unsavedRef.current.get(scope) ?? next);
      }
      return saved;
    };
    const withLedgerLock = async (): Promise<boolean> => {
      if (typeof navigator !== "undefined" && navigator.locks) {
        return navigator.locks.request(`ledger-pending-writes:${scope}`, run);
      }
      return run();
    };
    const next = mutationChainRef.current.then(withLedgerLock, withLedgerLock);
    mutationChainRef.current = next;
    return next;
  }, [readQueue]);

  const enqueueOperation = useCallback(async (operation: PendingLedgerOperation) => {
    const saved = await mutate((current) => mergePendingOperation(current, operation));
    if (saved) haptic([8, 30, 8]);
    return saved;
  }, [mutate]);

  const enqueuePendingWrites = useCallback(async (entries: PendingEntry[], operationIds = entries.map(() => makeId())) => {
    if (!entries.length) return true;
    const operations = entries.map((entry, index) => appendOperation(entry, ledgerVersion, operationIds[index]));
    const saved = await mutate((current) => mergeOperationLists(current, operations));
    if (saved) haptic([8, 30, 8]);
    return saved;
  }, [ledgerVersion, mutate]);

  const enqueueTransactionUpdate = useCallback((source: Txn["source"], entry: ParsedTransaction) => (
    enqueueOperation(updateOperation(source, entry, ledgerVersion))
  ), [enqueueOperation, ledgerVersion]);
  const enqueueTransactionDelete = useCallback((source: Txn["source"], reason: string) => (
    enqueueOperation(deleteOperation(source, reason, ledgerVersion))
  ), [enqueueOperation, ledgerVersion]);
  const enqueueAddTransactionTags = useCallback((sources: Txn["source"][], tags: string[]) => (
    enqueueOperation(addTransactionTagsOperation(sources, tags, ledgerVersion))
  ), [enqueueOperation, ledgerVersion]);

  const syncPendingWrites = useCallback(async ({ userInitiated = false }: { userInitiated?: boolean } = {}) => {
    if (syncingRef.current) return;
    if (typeof navigator !== "undefined" && !navigator.onLine) {
      if (userInitiated) showToast("info", i18n.t("pendingWrites.stillOffline", { count: pendingOperations.length }));
      return;
    }
    const scope = apiEndpointLedgerScope();
    syncingRef.current = true;
    setSyncingPendingWrites(true);
    let syncedCount = 0;
    let interruptedMessage = "";
    const attempted = new Set<string>();
    try {
      if (unsavedRef.current.has(scope)) {
        if (!userInitiated) return;
        if (!await mutate((current) => current, scope)) {
          showToast("error", i18n.t("pendingWrites.storageFailed"));
          return;
        }
      }
      while (scope === apiEndpointLedgerScope()) {
        await mutationChainRef.current;
        const latest = await readQueue(scope);
        const item = latest.find((operation) => !attempted.has(operation.id) && canAttempt(operation, userInitiated));
        if (!item || scope !== apiEndpointLedgerScope()) break;
        attempted.add(item.id);
        if (!await mutate((current) => current.map((operation) => operation.id === item.id
          ? { ...operation, status: "syncing", lastAttemptAt: Date.now(), updatedAt: Date.now() } : operation), scope)) break;
        if (scope !== apiEndpointLedgerScope()) break;
        try {
          await syncOperation(item);
          syncedCount += 1;
          if (!await mutate((current) => current.filter((operation) => operation.id !== item.id), scope)) break;
        } catch (error) {
          const message = error instanceof Error ? error.message : i18n.t("pendingWrites.syncInterrupted");
          const permanent = error instanceof PendingWriteError && error.status >= 400 && error.status < 500 && error.status !== 408 && error.status !== 429;
          const status = isPendingLedgerConflict(message) ? "conflict" : permanent ? "paused" : "error";
          interruptedMessage = message;
          const saved = await mutate((current) => current.map((operation) => {
            if (operation.id !== item.id) return operation;
            const retryCount = (operation.retryCount ?? 0) + 1;
            return {
              ...operation, status, lastError: message, retryCount, lastAttemptAt: Date.now(), updatedAt: Date.now(),
              nextAttemptAt: status === "error" ? Date.now() + Math.min(60_000, 1_000 * 2 ** Math.min(retryCount - 1, 6)) : undefined,
            };
          }), scope);
          if (!saved) break;
        }
      }
      if (scope !== apiEndpointLedgerScope()) return;
      const remaining = await readQueue(scope);
      if (syncedCount > 0) {
        if (userInitiated) haptic([6, 24, 10]);
        showToast("success", remaining.length ? i18n.t("pendingWrites.syncedPartial", { synced: syncedCount, remaining: remaining.length }) : i18n.t("pendingWrites.syncedAll", { count: syncedCount }));
        await load(true);
      } else if (userInitiated) {
        showToast(interruptedMessage ? "error" : "info", interruptedMessage || i18n.t("pendingWrites.remainingPending", { count: remaining.length }));
      }
    } finally {
      syncingRef.current = false;
      setSyncingPendingWrites(false);
    }
  }, [load, mutate, pendingOperations.length, readQueue, showToast]);

  const discardPendingOperation = useCallback(async (id: string) => {
    if (!await mutate((current) => discardPendingLedgerOperation(current, id))) showToast("error", i18n.t("pendingWrites.storageFailed"));
  }, [mutate, showToast]);

  useEffect(() => {
    const syncWhenOnline = () => { void syncPendingWrites(); };
    window.addEventListener("online", syncWhenOnline);
    return () => window.removeEventListener("online", syncWhenOnline);
  }, [syncPendingWrites]);

  useEffect(() => {
    if (storageUnavailable || syncingPendingWrites || !hasPendingOperationsToSync(pendingOperations)) return;
    if (typeof navigator !== "undefined" && !navigator.onLine) return;
    const eligible = pendingOperations.filter((operation) => operation.status !== "conflict" && operation.status !== "paused");
    const delay = Math.min(...eligible.map((operation) => operation.nextAttemptAt ? Math.max(0, operation.nextAttemptAt - Date.now()) : 300));
    const timer = window.setTimeout(() => { void syncPendingWrites(); }, delay);
    return () => window.clearTimeout(timer);
  }, [pendingOperations, storageUnavailable, syncPendingWrites, syncingPendingWrites]);

  const pendingWriteCount = pendingOperations.length;
  const pendingWriteSummary = useMemo(() => {
    if (!pendingOperations.length) return "";
    if (storageUnavailable) return i18n.t("pendingWrites.storageFailed");
    const oldest = new Date(Math.min(...pendingOperations.map((item) => item.createdAt))).toLocaleTimeString(i18n.language, { hour: "2-digit", minute: "2-digit" });
    const conflictCount = pendingOperations.filter((item) => item.status === "conflict").length;
    if (conflictCount) return i18n.t("pendingWrites.conflictSummary", { conflict: conflictCount, total: pendingOperations.length });
    const pausedCount = pendingOperations.filter((item) => item.status === "paused").length;
    if (pausedCount) return i18n.t("pendingWrites.pausedSummary", { count: pausedCount });
    const errorCount = pendingOperations.filter((item) => item.status === "error").length;
    if (errorCount) return i18n.t("pendingWrites.errorSummary", { error: errorCount, total: pendingOperations.length });
    return i18n.t("pendingWrites.pendingSummary", { count: pendingOperations.length, oldest });
  }, [pendingOperations, storageUnavailable]);

  return {
    pendingOperations, pendingWrites: pendingOperations, pendingWriteCount, pendingWriteSummary,
    enqueuePendingWrites, enqueueTransactionUpdate, enqueueTransactionDelete, enqueueAddTransactionTags,
    syncPendingWrites, syncingPendingWrites, discardPendingOperation,
  };
}
