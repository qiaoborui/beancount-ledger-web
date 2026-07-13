import { apiEndpointAuthScope, apiEndpointAuthStorageKey } from "@/lib/apiEndpoints";

type AuthStateStorage = Pick<Storage, "getItem" | "setItem" | "removeItem">;

type AuthStateEnvironment = {
  sessionStorage?: AuthStateStorage | null;
  localStorage?: AuthStateStorage | null;
  online?: boolean;
  endpointId?: string;
};

const sessionAuthedKey = "ledger_authed";
const sessionUnlockedKey = "ledger_unlocked";
const knownAuthKey = "ledger_auth_known";

function scopedKey(key: string, env: AuthStateEnvironment) {
  const endpointId = env.endpointId ?? apiEndpointAuthScope();
  return apiEndpointAuthStorageKey(key, endpointId);
}

function browserAuthStateEnvironment(): AuthStateEnvironment {
  if (typeof window === "undefined") return { online: true };
  return {
    sessionStorage: window.sessionStorage,
    localStorage: window.localStorage,
    online: typeof navigator === "undefined" ? true : navigator.onLine,
  };
}

function readStorage(storage: AuthStateStorage | null | undefined, key: string) {
  try {
    return storage?.getItem(key) ?? null;
  } catch {
    return null;
  }
}

function writeStorage(storage: AuthStateStorage | null | undefined, key: string, value: string) {
  try {
    storage?.setItem(key, value);
  } catch {
    // Storage may be unavailable in private mode.
  }
}

function removeStorage(storage: AuthStateStorage | null | undefined, key: string) {
  try {
    storage?.removeItem(key);
  } catch {
    // Storage may be unavailable in private mode.
  }
}

export function readInitialLedgerAuthState(env = browserAuthStateEnvironment()): boolean | null {
  if (readStorage(env.sessionStorage, scopedKey(sessionAuthedKey, env)) === "1") return true;
  if (readStorage(env.localStorage, scopedKey(knownAuthKey, env)) === "1") return true;
  if ((env.endpointId ?? apiEndpointAuthScope()) === "same-origin" && (readStorage(env.sessionStorage, sessionAuthedKey) === "1" || readStorage(env.localStorage, knownAuthKey) === "1")) return true;
  return null;
}

export function hasKnownLedgerAuthentication(env = browserAuthStateEnvironment()) {
  return readStorage(env.sessionStorage, scopedKey(sessionAuthedKey, env)) === "1" || readStorage(env.localStorage, scopedKey(knownAuthKey, env)) === "1";
}

export function rememberLedgerAuthenticated(env = browserAuthStateEnvironment()) {
  writeStorage(env.sessionStorage, scopedKey(sessionAuthedKey, env), "1");
  writeStorage(env.localStorage, scopedKey(knownAuthKey, env), "1");
}

export function forgetLedgerAuthentication(env = browserAuthStateEnvironment()) {
  removeStorage(env.sessionStorage, scopedKey(sessionAuthedKey, env));
  removeStorage(env.sessionStorage, sessionUnlockedKey);
  removeStorage(env.localStorage, scopedKey(knownAuthKey, env));
}
