import { useEffect, useRef, useState } from "react";
import { useTranslation } from "react-i18next";
import { Delete, Fingerprint, KeyRound, LockKeyhole, ShieldCheck } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import {
  apiEndpointSettingsChangeEvent,
  applyApiEndpointProbe,
  createApiEndpointId,
  displayApiEndpointUrl,
  isSameOriginApiEndpoint,
  normalizeApiEndpointUrl,
  probeApiEndpoint,
  readApiEndpointSettings,
  withActiveApiEndpoint,
  writeApiEndpointSettings,
  type ApiEndpointSettings,
} from "@/lib/apiEndpoints";
import type { QuickUnlockMode } from "./quickUnlock";

export function AppSkeleton() {
  return <div className="min-h-dvh bg-paper p-6"><div className="mx-auto max-w-4xl animate-pulse space-y-6"><div className="h-12 rounded-2xl bg-line" /><div className="grid grid-cols-3 gap-3"><div className="h-24 rounded-2xl bg-line" /><div className="h-24 rounded-2xl bg-line" /><div className="h-24 rounded-2xl bg-line" /></div><div className="h-72 rounded-2xl bg-line" /></div></div>;
}

export function LoginScreen({ password, setPassword, passkeyRegistered, passkeyLoading, toastText, onLogin, onPasskeyLogin }: { password: string; setPassword: (value: string) => void; passkeyRegistered: boolean; passkeyLoading?: boolean; toastText?: string; onLogin: () => void; onPasskeyLogin: () => void }) {
  const { t } = useTranslation();
  const [endpointSettings, setEndpointSettings] = useState<ApiEndpointSettings>(() => readApiEndpointSettings());
  const [showEndpointSettings, setShowEndpointSettings] = useState(false);
  const [draftEndpointUrl, setDraftEndpointUrl] = useState("");
  const [endpointMessage, setEndpointMessage] = useState("");
  const enabledEndpoints = endpointSettings.endpoints.filter((endpoint) => endpoint.enabled);
  const activeEndpoint = enabledEndpoints.find((endpoint) => endpoint.id === endpointSettings.activeId) ?? enabledEndpoints[0];

  useEffect(() => {
    const refresh = () => setEndpointSettings(readApiEndpointSettings());
    window.addEventListener(apiEndpointSettingsChangeEvent, refresh);
    window.addEventListener("storage", refresh);
    return () => {
      window.removeEventListener(apiEndpointSettingsChangeEvent, refresh);
      window.removeEventListener("storage", refresh);
    };
  }, []);

  async function selectEndpoint(activeId: string) {
    const endpoint = endpointSettings.endpoints.find((item) => item.id === activeId && item.enabled);
    if (!endpoint || endpoint.id === endpointSettings.activeId) return;
    setEndpointMessage(t("auth.verifyingBackend"));
    try {
      const result = await probeApiEndpoint(endpoint);
      const verified = applyApiEndpointProbe(endpointSettings, endpoint.id, result);
      const next = withActiveApiEndpoint(verified, endpoint.id);
      if (next.activeId !== endpoint.id) throw new Error(t("auth.incompatibleBackend"));
      setEndpointMessage(t("auth.switchedBackend"));
      setEndpointSettings(next);
      writeApiEndpointSettings(next);
    } catch (error) {
      setEndpointMessage(error instanceof Error ? error.message : t("auth.switchBackendFailed"));
    }
  }

  async function addEndpoint() {
    try {
      const url = normalizeApiEndpointUrl(draftEndpointUrl);
      const existing = endpointSettings.endpoints.find((endpoint) => endpoint.url === url);
      if (existing) {
        setDraftEndpointUrl("");
        const enabledSettings: ApiEndpointSettings = {
          ...endpointSettings,
          endpoints: endpointSettings.endpoints.map((endpoint) => endpoint.id === existing.id ? { ...endpoint, enabled: true } : endpoint),
        };
        const result = await probeApiEndpoint({ ...existing, enabled: true });
        const verified = applyApiEndpointProbe(enabledSettings, existing.id, result);
        const next = withActiveApiEndpoint(verified, existing.id);
        if (next.activeId !== existing.id) throw new Error(t("auth.backendIncompatible"));
        setEndpointMessage(t("auth.backendExistsSwitched"));
        setEndpointSettings(next);
        writeApiEndpointSettings(next);
        return;
      }
      const id = createApiEndpointId();
      const endpoint = { id, url, enabled: true };
      let next: ApiEndpointSettings = {
        ...endpointSettings,
        activeId: id,
        endpoints: [...endpointSettings.endpoints, endpoint],
      };
      setEndpointMessage(t("auth.verifyingNewBackend"));
      const result = await probeApiEndpoint(endpoint);
      next = applyApiEndpointProbe(next, endpoint.id, result);
      setDraftEndpointUrl("");
      setEndpointMessage(t("auth.addedConnecting"));
      setEndpointSettings(next);
      writeApiEndpointSettings(next);
    } catch (error) {
      setEndpointMessage(error instanceof Error ? error.message : t("auth.addBackendFailed"));
    }
  }

  return <div className="grid min-h-dvh place-items-center bg-paper px-4 py-[max(1rem,env(safe-area-inset-top))] pb-[max(1rem,env(safe-area-inset-bottom))]">
    <div className="card w-full max-w-md p-7">
      <div className="mb-7 h-1 w-12 rounded-full bg-brand" />
      <h1 className="font-serif text-3xl font-medium">{t("app.name")}</h1>
      <p className="mt-2 text-sm leading-6 text-olive">{t("auth.loginSubtitle")}</p>
      <div className="mt-5 rounded-2xl border border-line bg-panel p-3">
        <div className="flex items-start justify-between gap-3">
          <div className="min-w-0">
            <div className="text-xs text-stone">{t("auth.currentBackend")}</div>
            <div className="mt-1 break-all text-sm font-medium text-ink">{activeEndpoint ? displayApiEndpointUrl(activeEndpoint) : t("auth.noBackendAvailable")}</div>
          </div>
          <button type="button" className="shrink-0 text-sm font-medium text-brand" onClick={() => setShowEndpointSettings((value) => !value)} aria-expanded={showEndpointSettings}>{showEndpointSettings ? t("auth.collapse") : t("auth.switchBackend")}</button>
        </div>
        {showEndpointSettings && <div className="mt-3 space-y-3 border-t border-line pt-3">
          <label className="block">
            <span className="mb-1.5 block text-xs text-stone">{t("auth.useBackend")}</span>
            <select className="h-11 w-full rounded-xl border border-line bg-paper px-3 text-sm text-ink" value={activeEndpoint?.id ?? ""} onChange={(event) => void selectEndpoint(event.target.value)}>
              {enabledEndpoints.map((endpoint) => <option key={endpoint.id} value={endpoint.id}>{isSameOriginApiEndpoint(endpoint) ? `${t("apiEndpoints.currentSite")} · ${displayApiEndpointUrl(endpoint)}` : endpoint.url}</option>)}
            </select>
          </label>
          <div className="grid gap-2 sm:grid-cols-[minmax(0,1fr)_auto]">
            <Input value={draftEndpointUrl} onChange={(event) => setDraftEndpointUrl(event.target.value)} onKeyDown={(event) => event.key === "Enter" && void addEndpoint()} placeholder="https://api.example.com" className="h-11 rounded-xl bg-paper" />
            <Button type="button" variant="outline" className="h-11 rounded-xl bg-paper" onClick={() => void addEndpoint()}>{t("auth.addAndSwitch")}</Button>
          </div>
          <p className="text-xs leading-5 text-stone">{t("auth.backendHint")}</p>
          {endpointMessage && <p className="text-xs text-stone">{endpointMessage}</p>}
        </div>}
      </div>
      <Input type="password" className="mt-6 h-12 rounded-xl bg-panel" value={password} onChange={(e) => setPassword(e.target.value)} onKeyDown={(e) => e.key === "Enter" && onLogin()} placeholder={t("auth.passwordPlaceholder")} />
      <Button className="mt-4 h-12 w-full rounded-xl" onClick={onLogin}>{t("auth.passwordLogin")}</Button>
      {passkeyRegistered && <Button variant="outline" className="mt-3 h-12 w-full rounded-xl bg-paper text-warm" disabled={passkeyLoading} onClick={onPasskeyLogin}>{passkeyLoading ? t("auth.invokingFaceId") : t("auth.loginWithFaceId")}</Button>}
      {toastText && <p className="mt-3 whitespace-pre-wrap text-sm text-[var(--danger)]">{toastText}</p>}
    </div>
  </div>;
}

export function UnlockScreen({ message, onUnlock }: { message: string; onUnlock: () => void }) {
  const { t } = useTranslation();
  return <div className="grid min-h-dvh place-items-center bg-brand px-4 py-[max(1rem,env(safe-area-inset-top))] pb-[max(1rem,env(safe-area-inset-bottom))] text-paper"><div className="kami-float w-full max-w-sm rounded-xl border border-paper/20 bg-paper p-6 text-center text-ink"><h1 className="font-serif text-3xl font-medium">{t("auth.ledgerLocked")}</h1><p className="mt-3 text-sm text-olive">{t("auth.unlockHint")}</p><Button className="mt-6 h-12 w-full rounded-xl" onClick={onUnlock}>{t("auth.unlock")}</Button>{message && <p className="mt-3 whitespace-pre-wrap text-sm text-[var(--danger)]">{message}</p>}<p className="mt-4 text-xs text-stone">{t("auth.lockNote")}</p></div></div>;
}

export function SensitiveUnlockPanel({
  title = "",
  description = "",
  message,
  offline,
  offlineUnlockAvailable,
  offlineSecret,
  onOfflineSecretChange,
  onOfflineUnlock,
  quickUnlockEnabled,
  quickUnlockMode,
  passkeyRegistered,
  onQuickUnlock,
  onUnlock,
  onPasswordUnlock,
  unlocking,
  autoFocusInput,
  surface = "page",
}: {
  title?: string;
  description?: string;
  message?: string;
  offline?: boolean;
  offlineUnlockAvailable?: boolean;
  offlineSecret?: string;
  onOfflineSecretChange?: (value: string) => void;
  onOfflineUnlock?: () => void;
  quickUnlockEnabled?: boolean;
  quickUnlockMode?: QuickUnlockMode;
  passkeyRegistered?: boolean;
  onQuickUnlock?: (secret: string) => void;
  onUnlock: () => void;
  onPasswordUnlock?: (password: string) => void;
  unlocking?: boolean;
  autoFocusInput?: boolean;
  surface?: "page" | "dialog";
}) {
  const { t } = useTranslation();
  const effectiveTitle = title || t("auth.assetsHidden");
  const effectiveDescription = description || t("auth.sensitiveDesc");
  const offlineInputRef = useRef<HTMLInputElement | null>(null);
  useEffect(() => {
    if (!autoFocusInput || !offline || !offlineUnlockAvailable) return;
    const id = window.requestAnimationFrame(() => offlineInputRef.current?.focus());
    return () => window.cancelAnimationFrame(id);
  }, [autoFocusInput, offline, offlineUnlockAvailable]);

  const canUsePasskey = !offline && passkeyRegistered;
  const showPasswordInline = !offline && Boolean(onPasswordUnlock) && !quickUnlockEnabled && !passkeyRegistered;
  const shellClassName = surface === "dialog"
    ? "overflow-hidden rounded-md border border-line bg-panel px-5 py-6 shadow-[0_18px_50px_rgba(20,20,19,0.22)] sm:px-6"
    : "border-y border-line bg-panel px-4 py-12 text-center sm:px-6 lg:py-16";

  return <section className={shellClassName}>
    <div className="mx-auto flex max-w-xl flex-col items-center text-center">
      <div className="mb-5 grid h-10 w-10 place-items-center rounded-md border border-line bg-paper text-brand">
        <LockKeyhole className="h-5 w-5" />
      </div>
      <h2 className="font-serif text-2xl font-medium leading-tight text-ink">{effectiveTitle}</h2>
      <p className="mt-3 max-w-lg text-sm leading-6 text-olive">{effectiveDescription}</p>
    </div>

    <div className="mx-auto mt-6 w-full max-w-sm">
    {offline && offlineUnlockAvailable ? (
      <div className="grid gap-2 sm:grid-cols-[minmax(0,1fr)_auto]">
        <Input ref={offlineInputRef} autoFocus={autoFocusInput} type="password" className="h-11 bg-paper text-center sm:text-left" value={offlineSecret ?? ""} onChange={(event) => onOfflineSecretChange?.(event.target.value)} onKeyDown={(event) => event.key === "Enter" && onOfflineUnlock?.()} placeholder={t("auth.offlineUnlockCode")} />
        <Button className="h-11 px-4" onClick={onOfflineUnlock}><KeyRound className="mr-2 h-4 w-4" />{t("auth.offlineUnlock")}</Button>
      </div>
    ) : (
      <div className="space-y-3">
        {canUsePasskey && <Button className="h-11 w-full px-5" disabled={unlocking} onClick={onUnlock}><Fingerprint className="mr-2 h-4 w-4" />{unlocking ? t("auth.invokingFaceId") : t("auth.faceIdUnlock")}</Button>}
        {quickUnlockEnabled && <QuickUnlockControls mode={quickUnlockMode ?? "text"} onUnlock={onQuickUnlock ?? onUnlock} passkeyRegistered={canUsePasskey ? false : passkeyRegistered} onPasskeyUnlock={onUnlock} unlocking={unlocking} autoFocusInput={autoFocusInput} t={t} />}
        {!canUsePasskey && !quickUnlockEnabled && <p className="text-sm leading-6 text-stone">{t("auth.noQuickUnlockMethod")}</p>}
      </div>
    )}
    </div>

    {!offline && onPasswordUnlock && <PasswordUnlockControls onUnlock={onPasswordUnlock} unlocking={unlocking} autoFocusInput={autoFocusInput && showPasswordInline} initiallyOpen={Boolean(showPasswordInline)} t={t} />}
    {offline && !offlineUnlockAvailable && <p className="mx-auto mt-3 max-w-xl text-sm text-stone">{t("auth.offlineHint")}</p>}
    {message && <p className="mt-3 whitespace-pre-wrap text-sm text-[var(--danger)]">{message}</p>}
    <p className="mx-auto mt-5 flex max-w-sm items-center justify-center gap-1.5 text-xs leading-5 text-stone"><ShieldCheck className="h-3.5 w-3.5 shrink-0 text-brand" />{t("auth.autoHideNote")}</p>
  </section>;
}

function PasswordUnlockControls({ onUnlock, unlocking, autoFocusInput, initiallyOpen, t }: { onUnlock: (password: string) => void; unlocking?: boolean; autoFocusInput?: boolean; initiallyOpen: boolean; t: (key: string) => string }) {
  const [password, setPassword] = useState("");
  const [open, setOpen] = useState(initiallyOpen);
  const inputRef = useRef<HTMLInputElement | null>(null);
  useEffect(() => {
    if (!open || !autoFocusInput) return;
    const id = window.requestAnimationFrame(() => inputRef.current?.focus());
    return () => window.cancelAnimationFrame(id);
  }, [autoFocusInput, open]);
  return <div className="mx-auto mt-4 max-w-sm">
    {!open ? <button type="button" className="text-sm font-medium text-brand disabled:opacity-50" onClick={() => setOpen(true)} disabled={unlocking}>{t("auth.usePassword")}</button> : <div className="grid gap-2 sm:grid-cols-[minmax(0,1fr)_auto]">
      <Input ref={inputRef} autoFocus={autoFocusInput || open} type="password" autoComplete="current-password" className="h-11 bg-paper text-center sm:text-left" value={password} onChange={(event) => setPassword(event.target.value)} onKeyDown={(event) => event.key === "Enter" && password && onUnlock(password)} placeholder={t("auth.passwordPlaceholder")} disabled={unlocking} />
      <Button variant="outline" className="h-11 px-4" disabled={!password || unlocking} onClick={() => onUnlock(password)}>{unlocking ? t("auth.unlocking") : t("auth.unlock")}</Button>
    </div>}
  </div>;
}

export function PasskeyBanner({ onRegister }: { onRegister: () => void }) {
  const { t } = useTranslation();
  return <section className="card mb-6 flex flex-col gap-3 p-5 sm:flex-row sm:items-center sm:justify-between"><div><h2 className="font-serif text-xl font-medium">{t("auth.enableFaceId")}</h2><p className="mt-1 text-sm text-olive">{t("auth.enableFaceIdDesc")}</p></div><Button className="h-12 rounded-xl px-5" onClick={onRegister}>{t("auth.enable")}</Button></section>;
}

function QuickUnlockControls({ mode, passkeyRegistered, onUnlock, onPasskeyUnlock, unlocking, autoFocusInput, t }: { mode: QuickUnlockMode; passkeyRegistered?: boolean; onUnlock: (secret: string) => void; onPasskeyUnlock: () => void; unlocking?: boolean; autoFocusInput?: boolean; t: (key: string) => string }) {
  const [secret, setSecret] = useState("");
  const [expanded, setExpanded] = useState(false);
  const inputRef = useRef<HTMLInputElement | null>(null);
  useEffect(() => {
    if (!autoFocusInput || mode !== "text") return;
    const id = window.requestAnimationFrame(() => inputRef.current?.focus());
    return () => window.cancelAnimationFrame(id);
  }, [autoFocusInput, mode]);

  if (mode === "numeric") {
    if (!expanded) {
      return <div className="flex flex-col items-center gap-2">
        <button type="button" className="inline-flex h-9 items-center gap-2 rounded-md px-3 text-sm font-medium text-brand hover:bg-tag disabled:opacity-50" disabled={unlocking} onClick={() => setExpanded(true)}><KeyRound className="h-4 w-4" />{t("auth.deviceCode")}</button>
        {passkeyRegistered && <button type="button" className="text-xs text-stone hover:text-brand disabled:opacity-50" disabled={unlocking} onClick={onPasskeyUnlock}>{unlocking ? t("auth.invokingFaceId") : t("auth.switchToFaceId")}</button>}
      </div>;
    }
    return <div className="mx-auto w-full max-w-xs">
      <div className="mb-3 h-11 rounded-md border border-line bg-paper px-4 text-center text-2xl leading-10 tracking-[0.32em] text-ink" aria-label={t("auth.quickUnlockNumericPlaceholder")}>{secret ? "•".repeat(Math.min(secret.length, 8)) : ""}</div>
      <div className="grid grid-cols-3 gap-2">
        {["1", "2", "3", "4", "5", "6", "7", "8", "9"].map((digit) => <KeypadButton key={digit} label={digit} onClick={() => setSecret(secret + digit)} disabled={unlocking} />)}
        <KeypadButton label="删" onClick={() => setSecret(secret.slice(0, -1))} disabled={unlocking} />
        <KeypadButton label="0" onClick={() => setSecret(secret + "0")} disabled={unlocking} />
        <button type="button" className="h-12 rounded-md bg-brand text-sm font-medium text-paper disabled:opacity-50" disabled={!secret || unlocking} onClick={() => onUnlock(secret)}>{unlocking ? t("auth.unlocking") : t("auth.unlock")}</button>
      </div>
      {passkeyRegistered && <button type="button" className="mt-3 text-sm text-brand disabled:opacity-50" disabled={unlocking} onClick={onPasskeyUnlock}>{unlocking ? t("auth.invokingFaceId") : t("auth.switchToFaceId")}</button>}
    </div>;
  }
  return <div className="grid gap-2 sm:grid-cols-[minmax(0,1fr)_auto]">
    <Input ref={inputRef} autoFocus={autoFocusInput} type="password" className="h-11 bg-paper text-center sm:text-left" value={secret} onChange={(event) => setSecret(event.target.value)} onKeyDown={(event) => event.key === "Enter" && onUnlock(secret)} placeholder={t("auth.quickUnlockPlaceholder")} disabled={unlocking} />
    <Button className="h-11 px-4" disabled={!secret || unlocking} onClick={() => onUnlock(secret)}><KeyRound className="mr-2 h-4 w-4" />{unlocking ? t("auth.unlocking") : t("auth.quickUnlockAction")}</Button>
    {passkeyRegistered && <button type="button" className="sm:col-span-2 text-sm text-brand disabled:opacity-50" disabled={unlocking} onClick={onPasskeyUnlock}>{unlocking ? t("auth.invokingFaceId") : t("auth.switchToFaceId")}</button>}
  </div>;
}

function KeypadButton({ label, onClick, disabled }: { label: string; onClick: () => void; disabled?: boolean }) {
  return <button type="button" className="grid h-12 place-items-center rounded-md border border-line bg-paper text-xl font-medium text-ink active:bg-tag disabled:opacity-50" disabled={disabled} onClick={onClick}>{label === "删" ? <Delete className="h-4 w-4" /> : label}</button>;
}
