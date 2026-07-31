import { afterEach, describe, expect, it, vi } from "vitest";
import { authenticationHaptic, haptic, readIOSAuthenticationHapticsEnabled, writeIOSAuthenticationHapticsEnabled } from "./haptics";

function memoryStorage() {
  const values = new Map<string, string>();
  return {
    getItem: (key: string) => values.get(key) ?? null,
    setItem: (key: string, value: string) => values.set(key, value),
    removeItem: (key: string) => values.delete(key),
  } satisfies Pick<Storage, "getItem" | "setItem" | "removeItem">;
}

function installBrowser(value: { userAgent: string; platform?: string; maxTouchPoints?: number; vibrate: ReturnType<typeof vi.fn> }) {
  vi.stubGlobal("window", { localStorage: memoryStorage() } as unknown as Window & typeof globalThis);
  vi.stubGlobal("navigator", {
    userAgent: value.userAgent,
    platform: value.platform ?? "",
    maxTouchPoints: value.maxTouchPoints ?? 0,
    vibrate: value.vibrate,
  } as unknown as Navigator);
}

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("haptics", () => {
  it("keeps existing haptics available outside iOS", () => {
    const vibrate = vi.fn();
    installBrowser({ userAgent: "Mozilla/5.0 (Linux; Android 15)", vibrate });

    haptic(6);

    expect(vibrate).toHaveBeenCalledWith(6);
  });

  it("limits iOS feedback to enabled authentication controls", () => {
    const vibrate = vi.fn();
    installBrowser({ userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X)", vibrate });

    haptic(6);
    authenticationHaptic(7);
    writeIOSAuthenticationHapticsEnabled(true);
    authenticationHaptic(8);

    expect(vibrate).toHaveBeenCalledTimes(1);
    expect(vibrate).toHaveBeenCalledWith(8);
    expect(readIOSAuthenticationHapticsEnabled()).toBe(true);
  });

  it("removes the polyfill identifier when feedback is disabled", () => {
    const vibrate = vi.fn();
    installBrowser({ userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X)", vibrate });
    window.localStorage.setItem("pro-max-vibrator-uuid", "test-id");

    writeIOSAuthenticationHapticsEnabled(false);

    expect(window.localStorage.getItem("pro-max-vibrator-uuid")).toBeNull();
  });
});
