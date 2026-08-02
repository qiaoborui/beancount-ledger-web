import { useRef } from "react";
import { startAuthentication, startRegistration, type PublicKeyCredentialCreationOptionsJSON, type PublicKeyCredentialRequestOptionsJSON } from "@simplewebauthn/browser";
import { fetchJson, readJson } from "@/lib/clientFetch";
import { apiEndpointAuthScope, apiFetch, currentApiEndpoint, readApiEndpointSettings, type ApiEndpoint } from "@/lib/apiEndpoints";
import { rememberLedgerAuthenticated } from "../authState";
import type { PasskeyCredentialSummary } from "../passkeys";
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
  passkeyOptions: PreparedPasskeyLogin | null;
  passkeyOptionsRequest: Promise<void> | null;
  passkeyOptionsRequestEndpointId: string | null;
  quickUnlock: Promise<void> | null;
  passkeyRegistration: Promise<PasskeyCredentialSummary | null> | null;
};

type PreparedPasskeyLogin = {
  endpointId: string;
  options: PublicKeyCredentialRequestOptionsJSON;
  preparedAt: number;
};

const passkeyOptionsMaxAgeMs = 8 * 60 * 1000;

function emptyLedgerAuthInFlight(): LedgerAuthInFlight {
  return {
    login: null,
    passkeyLogin: null,
    passkeyOptions: null,
    passkeyOptionsRequest: null,
    passkeyOptionsRequestEndpointId: null,
    quickUnlock: null,
    passkeyRegistration: null,
  };
}

function markSensitiveUnlocked(setUnlocked: (unlocked: boolean) => void, setAuthed: (authenticated: boolean) => void, endpointId = apiEndpointAuthScope()) {
  sessionStorage.removeItem("ledger_locked_at");
  sessionStorage.removeItem("ledger_hidden_at");
  sessionStorage.setItem("ledger_unlocked", "1");
  rememberLedgerAuthenticated({ sessionStorage, localStorage, endpointId });
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

export function createLedgerAuthActions({ password, setPassword, setAuthed, setUnlocked, setPasskeyRegistered, load, showToast, clearToast }: LedgerAuthArgs, inFlight: LedgerAuthInFlight = emptyLedgerAuthInFlight()) {
  async function loginWithPassword(inputPassword: string) {
    if (inFlight.login) return inFlight.login;
    inFlight.login = (async () => {
      const endpointId = apiEndpointAuthScope();
      try {
        const res = await apiFetch("/api/auth/login", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ password: inputPassword }) }, { kind: "auth" });
        if (!res.ok) {
          const data = await readJson<{ error?: string }>(res, {});
          throw new Error(res.status === 401 ? "密码不对" : data.error || `登录失败：${res.status}`);
        }
        markSensitiveUnlocked(setUnlocked, setAuthed, endpointId);
        refreshAfterAuth(load, showToast);
        clearToast();
      } catch (error) {
        const message = error instanceof Error ? error.message : "登录失败";
        showToast("error", message);
        throw error;
      }
    })();
    try {
      await inFlight.login;
    } finally {
      inFlight.login = null;
    }
  }

  async function login() {
    try {
      await loginWithPassword(password);
    } catch {
      // The login screen displays the error through the shared toast.
    }
  }

  function preparedPasskeyOptions(endpointId: string) {
    const prepared = inFlight.passkeyOptions;
    if (!prepared || prepared.endpointId !== endpointId || Date.now() - prepared.preparedAt >= passkeyOptionsMaxAgeMs) {
      inFlight.passkeyOptions = null;
      return null;
    }
    return prepared.options;
  }

  async function preparePasskeyLogin() {
    const endpointId = apiEndpointAuthScope();
    if (preparedPasskeyOptions(endpointId)) return;
    if (inFlight.passkeyOptionsRequest && inFlight.passkeyOptionsRequestEndpointId === endpointId) {
      return inFlight.passkeyOptionsRequest;
    }
    inFlight.passkeyOptionsRequestEndpointId = endpointId;
    const request = (async () => {
      const options = await fetchJson<PublicKeyCredentialRequestOptionsJSON & { error?: string }>("/api/passkey/login/options", { method: "POST" });
      if (options.error) throw new Error(options.error);
      if (apiEndpointAuthScope() === endpointId) {
        inFlight.passkeyOptions = { endpointId, options, preparedAt: Date.now() };
      }
    })();
    inFlight.passkeyOptionsRequest = request;
    try {
      await request;
    } finally {
      if (inFlight.passkeyOptionsRequest === request) {
        inFlight.passkeyOptionsRequest = null;
        inFlight.passkeyOptionsRequestEndpointId = null;
      }
    }
  }

  async function loginWithPasskey() {
    if (inFlight.passkeyLogin) return inFlight.passkeyLogin;
    inFlight.passkeyLogin = (async () => {
      const endpointId = apiEndpointAuthScope();
      try {
        let options = preparedPasskeyOptions(endpointId);
        if (!options) {
          await preparePasskeyLogin();
          options = preparedPasskeyOptions(endpointId);
        }
        if (!options) throw new Error("Face ID 登录准备失败，请重试");
        inFlight.passkeyOptions = null;
        const response = await startAuthentication({ optionsJSON: options });
        const verify = await apiFetch("/api/passkey/login/verify", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(response) }, { kind: "auth" });
        const data = await readJson<{ error?: string }>(verify);
        if (!verify.ok) throw new Error(data.error || "Face ID 登录失败");
        markSensitiveUnlocked(setUnlocked, setAuthed, endpointId);
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
      const endpointId = apiEndpointAuthScope();
      try {
        await unlockWithQuickLedgerSecret(secret);
        markSensitiveUnlocked(setUnlocked, setAuthed, endpointId);
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

  async function registerPasskey(endpoint: ApiEndpoint = currentApiEndpoint(readApiEndpointSettings())) {
    if (inFlight.passkeyRegistration) return inFlight.passkeyRegistration;
    inFlight.passkeyRegistration = (async () => {
      showToast("info", "正在添加 Passkey...");
      try {
        const optionsResponse = await apiFetch("/api/passkey/register/options", { method: "POST" }, { kind: "auth", endpoint });
        const options = await readJson<PublicKeyCredentialCreationOptionsJSON & { error?: string }>(optionsResponse);
        if (!optionsResponse.ok) throw new Error(options.error || "无法开始添加 Passkey");
        if (options.error) throw new Error(options.error);
        const response = await startRegistration({ optionsJSON: options });
        const verify = await apiFetch("/api/passkey/register/verify", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(response) }, { kind: "auth", endpoint });
        const data = await readJson<{ error?: string; credential?: PasskeyCredentialSummary }>(verify);
        if (!verify.ok) throw new Error(data.error || "Face ID 启用失败");
        setPasskeyRegistered(true);
        showToast("success", "Passkey 已添加");
        return data.credential ?? null;
      } catch (error) {
        if (error instanceof DOMException && error.name === "NotAllowedError") {
          showToast("info", "已取消添加 Passkey");
          return null;
        }
        showToast("error", error instanceof Error ? error.message : String(error));
        return null;
      }
    })();
    try {
      return await inFlight.passkeyRegistration;
    } finally {
      inFlight.passkeyRegistration = null;
    }
  }

  return { password, setPassword, login, loginWithPassword, preparePasskeyLogin, loginWithPasskey, loginWithQuickUnlock, registerPasskey };
}

export function useLedgerAuth(args: LedgerAuthArgs) {
  const inFlightRef = useRef<LedgerAuthInFlight>(emptyLedgerAuthInFlight());
  return createLedgerAuthActions(args, inFlightRef.current);
}
