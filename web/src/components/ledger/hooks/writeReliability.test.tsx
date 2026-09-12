// @vitest-environment jsdom
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { EnqueuePendingWrites } from "../pendingLedgerOperations";
import type { ParsedTransaction } from "@/lib/schemas";

const disk = vi.hoisted(() => ({ values: new Map<string, unknown>(), fail: false }));
vi.mock("@/lib/indexedLedgerCache", () => ({
  readIndexedCache: vi.fn(async (key: string) => disk.values.get(key) ?? null),
  writeIndexedCache: vi.fn(async (key: string, value: unknown) => {
    if (disk.fail) return false;
    disk.values.set(key, structuredClone(value));
    return true;
  }),
  deleteIndexedCache: vi.fn(async (key: string) => disk.values.delete(key)),
}));
import { readPendingLedgerOperations, usePendingLedgerWrites } from "./usePendingLedgerWrites";
import { useEntryActions } from "./useEntryActions";

const entry: ParsedTransaction = {
  kind: "transaction", date: "2026-09-12", payee: "Cafe", narration: "Lunch", metadata: {}, tags: [],
  confidence: 1, needsReview: false, questions: [],
  postings: [{ account: "Expenses:Food", amount: "12", currency: "CNY" }, { account: "Assets:Cash", amount: "-12", currency: "CNY" }],
};
const roots: Root[] = [];
async function mount<T>(hook: () => T) {
  let current: T;
  function Host() { current = hook(); return null; }
  const root = createRoot(document.createElement("div"));
  roots.push(root);
  await act(async () => { root.render(<Host />); });
  return () => current!;
}
async function advance(ms: number) { await act(async () => { await vi.advanceTimersByTimeAsync(ms); }); }
const load = vi.fn();
const showToast = vi.fn();

beforeEach(() => {
  Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });
  vi.useFakeTimers();
  localStorage.clear(); disk.values.clear(); disk.fail = false;
  vi.spyOn(navigator, "onLine", "get").mockReturnValue(true);
  vi.stubGlobal("fetch", vi.fn(async () => new Response(JSON.stringify({ ok: true }), { status: 200 })));
  load.mockReset(); showToast.mockReset();
});
afterEach(async () => {
  await act(async () => { roots.splice(0).forEach((root) => root.unmount()); });
  vi.restoreAllMocks(); vi.unstubAllGlobals(); vi.useRealTimers();
});

describe("pending write lifecycle", () => {
  it("serializes two tabs' append read/modify/write through a shared Web Lock", async () => {
    const locks = new Map<string, Promise<unknown>>();
    const request = vi.fn((name: string, callback: () => Promise<unknown>) => {
      const next = (locks.get(name) ?? Promise.resolve()).then(callback);
      locks.set(name, next.catch(() => undefined));
      return next;
    });
    vi.stubGlobal("navigator", { onLine: false, locks: { request } });
    const first = await mount(() => usePendingLedgerWrites({ load, showToast }));
    const second = await mount(() => usePendingLedgerWrites({ load, showToast }));
    await act(async () => {
      await Promise.all([
        first().enqueuePendingWrites([entry], ["tab-one"]),
        second().enqueuePendingWrites([{ ...entry, payee: "Bakery" }], ["tab-two"]),
      ]);
    });
    const stored = await readPendingLedgerOperations();
    expect(stored.map((operation) => operation.id).sort()).toEqual(["tab-one", "tab-two"]);
    expect(first().pendingOperations).toHaveLength(2);
    expect(second().pendingOperations).toHaveLength(2);
    expect(request).toHaveBeenCalledTimes(2);
    expect(request.mock.calls[0][0]).toBe(request.mock.calls[1][0]);
  });

  it.each(["localStorage", "IndexedDB"])("keeps discarded writes deleted when %s is stale", async (failedStore) => {
    vi.spyOn(navigator, "onLine", "get").mockReturnValue(false);
    const queue = await mount(() => usePendingLedgerWrites({ load, showToast }));
    await act(async () => { await queue().enqueuePendingWrites([entry]); });
    const id = queue().pendingOperations[0].id;
    if (failedStore === "IndexedDB") disk.fail = true;
    else vi.spyOn(Storage.prototype, "setItem").mockImplementation(() => { throw new DOMException("quota", "QuotaExceededError"); });
    await act(async () => { await queue().discardPendingOperation(id); });
    await act(async () => { roots.pop()!.unmount(); });
    const restored = await mount(() => usePendingLedgerWrites({ load, showToast }));
    expect(restored().pendingOperations).toHaveLength(0);
    vi.spyOn(navigator, "onLine", "get").mockReturnValue(true);
    await act(async () => { await restored().syncPendingWrites({ userInitiated: true }); });
    expect(fetch).not.toHaveBeenCalled();
  });

  it.each(["localStorage", "IndexedDB"])("keeps the latest edit when %s is stale", async (failedStore) => {
    vi.spyOn(navigator, "onLine", "get").mockReturnValue(false);
    const queue = await mount(() => usePendingLedgerWrites({ load, showToast }));
    const source = { file: "transactions/2026/09.bean", line: 12, hash: "original" };
    await act(async () => { await queue().enqueueTransactionUpdate(source, entry); });
    if (failedStore === "IndexedDB") disk.fail = true;
    else vi.spyOn(Storage.prototype, "setItem").mockImplementation(() => { throw new DOMException("quota", "QuotaExceededError"); });
    await act(async () => { await queue().enqueueTransactionUpdate(source, { ...entry, narration: "Corrected lunch" }); });
    await act(async () => { roots.pop()!.unmount(); });
    const restored = await mount(() => usePendingLedgerWrites({ load, showToast }));
    expect(restored().pendingOperations).toHaveLength(1);
    vi.spyOn(navigator, "onLine", "get").mockReturnValue(true);
    await act(async () => { await restored().syncPendingWrites({ userInitiated: true }); });
    expect(fetch).toHaveBeenCalledTimes(1);
    expect(JSON.parse(String(vi.mocked(fetch).mock.calls[0][1]?.body)).entry.narration).toBe("Corrected lunch");
  });

  it("keeps a non-JSON authentication failure paused after remount", async () => {
    vi.mocked(fetch).mockResolvedValue(new Response("Session expired", { status: 401 }));
    const first = await mount(() => usePendingLedgerWrites({ load, showToast }));
    await act(async () => { await first().enqueuePendingWrites([entry]); });
    await advance(300);
    await act(async () => { roots.pop()!.unmount(); });
    const restored = await mount(() => usePendingLedgerWrites({ load, showToast }));
    await advance(60_000);
    expect(fetch).toHaveBeenCalledTimes(1);
    vi.mocked(fetch).mockImplementation(async () => new Response('{"ok":true}', { status: 200 }));
    await act(async () => { await restored().syncPendingWrites({ userInitiated: true }); });
    expect(restored().pendingOperations).toHaveLength(0);
    expect(fetch).toHaveBeenCalledTimes(2);
  });
  it.each([400, 401, 403, 409, 423])("pauses HTTP %i failures until a manual retry", async (status) => {
    vi.mocked(fetch).mockImplementation(() => new Promise((resolve) => setTimeout(() => resolve(new Response(JSON.stringify({ error: "rejected" }), { status })), 1)));
    const queue = await mount(() => usePendingLedgerWrites({ load, showToast }));
    await act(async () => { await queue().enqueuePendingWrites([entry]); });
    await advance(300);
    await advance(1);
    expect(fetch).toHaveBeenCalledTimes(1);
    await advance(60_000);
    expect(fetch).toHaveBeenCalledTimes(1);
    await act(async () => { void queue().syncPendingWrites({ userInitiated: true }); });
    await advance(1);
    expect(fetch).toHaveBeenCalledTimes(2);
  });

  it("backs off transient errors and preserves the operation ID through retry", async () => {
    vi.mocked(fetch).mockImplementation(() => new Promise((resolve) => setTimeout(() => resolve(new Response(JSON.stringify({ error: "unavailable" }), { status: 503 })), 1)));
    const queue = await mount(() => usePendingLedgerWrites({ load, showToast }));
    await act(async () => { await queue().enqueuePendingWrites([entry]); });
    await advance(300);
    await advance(1);
    expect(fetch).toHaveBeenCalledTimes(1);
    await advance(999);
    expect(fetch).toHaveBeenCalledTimes(1);
    await advance(1);
    expect(fetch).toHaveBeenCalledTimes(2);
    await advance(1);
    await advance(1_999);
    expect(fetch).toHaveBeenCalledTimes(2);
    await advance(1);
    expect(fetch).toHaveBeenCalledTimes(3);
    const keys = vi.mocked(fetch).mock.calls.map(([, init]) => new Headers(init?.headers).get("Idempotency-Key"));
    expect(keys[0]).toBeTruthy(); expect(new Set(keys).size).toBe(1);
  });

  it("reports failed persistence and retains the operation in memory", async () => {
    vi.spyOn(navigator, "onLine", "get").mockReturnValue(false);
    const queue = await mount(() => usePendingLedgerWrites({ load, showToast }));
    disk.fail = true;
    vi.spyOn(Storage.prototype, "setItem").mockImplementation(() => { throw new DOMException("quota", "QuotaExceededError"); });
    let saved: unknown;
    await act(async () => { saved = await queue().enqueuePendingWrites([entry]); });
    expect(saved).toBe(false);
    expect(queue().pendingOperations).toHaveLength(1);
    await act(async () => { window.dispatchEvent(new Event("storage")); });
    expect(queue().pendingOperations).toHaveLength(1);
    vi.mocked(Storage.prototype.setItem).mockRestore(); disk.fail = false;
    vi.spyOn(navigator, "onLine", "get").mockReturnValue(true);
    await act(async () => { await queue().syncPendingWrites({ userInitiated: true }); });
    expect(queue().pendingOperations).toHaveLength(0);
    expect(fetch).toHaveBeenCalledTimes(1);
  });
});

describe("entry submission lifecycle", () => {
  async function prepare(enqueuePendingWrites: EnqueuePendingWrites) {
    const actions = await mount(() => useEntryActions({ load, showToast, enqueuePendingWrites }));
    await act(async () => { actions().setManual((current) => ({ ...current, payee: "Cafe", amount: "12" })); actions().setEntryOpen(true); });
    await act(async () => { actions().previewManualEntry(); });
    return actions;
  }
  it("keeps the preview and editor open when offline persistence fails", async () => {
    vi.spyOn(navigator, "onLine", "get").mockReturnValue(false);
    const actions = await prepare(vi.fn(async () => false));
    await act(async () => { await actions().appendPreviews(); });
    expect(actions().previews).toHaveLength(1);
    expect(actions().entryOpen).toBe(true);
    expect(actions().manual.payee).toBe("Cafe");
  });
  it("reuses batch operation IDs after the response is lost", async () => {
    vi.mocked(fetch).mockRejectedValue(new TypeError("connection lost"));
    const enqueue = vi.fn<EnqueuePendingWrites>(async () => true);
    const actions = await prepare(enqueue);
    await act(async () => { await actions().appendPreviews(); });
    const body = JSON.parse(String(vi.mocked(fetch).mock.calls[0][1]?.body));
    expect(body.operationIds).toHaveLength(1);
    expect(enqueue.mock.calls[0][1]).toEqual(body.operationIds);
  });

  it("retries the same draft with the same IDs when response loss and storage failure coincide", async () => {
    vi.mocked(fetch).mockRejectedValue(new TypeError("connection lost"));
    const enqueue = vi.fn<EnqueuePendingWrites>(async () => false);
    const actions = await prepare(enqueue);
    await act(async () => { await actions().appendPreviews(); });
    expect(actions().previews).toHaveLength(1);
    enqueue.mockResolvedValue(true);
    await act(async () => { await actions().appendPreviews(); });
    const requests = vi.mocked(fetch).mock.calls.map(([, init]) => JSON.parse(String(init?.body)));
    expect(requests[0].operationIds).toEqual(requests[1].operationIds);
    expect(enqueue.mock.calls[0][1]).toEqual(enqueue.mock.calls[1][1]);
    expect(actions().previews).toHaveLength(0);
  });
});
