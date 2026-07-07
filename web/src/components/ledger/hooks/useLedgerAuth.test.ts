import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { createLedgerAuthActions } from "./useLedgerAuth";
import { startAuthentication, startRegistration } from "@simplewebauthn/browser";
import { unlockWithQuickLedgerSecret } from "../quickUnlock";

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
    Object.defineProperty(globalThis, "sessionStorage", { value: memoryStorage(), configurable: true });
    Object.defineProperty(globalThis, "localStorage", { value: memoryStorage(), configurable: true });
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
  });

  afterEach(() => {
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
});
