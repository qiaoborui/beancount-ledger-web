import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { createLedgerAuthActions } from "./useLedgerAuth";
import { startAuthentication, startRegistration } from "@simplewebauthn/browser";
import { unlockWithQuickLedgerSecret } from "../quickUnlock";
import { apiEndpointAuthStorageKey, resetApiEndpointRuntimeState, writeApiEndpointSettings } from "@/lib/apiEndpoints";

vi.mock("@simplewebauthn/browser", () => ({
  startAuthentication: vi.fn(),
  startRegistration: vi.fn(),
}));

vi.mock("../quickUnlock", () => ({
  unlockWithQuickLedgerSecret: vi.fn(),
}));

function memoryStorage() {
  const values = new Map<string, string>();
  return {
    getItem: (key: string) => values.get(key) ?? null,
    setItem: (key: string, value: string) => values.set(key, value),
    removeItem: (key: string) => values.delete(key),
    clear: () => values.clear(),
    key: (index: number) => Array.from(values.keys())[index] ?? null,
    get length() {
      return values.size;
    },
  };
}

function jsonResponse(data: unknown, init?: ResponseInit) {
  return new Response(JSON.stringify(data), init);
}

function authArgs() {
  return {
    password: "",
    setPassword: vi.fn(),
    setAuthed: vi.fn(),
    setUnlocked: vi.fn(),
    setPasskeyRegistered: vi.fn(),
    load: vi.fn().mockResolvedValue(undefined),
    showToast: vi.fn(),
    clearToast: vi.fn(),
  };
}

describe("createLedgerAuthActions", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    const sessionStorage = memoryStorage();
    const localStorage = memoryStorage();
    Object.defineProperty(globalThis, "sessionStorage", { value: sessionStorage, configurable: true });
    Object.defineProperty(globalThis, "localStorage", { value: localStorage, configurable: true });
    vi.mocked(startAuthentication).mockResolvedValue({ id: "credential" } as never);
    vi.mocked(startRegistration).mockResolvedValue({ id: "credential" } as never);
    vi.mocked(unlockWithQuickLedgerSecret).mockResolvedValue(undefined);
    globalThis.fetch = vi.fn(async (input) => {
      const url = String(input);
      if (url.endsWith("/api/passkey/login/options")) return jsonResponse({ challenge: "login-challenge" });
      if (url.endsWith("/api/passkey/login/verify")) return jsonResponse({ ok: true });
      if (url.endsWith("/api/passkey/register/options")) return jsonResponse({ challenge: "register-challenge" });
      if (url.endsWith("/api/passkey/register/verify")) return jsonResponse({ ok: true });
      if (url.endsWith("/api/auth/login")) return jsonResponse({ ok: true });
      return jsonResponse({}, { status: 404 });
    }) as typeof fetch;
    vi.stubGlobal("window", {
      localStorage,
      sessionStorage,
      location: { origin: "https://app.example.com" },
      fetch: globalThis.fetch,
      setTimeout,
      clearTimeout,
      dispatchEvent: vi.fn(),
    });
  });

  afterEach(() => {
    resetApiEndpointRuntimeState();
    vi.unstubAllGlobals();
    vi.restoreAllMocks();
  });

  it("refreshes unlocked ledger data immediately after passkey login", async () => {
    const args = authArgs();
    const actions = createLedgerAuthActions(args);

    await actions.loginWithPasskey();

    expect(args.setUnlocked).toHaveBeenCalledWith(true);
    expect(args.setAuthed).toHaveBeenCalledWith(true);
    expect(args.load).toHaveBeenCalledWith(true, { sensitiveUnlocked: true });
    expect(args.clearToast).toHaveBeenCalled();
  });

  it("uses an explicit main password to unlock an existing session", async () => {
    const args = authArgs();
    const actions = createLedgerAuthActions(args);

    await actions.loginWithPassword("fallback-secret");

    const loginCall = vi.mocked(window.fetch).mock.calls.find(([input]) => String(input).endsWith("/api/auth/login"));
    expect(loginCall?.[1]?.body).toBe(JSON.stringify({ password: "fallback-secret" }));
    expect(args.setUnlocked).toHaveBeenCalledWith(true);
    expect(args.load).toHaveBeenCalledWith(true, { sensitiveUnlocked: true });
    expect(args.clearToast).toHaveBeenCalled();
  });

  it("coalesces repeated passkey login clicks into one browser prompt", async () => {
    const args = authArgs();
    const actions = createLedgerAuthActions(args);

    await Promise.all([actions.loginWithPasskey(), actions.loginWithPasskey()]);

    const urls = vi.mocked(globalThis.fetch).mock.calls.map(([input]) => String(input));
    expect(urls.filter((url) => url.endsWith("/api/passkey/login/options"))).toHaveLength(1);
    expect(vi.mocked(startAuthentication)).toHaveBeenCalledTimes(1);
    expect(args.load).toHaveBeenCalledTimes(1);
  });

  it("does not treat a post-login ledger refresh failure as a passkey failure", async () => {
    const args = authArgs();
    args.load = vi.fn().mockRejectedValue(new Error("bootstrap timed out"));
    const actions = createLedgerAuthActions(args);

    await actions.loginWithPasskey();
    await Promise.resolve();

    expect(args.setUnlocked).toHaveBeenCalledWith(true);
    expect(args.setAuthed).toHaveBeenCalledWith(true);
    expect(args.clearToast).toHaveBeenCalled();
    expect(args.showToast).toHaveBeenCalledWith("error", "账本数据刷新失败：bootstrap timed out");
  });

  it("returns from quick unlock before the full ledger refresh completes", async () => {
    const args = authArgs();
    let finishRefresh: () => void = () => {};
    let refreshSettled = false;
    args.load = vi.fn(() => new Promise<void>((resolve) => {
      finishRefresh = () => {
        refreshSettled = true;
        resolve();
      };
    }));
    const actions = createLedgerAuthActions(args);

    await actions.loginWithQuickUnlock("local-secret");

    expect(refreshSettled).toBe(false);
    expect(args.setUnlocked).toHaveBeenCalledWith(true);
    expect(args.clearToast).toHaveBeenCalled();
    finishRefresh();
  });

  it("propagates quick unlock secret failures so the modal can stay open", async () => {
    const args = authArgs();
    vi.mocked(unlockWithQuickLedgerSecret).mockRejectedValueOnce(new Error("bad local secret"));
    const actions = createLedgerAuthActions(args);

    await expect(actions.loginWithQuickUnlock("bad")).rejects.toThrow("bad local secret");

    expect(args.setUnlocked).not.toHaveBeenCalled();
    expect(args.load).not.toHaveBeenCalled();
    expect(args.showToast).toHaveBeenCalledWith("error", "bad local secret");
  });

  it("records a successful password login against the endpoint used for that login request", async () => {
    writeApiEndpointSettings({
      activeId: "primary",
      autoSelect: false,
      endpoints: [
        { id: "same-origin", url: "", enabled: true },
        { id: "primary", url: "https://primary.example.com", enabled: true },
        { id: "backup", url: "https://backup.example.com", enabled: true },
      ],
    });
    vi.mocked(window.fetch).mockImplementationOnce(async () => {
      writeApiEndpointSettings({
        activeId: "backup",
        autoSelect: false,
        endpoints: [
          { id: "same-origin", url: "", enabled: true },
          { id: "primary", url: "https://primary.example.com", enabled: true },
          { id: "backup", url: "https://backup.example.com", enabled: true },
        ],
      });
      return jsonResponse({ ok: true });
    });
    const args = authArgs();
    const actions = createLedgerAuthActions(args);

    await actions.login();

    expect(localStorage.getItem(apiEndpointAuthStorageKey("ledger_auth_known", "primary"))).toBe("1");
    expect(localStorage.getItem(apiEndpointAuthStorageKey("ledger_auth_known", "backup"))).toBeNull();
    expect(vi.mocked(window.fetch).mock.calls[0][1]?.headers).toEqual({ "Content-Type": "application/json" });
  });
});
