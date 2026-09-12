import { afterEach, expect, it, vi } from "vitest";

afterEach(() => { vi.unstubAllGlobals(); vi.resetModules(); });

it("reports a transaction abort after a successful put as a failed save", async () => {
  const request: { result: string; onsuccess?: () => void } = { result: "queue" };
  const tx: { error: Error; objectStore: () => unknown; onabort?: () => void } = {
    error: new Error("quota exhausted at commit"),
    objectStore: () => ({ put: () => {
      queueMicrotask(() => { request.onsuccess?.(); queueMicrotask(() => tx.onabort?.()); });
      return request;
    } }),
  };
  const opening: { result: unknown; onsuccess?: () => void } = { result: { transaction: () => tx } };
  vi.stubGlobal("window", { indexedDB: { open: () => {
    queueMicrotask(() => opening.onsuccess?.());
    return opening;
  } } });
  const { writeIndexedCache } = await import("./indexedLedgerCache");
  expect(await writeIndexedCache("queue", [{ id: "entry" }])).toBe(false);
});
