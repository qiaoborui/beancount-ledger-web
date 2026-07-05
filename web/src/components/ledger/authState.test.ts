import { describe, expect, it } from "vitest";
import { forgetLedgerAuthentication, hasKnownLedgerAuthentication, readInitialLedgerAuthState, rememberLedgerAuthenticated } from "./authState";

function memoryStorage() {
  const values = new Map<string, string>();
  return {
    getItem: (key: string) => values.get(key) ?? null,
    setItem: (key: string, value: string) => values.set(key, value),
    removeItem: (key: string) => values.delete(key),
  };
}

describe("ledger auth state", () => {
  it("uses the session auth marker immediately", () => {
    const sessionStorage = memoryStorage();
    const localStorage = memoryStorage();
    rememberLedgerAuthenticated({ sessionStorage, localStorage, online: true });

    expect(readInitialLedgerAuthState({ sessionStorage, localStorage, online: true })).toBe(true);
  });

  it("treats a previous confirmed login as authenticated only while offline", () => {
    const sessionStorage = memoryStorage();
    const localStorage = memoryStorage();
    rememberLedgerAuthenticated({ sessionStorage, localStorage, online: true });
    sessionStorage.removeItem("ledger_authed");

    expect(readInitialLedgerAuthState({ sessionStorage, localStorage, online: false })).toBe(true);
    expect(readInitialLedgerAuthState({ sessionStorage, localStorage, online: true })).toBeNull();
  });

  it("clears the persistent login hint after the server reports unauthenticated", () => {
    const sessionStorage = memoryStorage();
    const localStorage = memoryStorage();
    rememberLedgerAuthenticated({ sessionStorage, localStorage, online: true });
    sessionStorage.setItem("ledger_unlocked", "1");

    forgetLedgerAuthentication({ sessionStorage, localStorage, online: true });

    expect(hasKnownLedgerAuthentication({ sessionStorage, localStorage, online: false })).toBe(false);
    expect(sessionStorage.getItem("ledger_unlocked")).toBeNull();
  });
});
