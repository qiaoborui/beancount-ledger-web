import { startAuthentication, startRegistration, type PublicKeyCredentialCreationOptionsJSON, type PublicKeyCredentialRequestOptionsJSON } from "@simplewebauthn/browser";
import { fetchJson, readJson } from "@/lib/clientFetch";

export function useLedgerAuth({ password, setPassword, setAuthed, setUnlocked, setPasskeyRegistered, showToast, clearToast }: { password: string; setPassword: (value: string) => void; setAuthed: (authenticated: boolean) => void; setUnlocked: (unlocked: boolean) => void; setPasskeyRegistered: (registered: boolean) => void; load: () => void | Promise<void>; showToast: (kind: "info" | "success" | "error", text: string) => void; clearToast: () => void }) {
  async function login() {
    const res = await fetch("/api/auth/login", { method: "POST", body: JSON.stringify({ password }) });
    if (res.ok) {
      sessionStorage.removeItem("ledger_locked_at");
      sessionStorage.removeItem("ledger_hidden_at");
      sessionStorage.setItem("ledger_unlocked", "1");
      sessionStorage.setItem("ledger_authed", "1");
      setUnlocked(true);
      setAuthed(true);
    } else {
      showToast("error", "密码不对");
    }
  }

  async function loginWithPasskey() {
    showToast("info", "正在唤起 Face ID...");
    try {
      const options = await fetchJson<PublicKeyCredentialRequestOptionsJSON & { error?: string }>("/api/passkey/login/options", { method: "POST" });
      if (options.error) throw new Error(options.error);
      const response = await startAuthentication({ optionsJSON: options });
      const verify = await fetch("/api/passkey/login/verify", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(response) });
      const data = await readJson<{ error?: string }>(verify);
      if (!verify.ok) throw new Error(data.error || "Face ID 登录失败");
      sessionStorage.removeItem("ledger_locked_at");
      sessionStorage.removeItem("ledger_hidden_at");
      sessionStorage.setItem("ledger_unlocked", "1");
      sessionStorage.setItem("ledger_authed", "1");
      setUnlocked(true);
      setAuthed(true);
      clearToast();
    } catch (error) {
      showToast("error", error instanceof Error ? error.message : String(error));
    }
  }

  async function registerPasskey() {
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
  }

  return { password, setPassword, login, loginWithPasskey, registerPasskey };
}
