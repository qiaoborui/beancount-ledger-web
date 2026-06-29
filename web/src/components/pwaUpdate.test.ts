import { describe, expect, it } from "vitest";
import { shouldShowServiceWorkerUpdate } from "./pwaUpdate";

describe("shouldShowServiceWorkerUpdate", () => {
  const worker = {} as ServiceWorker;
  const controller = {} as ServiceWorker;

  it("requires a waiting worker and an existing controller", () => {
    expect(shouldShowServiceWorkerUpdate(null, controller, null)).toBe(false);
    expect(shouldShowServiceWorkerUpdate(worker, null, null)).toBe(false);
    expect(shouldShowServiceWorkerUpdate(worker, controller, null)).toBe(true);
  });

  it("does not keep showing a waiting worker that the user already activated", () => {
    expect(shouldShowServiceWorkerUpdate(worker, controller, worker)).toBe(false);
    expect(shouldShowServiceWorkerUpdate({} as ServiceWorker, controller, worker)).toBe(true);
  });
});
