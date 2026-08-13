import { describe, expect, it } from "vitest";
import { loadInstanceSetupState } from "./instanceSetupState";

describe("loadInstanceSetupState", () => {
  it("keeps a failed setup status request unavailable instead of assuming ready", async () => {
    const state = await loadInstanceSetupState(async () => { throw new Error("database connection refused"); });

    expect(state).toEqual({ kind: "unavailable", error: "database connection refused" });
  });

  it("preserves setup-required and indexer failure phases", async () => {
    const required = await loadInstanceSetupState(async () => ({ setupRequired: true, readiness: { state: "setup_required" } }));
    const degraded = await loadInstanceSetupState(async () => ({
      setupRequired: false,
      readiness: { state: "indexer_error", error: "bean-check failed" },
    }));

    expect(required.kind).toBe("required");
    expect(degraded.kind).toBe("ready");
    if (degraded.kind === "ready") expect(degraded.status.readiness?.state).toBe("indexer_error");
  });

  it("rejects an incomplete response instead of treating it as configured", async () => {
    const state = await loadInstanceSetupState(async () => ({ setupRequired: undefined } as never));

    expect(state.kind).toBe("unavailable");
  });
});
