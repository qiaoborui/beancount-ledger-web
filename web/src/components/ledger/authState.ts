type AuthStateStorage = Pick<Storage, "getItem" | "setItem" | "removeItem">;

type AuthStateEnvironment = {
  sessionStorage?: AuthStateStorage | null;
  localStorage?: AuthStateStorage | null;
  online?: boolean;
};

const sessionAuthedKey = "ledger_authed";
const sessionUnlockedKey = "ledger_unlocked";
const knownAuthKey = "ledger_auth_known";

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
  if (readStorage(env.sessionStorage, sessionAuthedKey) === "1") return true;
  if (env.online === false && readStorage(env.localStorage, knownAuthKey) === "1") return true;
  return null;
}

export function hasKnownLedgerAuthentication(env = browserAuthStateEnvironment()) {
  return readStorage(env.sessionStorage, sessionAuthedKey) === "1" || readStorage(env.localStorage, knownAuthKey) === "1";
}

export function rememberLedgerAuthenticated(env = browserAuthStateEnvironment()) {
  writeStorage(env.sessionStorage, sessionAuthedKey, "1");
  writeStorage(env.localStorage, knownAuthKey, "1");
}

export function forgetLedgerAuthentication(env = browserAuthStateEnvironment()) {
  removeStorage(env.sessionStorage, sessionAuthedKey);
  removeStorage(env.sessionStorage, sessionUnlockedKey);
  removeStorage(env.localStorage, knownAuthKey);
}
