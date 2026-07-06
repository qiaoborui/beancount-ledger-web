import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { createLedgerAuthActions } from "./useLedgerAuth";
import { startAuthentication, startRegistration } from "@simplewebauthn/browser";

vi.mock("@simplewebauthn/browser", () => ({
  startAuthentication: vi.fn(),
  startRegistration: vi.fn(),
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
});
