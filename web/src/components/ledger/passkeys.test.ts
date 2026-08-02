import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { resetApiEndpointRuntimeState, writeApiEndpointSettings, type ApiEndpointSettings } from "@/lib/apiEndpoints";
import { deletePasskeyCredential, listPasskeyCredentials, passkeyBackupPresentation } from "./passkeys";

const endpointSettings: ApiEndpointSettings = {
  activeId: "primary",
  autoSelect: false,
  clusterId: "ledger",
  apiVersion: 1,
  endpoints: [
    { id: "same-origin", url: "", enabled: true, clusterId: "ledger", apiVersion: 1 },
    { id: "primary", url: "https://primary.example.com", enabled: true, clusterId: "ledger", apiVersion: 1, capabilities: ["passkey-management-v1"] },
    { id: "backup", url: "https://backup.example.com", enabled: true, clusterId: "ledger", apiVersion: 1, capabilities: ["passkey-management-v1"] },
  ],
};

beforeEach(() => {
  const values = new Map<string, string>();
  const localStorage = {
    getItem: (key: string) => values.get(key) ?? null,
    setItem: (key: string, value: string) => values.set(key, value),
    removeItem: (key: string) => values.delete(key),
    clear: () => values.clear(),
    key: (index: number) => Array.from(values.keys())[index] ?? null,
    get length() { return values.size; },
  } satisfies Storage;
  vi.stubGlobal("window", { localStorage, location: { origin: "https://app.example.com" }, fetch: vi.fn(), setTimeout, clearTimeout, dispatchEvent: vi.fn() });
  resetApiEndpointRuntimeState();
});

afterEach(() => {
  resetApiEndpointRuntimeState();
  vi.unstubAllGlobals();
});

describe("passkeyBackupPresentation", () => {
  it("distinguishes synced, sync-capable, device-bound, and legacy credentials", () => {
    expect(passkeyBackupPresentation({ id: "1", name: "Synced", backupEligible: true, backupState: true }).label).toBe("已同步");
    expect(passkeyBackupPresentation({ id: "2", name: "Capable", backupEligible: true, backupState: false }).label).toBe("可同步");
    expect(passkeyBackupPresentation({ id: "3", name: "Bound", backupEligible: false, backupState: false }).label).toBe("设备绑定");
    expect(passkeyBackupPresentation({ id: "4", name: "Legacy" }).label).toBe("状态未知");
  });
});

describe("Passkey management endpoint pinning", () => {
  it("keeps deletion on the endpoint that supplied the credential list", async () => {
    writeApiEndpointSettings(endpointSettings);
    const fetchMock = vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input);
      if (url.endsWith("/api/passkey/credentials")) {
        return new Response(JSON.stringify({ credentials: [{ id: "credential-1", name: "MacBook" }] }), { status: 200, headers: { "Content-Type": "application/json" } });
      }
      return new Response(JSON.stringify({ ok: true, remaining: 0 }), { status: 200, headers: { "Content-Type": "application/json" } });
    });
    window.fetch = fetchMock as typeof fetch;

    const listed = await listPasskeyCredentials();
    writeApiEndpointSettings({ ...endpointSettings, activeId: "backup" });
    await deletePasskeyCredential(listed.endpoint, "credential-1", "main-secret");

    expect(listed.endpoint.id).toBe("primary");
    expect(fetchMock).toHaveBeenNthCalledWith(1, "https://primary.example.com/api/passkey/credentials", expect.anything());
    expect(fetchMock).toHaveBeenNthCalledWith(2, "https://primary.example.com/api/passkey/credentials/credential-1", expect.objectContaining({
      body: JSON.stringify({ password: "main-secret" }),
    }));
  });
});
