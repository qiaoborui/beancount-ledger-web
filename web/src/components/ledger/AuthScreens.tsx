import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";

export function AppSkeleton() {
  return <div className="min-h-dvh bg-paper p-6"><div className="mx-auto max-w-4xl animate-pulse space-y-6"><div className="h-12 rounded-2xl bg-line" /><div className="grid grid-cols-3 gap-3"><div className="h-24 rounded-2xl bg-line" /><div className="h-24 rounded-2xl bg-line" /><div className="h-24 rounded-2xl bg-line" /></div><div className="h-72 rounded-2xl bg-line" /></div></div>;
}

export function LoginScreen({ password, setPassword, passkeyRegistered, toastText, onLogin, onPasskeyLogin }: { password: string; setPassword: (value: string) => void; passkeyRegistered: boolean; toastText?: string; onLogin: () => void; onPasskeyLogin: () => void }) {
  return <div className="grid min-h-dvh place-items-center bg-paper px-4 py-[max(1rem,env(safe-area-inset-top))] pb-[max(1rem,env(safe-area-inset-bottom))]">
    <div className="card w-full max-w-sm p-7">
      <div className="mb-7 h-1 w-12 rounded-full bg-brand" />
      <h1 className="font-serif text-3xl font-medium">我的账本</h1>
      <p className="mt-2 text-sm leading-6 text-olive">私人财务札记。输入密码后再读取本地账本数据。</p>
      <Input type="password" className="mt-6 h-12 rounded-xl bg-panel" value={password} onChange={(e) => setPassword(e.target.value)} onKeyDown={(e) => e.key === "Enter" && onLogin()} />
      <Button className="mt-4 h-12 w-full rounded-xl" onClick={onLogin}>密码登录</Button>
      {passkeyRegistered && <Button variant="outline" className="mt-3 h-12 w-full rounded-xl bg-paper text-warm" onClick={onPasskeyLogin}>使用 Face ID / Passkey 登录</Button>}
      {toastText && <p className="mt-3 whitespace-pre-wrap text-sm text-[var(--danger)]">{toastText}</p>}
    </div>
  </div>;
}

export function UnlockScreen({ message, onUnlock }: { message: string; onUnlock: () => void }) {
  return <div className="grid min-h-dvh place-items-center bg-brand px-4 py-[max(1rem,env(safe-area-inset-top))] pb-[max(1rem,env(safe-area-inset-bottom))] text-paper"><div className="kami-float w-full max-w-sm rounded-xl border border-paper/20 bg-paper p-6 text-center text-ink"><h1 className="font-serif text-3xl font-medium">账本已锁定</h1><p className="mt-3 text-sm text-olive">为保护余额和流水隐私，请用 Face ID / Passkey 解锁。</p><Button className="mt-6 h-12 w-full rounded-xl" onClick={onUnlock}>使用 Face ID 解锁</Button>{message && <p className="mt-3 whitespace-pre-wrap text-sm text-[var(--danger)]">{message}</p>}<p className="mt-4 text-xs text-stone">短暂切换 App 不会锁定；后台超过 5 分钟或重新打开后会锁定。</p></div></div>;
}

export function SensitiveUnlockPanel({ title = "资产信息已隐藏", description = "净资产和账户余额需要确认是你本人后查看。普通记账、流水和损益分析可以直接使用。", message, offline, offlineUnlockAvailable, offlineSecret, onOfflineSecretChange, onOfflineUnlock, onUnlock }: { title?: string; description?: string; message?: string; offline?: boolean; offlineUnlockAvailable?: boolean; offlineSecret?: string; onOfflineSecretChange?: (value: string) => void; onOfflineUnlock?: () => void; onUnlock: () => void }) {
  return <section className="card p-6 text-center"><div className="mx-auto mb-4 h-1 w-12 rounded-full bg-brand" /><h2 className="font-serif text-2xl font-medium">{title}</h2><p className="mx-auto mt-3 max-w-xl text-sm leading-6 text-olive">{description}</p>{offline && offlineUnlockAvailable ? <div className="mx-auto mt-5 flex max-w-sm flex-col gap-3"><Input type="password" className="h-12 rounded-xl bg-panel text-center" value={offlineSecret ?? ""} onChange={(event) => onOfflineSecretChange?.(event.target.value)} onKeyDown={(event) => event.key === "Enter" && onOfflineUnlock?.()} placeholder="离线解锁码" /><Button className="h-12 rounded-xl px-5" onClick={onOfflineUnlock}>离线解锁</Button></div> : <Button className="mt-5 h-12 rounded-xl px-5" onClick={onUnlock}>使用 Face ID / Passkey 查看</Button>}{offline && !offlineUnlockAvailable && <p className="mx-auto mt-3 max-w-xl text-sm text-stone">当前离线；需要先在线解锁并在设置里启用离线解锁码。</p>}{message && <p className="mt-3 whitespace-pre-wrap text-sm text-[var(--danger)]">{message}</p>}<p className="mt-4 text-xs text-stone">解锁后 15 分钟内可查看余额和净资产；重新打开仍可先直接聊天。</p></section>;
}

export function PasskeyBanner({ onRegister }: { onRegister: () => void }) {
  return <section className="card mb-6 flex flex-col gap-3 p-5 sm:flex-row sm:items-center sm:justify-between"><div><h2 className="font-serif text-xl font-medium">启用 Face ID / Passkey</h2><p className="mt-1 text-sm text-olive">添加到桌面后，可用系统 Face ID、Touch ID 或设备密码解锁账页。</p></div><Button className="h-12 rounded-xl px-5" onClick={onRegister}>启用</Button></section>;
}
