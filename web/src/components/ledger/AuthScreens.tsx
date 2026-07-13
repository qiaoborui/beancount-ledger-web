import { useEffect, useRef, useState } from "react";
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

export function LoginScreen({ password, setPassword, passkeyRegistered, toastText, onLogin, onPasskeyLogin }: { password: string; setPassword: (value: string) => void; passkeyRegistered: boolean; toastText?: string; onLogin: () => void; onPasskeyLogin: () => void }) {
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
    setEndpointMessage("正在验证所选后端…");
    try {
      const result = await probeApiEndpoint(endpoint);
      const verified = applyApiEndpointProbe(endpointSettings, endpoint.id, result);
      const next = withActiveApiEndpoint(verified, endpoint.id);
      if (next.activeId !== endpoint.id) throw new Error("所选后端与当前账本不兼容");
      setEndpointMessage("已切换后端，请重新登录。");
      setEndpointSettings(next);
      writeApiEndpointSettings(next);
    } catch (error) {
      setEndpointMessage(error instanceof Error ? error.message : "切换后端失败");
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
        if (next.activeId !== existing.id) throw new Error("这个后端与当前账本不兼容");
        setEndpointMessage("这个后端已存在，已验证并切换。");
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
      setEndpointMessage("正在验证新后端…");
      const result = await probeApiEndpoint(endpoint);
      next = applyApiEndpointProbe(next, endpoint.id, result);
      setDraftEndpointUrl("");
      setEndpointMessage("已添加，正在连接新后端…");
      setEndpointSettings(next);
      writeApiEndpointSettings(next);
    } catch (error) {
      setEndpointMessage(error instanceof Error ? error.message : "添加后端失败");
    }
  }

  return <div className="grid min-h-dvh place-items-center bg-paper px-4 py-[max(1rem,env(safe-area-inset-top))] pb-[max(1rem,env(safe-area-inset-bottom))]">
    <div className="card w-full max-w-md p-7">
      <div className="mb-7 h-1 w-12 rounded-full bg-brand" />
      <h1 className="font-serif text-3xl font-medium">我的账本</h1>
      <p className="mt-2 text-sm leading-6 text-olive">私人财务札记。输入密码后再读取本地账本数据。</p>
      <div className="mt-5 rounded-2xl border border-line bg-panel p-3">
        <div className="flex items-start justify-between gap-3">
          <div className="min-w-0">
            <div className="text-xs text-stone">当前后端</div>
            <div className="mt-1 break-all text-sm font-medium text-ink">{activeEndpoint ? displayApiEndpointUrl(activeEndpoint) : "没有可用后端"}</div>
          </div>
          <button type="button" className="shrink-0 text-sm font-medium text-brand" onClick={() => setShowEndpointSettings((value) => !value)} aria-expanded={showEndpointSettings}>{showEndpointSettings ? "收起" : "切换后端"}</button>
        </div>
        {showEndpointSettings && <div className="mt-3 space-y-3 border-t border-line pt-3">
          <label className="block">
            <span className="mb-1.5 block text-xs text-stone">使用后端</span>
            <select className="h-11 w-full rounded-xl border border-line bg-paper px-3 text-sm text-ink" value={activeEndpoint?.id ?? ""} onChange={(event) => void selectEndpoint(event.target.value)}>
              {enabledEndpoints.map((endpoint) => <option key={endpoint.id} value={endpoint.id}>{isSameOriginApiEndpoint(endpoint) ? `当前站点 · ${displayApiEndpointUrl(endpoint)}` : endpoint.url}</option>)}
            </select>
          </label>
          <div className="grid gap-2 sm:grid-cols-[minmax(0,1fr)_auto]">
            <Input value={draftEndpointUrl} onChange={(event) => setDraftEndpointUrl(event.target.value)} onKeyDown={(event) => event.key === "Enter" && void addEndpoint()} placeholder="https://api.example.com" className="h-11 rounded-xl bg-paper" />
            <Button type="button" variant="outline" className="h-11 rounded-xl bg-paper" onClick={() => void addEndpoint()}>添加并切换</Button>
          </div>
          <p className="text-xs leading-5 text-stone">自定义后端必须使用 HTTPS，并允许当前站点跨域访问。多个后端应连接同一个账本。</p>
          {endpointMessage && <p className="text-xs text-stone">{endpointMessage}</p>}
        </div>}
      </div>
      <Input type="password" className="mt-6 h-12 rounded-xl bg-panel" value={password} onChange={(e) => setPassword(e.target.value)} onKeyDown={(e) => e.key === "Enter" && onLogin()} />
      <Button className="mt-4 h-12 w-full rounded-xl" onClick={onLogin}>密码登录</Button>
      {passkeyRegistered && <Button variant="outline" className="mt-3 h-12 w-full rounded-xl bg-paper text-warm" onClick={onPasskeyLogin}>使用 Face ID / Passkey 登录</Button>}
      {toastText && <p className="mt-3 whitespace-pre-wrap text-sm text-[var(--danger)]">{toastText}</p>}
    </div>
  </div>;
}

export function UnlockScreen({ message, onUnlock }: { message: string; onUnlock: () => void }) {
  return <div className="grid min-h-dvh place-items-center bg-brand px-4 py-[max(1rem,env(safe-area-inset-top))] pb-[max(1rem,env(safe-area-inset-bottom))] text-paper"><div className="kami-float w-full max-w-sm rounded-xl border border-paper/20 bg-paper p-6 text-center text-ink"><h1 className="font-serif text-3xl font-medium">账本已锁定</h1><p className="mt-3 text-sm text-olive">为保护余额和流水隐私，请先解锁敏感数据。</p><Button className="mt-6 h-12 w-full rounded-xl" onClick={onUnlock}>解锁</Button>{message && <p className="mt-3 whitespace-pre-wrap text-sm text-[var(--danger)]">{message}</p>}<p className="mt-4 text-xs text-stone">短暂切换 App 不会锁定；后台超过 5 分钟或重新打开后会锁定。</p></div></div>;
}

export function SensitiveUnlockPanel({
  title = "资产信息已隐藏",
  description = "净资产和账户余额需要确认是你本人后查看。普通记账、流水和损益分析可以直接使用。",
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
  unlocking,
  autoFocusInput,
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
  unlocking?: boolean;
  autoFocusInput?: boolean;
}) {
  const offlineInputRef = useRef<HTMLInputElement | null>(null);
  useEffect(() => {
    if (!autoFocusInput || !offline || !offlineUnlockAvailable) return;
    const id = window.requestAnimationFrame(() => offlineInputRef.current?.focus());
    return () => window.cancelAnimationFrame(id);
  }, [autoFocusInput, offline, offlineUnlockAvailable]);

  return <section className="card p-6 text-center">
    <div className="mx-auto mb-4 h-1 w-12 rounded-full bg-brand" />
    <h2 className="font-serif text-2xl font-medium">{title}</h2>
    <p className="mx-auto mt-3 max-w-xl text-sm leading-6 text-olive">{description}</p>
    {offline && offlineUnlockAvailable ? (
      <div className="mx-auto mt-5 flex max-w-sm flex-col gap-3">
        <Input ref={offlineInputRef} autoFocus={autoFocusInput} type="password" className="h-12 rounded-xl bg-panel text-center" value={offlineSecret ?? ""} onChange={(event) => onOfflineSecretChange?.(event.target.value)} onKeyDown={(event) => event.key === "Enter" && onOfflineUnlock?.()} placeholder="离线解锁码" />
        <Button className="h-12 rounded-xl px-5" onClick={onOfflineUnlock}>离线解锁</Button>
      </div>
    ) : quickUnlockEnabled ? (
      <QuickUnlockControls mode={quickUnlockMode ?? "text"} onUnlock={onQuickUnlock ?? onUnlock} passkeyRegistered={passkeyRegistered} onPasskeyUnlock={onUnlock} unlocking={unlocking} autoFocusInput={autoFocusInput} />
    ) : (
      <div className="mx-auto mt-5 flex max-w-sm flex-col gap-3">
        {passkeyRegistered && <Button className="h-12 rounded-xl px-5" onClick={onUnlock}>使用 Face ID / Passkey 查看</Button>}
        {!passkeyRegistered && <p className="text-sm leading-6 text-stone">当前设备还没有可用的快速解锁方式。用主密码登录并查看一次敏感数据后，可以在设置里启用本机快速解锁。</p>}
      </div>
    )}
    {offline && !offlineUnlockAvailable && <p className="mx-auto mt-3 max-w-xl text-sm text-stone">当前离线；需要先在线解锁并在设置里启用离线解锁码。</p>}
    {message && <p className="mt-3 whitespace-pre-wrap text-sm text-[var(--danger)]">{message}</p>}
    <p className="mt-4 text-xs text-stone">解锁后 15 分钟内可查看余额和净资产；重新打开仍可先直接聊天。</p>
  </section>;
}

export function PasskeyBanner({ onRegister }: { onRegister: () => void }) {
  return <section className="card mb-6 flex flex-col gap-3 p-5 sm:flex-row sm:items-center sm:justify-between"><div><h2 className="font-serif text-xl font-medium">启用 Face ID / Passkey</h2><p className="mt-1 text-sm text-olive">添加到桌面后，可用系统 Face ID、Touch ID 或设备密码解锁账页。</p></div><Button className="h-12 rounded-xl px-5" onClick={onRegister}>启用</Button></section>;
}

function QuickUnlockControls({ mode, passkeyRegistered, onUnlock, onPasskeyUnlock, unlocking, autoFocusInput }: { mode: QuickUnlockMode; passkeyRegistered?: boolean; onUnlock: (secret: string) => void; onPasskeyUnlock: () => void; unlocking?: boolean; autoFocusInput?: boolean }) {
  const [secret, setSecret] = useState("");
  const inputRef = useRef<HTMLInputElement | null>(null);
  useEffect(() => {
    if (!autoFocusInput || mode !== "text") return;
    const id = window.requestAnimationFrame(() => inputRef.current?.focus());
    return () => window.cancelAnimationFrame(id);
  }, [autoFocusInput, mode]);

  if (mode === "numeric") {
    return <div className="mx-auto mt-5 w-full max-w-xs">
      <div className="mb-3 h-12 rounded-xl border border-line bg-panel px-4 text-center text-2xl tracking-[0.35em] text-ink" aria-label="本机数字解锁码">{secret ? "•".repeat(Math.min(secret.length, 8)) : ""}</div>
      <div className="grid grid-cols-3 gap-2">
        {["1", "2", "3", "4", "5", "6", "7", "8", "9"].map((digit) => <KeypadButton key={digit} label={digit} onClick={() => setSecret(secret + digit)} disabled={unlocking} />)}
        <KeypadButton label="删" onClick={() => setSecret(secret.slice(0, -1))} disabled={unlocking} />
        <KeypadButton label="0" onClick={() => setSecret(secret + "0")} disabled={unlocking} />
        <button type="button" className="h-14 rounded-xl bg-brand text-sm font-medium text-paper disabled:opacity-50" disabled={!secret || unlocking} onClick={() => onUnlock(secret)}>{unlocking ? "解锁中…" : "解锁"}</button>
      </div>
      {passkeyRegistered && <button type="button" className="mt-3 text-sm text-brand disabled:opacity-50" disabled={unlocking} onClick={onPasskeyUnlock}>改用 Face ID / Passkey</button>}
    </div>;
  }
  return <div className="mx-auto mt-5 flex max-w-sm flex-col gap-3">
    <Input ref={inputRef} autoFocus={autoFocusInput} type="password" className="h-12 rounded-xl bg-panel text-center" value={secret} onChange={(event) => setSecret(event.target.value)} onKeyDown={(event) => event.key === "Enter" && onUnlock(secret)} placeholder="本机快速解锁口令" disabled={unlocking} />
    <Button className="h-12 rounded-xl px-5" disabled={!secret || unlocking} onClick={() => onUnlock(secret)}>{unlocking ? "解锁中…" : "快速解锁"}</Button>
    {passkeyRegistered && <Button variant="outline" className="h-12 rounded-xl bg-paper text-warm" disabled={unlocking} onClick={onPasskeyUnlock}>改用 Face ID / Passkey</Button>}
  </div>;
}

function KeypadButton({ label, onClick, disabled }: { label: string; onClick: () => void; disabled?: boolean }) {
  return <button type="button" className="h-14 rounded-xl border border-line bg-panel text-xl font-medium text-ink active:bg-tag disabled:opacity-50" disabled={disabled} onClick={onClick}>{label}</button>;
}
