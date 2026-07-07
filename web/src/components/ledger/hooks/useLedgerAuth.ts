import { useRef } from "react";
import { startAuthentication, startRegistration, type PublicKeyCredentialCreationOptionsJSON, type PublicKeyCredentialRequestOptionsJSON } from "@simplewebauthn/browser";
import { fetchJson, readJson } from "@/lib/clientFetch";
import { rememberLedgerAuthenticated } from "../authState";
import { unlockWithQuickLedgerSecret } from "../quickUnlock";

type LedgerAuthLoad = (forceFresh?: boolean, options?: { sensitiveUnlocked?: boolean }) => void | Promise<void>;

type LedgerAuthArgs = {
  password: string;
  setPassword: (value: string) => void;
  setAuthed: (authenticated: boolean) => void;
  setUnlocked: (unlocked: boolean) => void;
  setPasskeyRegistered: (registered: boolean) => void;
  load: LedgerAuthLoad;
  showToast: (kind: "info" | "success" | "error", text: string) => void;
  clearToast: () => void;
};

type LedgerAuthInFlight = {
  login: Promise<void> | null;
  passkeyLogin: Promise<void> | null;
  quickUnlock: Promise<void> | null;
  passkeyRegistration: Promise<void> | null;
};

function markSensitiveUnlocked(setUnlocked: (unlocked: boolean) => void, setAuthed: (authenticated: boolean) => void) {
  sessionStorage.removeItem("ledger_locked_at");
  sessionStorage.removeItem("ledger_hidden_at");
  sessionStorage.setItem("ledger_unlocked", "1");
  rememberLedgerAuthenticated();
  setUnlocked(true);
  setAuthed(true);
}

function refreshAfterAuth(load: LedgerAuthLoad, showToast: LedgerAuthArgs["showToast"]) {
  try {
    Promise.resolve(load(true, { sensitiveUnlocked: true })).catch((error) => {
      showToast("error", error instanceof Error ? `账本数据刷新失败：${error.message}` : "账本数据刷新失败");
    });
  } catch (error) {
    showToast("error", error instanceof Error ? `账本数据刷新失败：${error.message}` : "账本数据刷新失败");
  }
}

export function createLedgerAuthActions({ password, setPassword, setAuthed, setUnlocked, setPasskeyRegistered, load, showToast, clearToast }: LedgerAuthArgs, inFlight: LedgerAuthInFlight = { login: null, passkeyLogin: null, quickUnlock: null, passkeyRegistration: null }) {
  async function login() {
    if (inFlight.login) return inFlight.login;
    inFlight.login = (async () => {
      try {
        const res = await fetch("/api/auth/login", { method: "POST", body: JSON.stringify({ password }) });
        if (res.ok) {
          markSensitiveUnlocked(setUnlocked, setAuthed);
          refreshAfterAuth(load, showToast);
        } else {
          showToast("error", "密码不对");
        }
      } catch (error) {
        showToast("error", error instanceof Error ? error.message : "登录失败");
      }
    })();
    try {
      await inFlight.login;
    } finally {
      inFlight.login = null;
    }
  }

  async function loginWithPasskey() {
    if (inFlight.passkeyLogin) return inFlight.passkeyLogin;
    inFlight.passkeyLogin = (async () => {
      showToast("info", "正在唤起 Face ID...");
      try {
        const options = await fetchJson<PublicKeyCredentialRequestOptionsJSON & { error?: string }>("/api/passkey/login/options", { method: "POST" });
        if (options.error) throw new Error(options.error);
        const response = await startAuthentication({ optionsJSON: options });
        const verify = await fetch("/api/passkey/login/verify", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(response) });
        const data = await readJson<{ error?: string }>(verify);
        if (!verify.ok) throw new Error(data.error || "Face ID 登录失败");
        markSensitiveUnlocked(setUnlocked, setAuthed);
        refreshAfterAuth(load, showToast);
        clearToast();
      } catch (error) {
        showToast("error", error instanceof Error ? error.message : String(error));
      }
    })();
    try {
      await inFlight.passkeyLogin;
    } finally {
      inFlight.passkeyLogin = null;
    }
  }

  async function loginWithQuickUnlock(secret: string) {
    if (inFlight.quickUnlock) return inFlight.quickUnlock;
    inFlight.quickUnlock = (async () => {
      try {
        await unlockWithQuickLedgerSecret(secret);
        markSensitiveUnlocked(setUnlocked, setAuthed);
        refreshAfterAuth(load, showToast);
        clearToast();
      } catch (error) {
        showToast("error", error instanceof Error ? error.message : String(error));
        throw error;
      }
    })();
    try {
      await inFlight.quickUnlock;
    } finally {
      inFlight.quickUnlock = null;
    }
  }

  async function registerPasskey() {
    if (inFlight.passkeyRegistration) return inFlight.passkeyRegistration;
    inFlight.passkeyRegistration = (async () => {
      showToast("info", "正在启用 Face ID...");
      try {
        const options = await fetchJson<PublicKeyCredentialCreationOptionsJSON & { error?: string }>("/api/passkey/register/options", { method: "POST" });
        if (options.error) throw new Error(options.error);
        const response = await startRegistration({ optionsJSON: options });
        const verify = await fetch("/api/passkey/register/verify", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(response) });
        const data = await readJson<{ error?: string }>(verify);
        if (!verify.ok) throw new Error(data.error || "Face ID 启用失败");
        setPasskeyRegistered(true);
        showToast("success", "Face ID / Passkey 已启用");
      } catch (error) {
        showToast("error", error instanceof Error ? error.message : String(error));
      }
    })();
    try {
      await inFlight.passkeyRegistration;
    } finally {
      inFlight.passkeyRegistration = null;
    }
  }

  return { password, setPassword, login, loginWithPasskey, loginWithQuickUnlock, registerPasskey };
}

export function useLedgerAuth(args: LedgerAuthArgs) {
  const inFlightRef = useRef<LedgerAuthInFlight>({ login: null, passkeyLogin: null, quickUnlock: null, passkeyRegistration: null });
  return createLedgerAuthActions(args, inFlightRef.current);
}
