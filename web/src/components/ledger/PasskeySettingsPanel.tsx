import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { Fingerprint, KeyRound, MoreHorizontal, Pencil, Plus, ShieldCheck, Trash2 } from "lucide-react";
import { AlertDialog, AlertDialogCancel, AlertDialogContent, AlertDialogDescription, AlertDialogFooter, AlertDialogHeader, AlertDialogTitle } from "@/components/ui/alert-dialog";
import { Button } from "@/components/ui/button";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { DropdownMenu, DropdownMenuContent, DropdownMenuItem, DropdownMenuTrigger } from "@/components/ui/dropdown-menu";
import { Input } from "@/components/ui/input";
import { apiEndpointLabel, apiEndpointSettingsChangeEvent, currentApiEndpoint, readApiEndpointSettings, type ApiEndpoint } from "@/lib/apiEndpoints";
import { deletePasskeyCredential, listPasskeyCredentials, passkeyBackupPresentation, PasskeyManagementUnsupportedError, renamePasskeyCredential, type PasskeyCredentialSummary } from "./passkeys";

type ToastFn = (kind: "info" | "success" | "error", text: string) => void;

export function PasskeySettingsPanel({ onRegister, onRegisteredChange, showToast }: { onRegister: (endpoint: ApiEndpoint) => Promise<PasskeyCredentialSummary | null>; onRegisteredChange: (registered: boolean) => void; showToast: ToastFn }) {
  const [credentials, setCredentials] = useState<PasskeyCredentialSummary[]>([]);
  const [loading, setLoading] = useState(true);
  const [loadError, setLoadError] = useState("");
  const [registering, setRegistering] = useState(false);
  const [editing, setEditing] = useState<PasskeyCredentialSummary | null>(null);
  const [editName, setEditName] = useState("");
  const [deleting, setDeleting] = useState<PasskeyCredentialSummary | null>(null);
  const [password, setPassword] = useState("");
  const [saving, setSaving] = useState(false);
  const [backendLabel, setBackendLabel] = useState(() => activeBackendLabel());
  const [endpoint, setEndpoint] = useState<ApiEndpoint | null>(null);
  const [managementUnsupported, setManagementUnsupported] = useState(false);
  const loadGeneration = useRef(0);
  const endpointSettingsGeneration = useRef(0);

  const loadCredentials = useCallback(async (requestedEndpoint?: ApiEndpoint) => {
    const generation = ++loadGeneration.current;
    setLoading(true);
    setLoadError("");
    setManagementUnsupported(false);
    try {
      const result = await listPasskeyCredentials(requestedEndpoint);
      if (generation !== loadGeneration.current) return;
      setEndpoint(result.endpoint);
      setBackendLabel(apiEndpointLabel(result.endpoint));
      setCredentials(result.credentials);
      onRegisteredChange(result.credentials.length > 0);
    } catch (error) {
      if (generation !== loadGeneration.current) return;
      if (error instanceof PasskeyManagementUnsupportedError) {
        setEndpoint(error.endpoint);
        setBackendLabel(apiEndpointLabel(error.endpoint));
        setCredentials([]);
        setManagementUnsupported(true);
        return;
      }
      const message = error instanceof Error ? error.message : "读取 Passkey 失败";
      setCredentials([]);
      setLoadError(message);
      showToast("error", message);
    } finally {
      if (generation === loadGeneration.current) setLoading(false);
    }
  }, [onRegisteredChange, showToast]);

  useEffect(() => {
    void loadCredentials();
    const handleEndpointChange = () => {
      endpointSettingsGeneration.current += 1;
      loadGeneration.current += 1;
      setBackendLabel(activeBackendLabel());
      setEndpoint(null);
      setCredentials([]);
      setLoadError("");
      setManagementUnsupported(false);
      setEditing(null);
      setDeleting(null);
      setPassword("");
      setSaving(false);
      void loadCredentials();
    };
    window.addEventListener(apiEndpointSettingsChangeEvent, handleEndpointChange);
    return () => window.removeEventListener(apiEndpointSettingsChangeEvent, handleEndpointChange);
  }, [loadCredentials]);

  async function register() {
    if (registering || !endpoint || managementUnsupported) return;
    const operationGeneration = endpointSettingsGeneration.current;
    const operationEndpoint = endpoint;
    setRegistering(true);
    try {
      const credential = await onRegister(operationEndpoint);
      if (operationGeneration !== endpointSettingsGeneration.current) return;
      await loadCredentials(operationEndpoint);
      if (credential && operationGeneration === endpointSettingsGeneration.current) {
        setEditing(credential);
        setEditName(credential.name);
      }
    } finally {
      setRegistering(false);
    }
  }

  function beginRename(credential: PasskeyCredentialSummary) {
    setEditing(credential);
    setEditName(credential.name);
  }

  async function saveName() {
    if (!editing || !endpoint || saving) return;
    const operationGeneration = endpointSettingsGeneration.current;
    const name = editName.trim();
    if (!name) {
      showToast("error", "请输入 Passkey 名称");
      return;
    }
    setSaving(true);
    try {
      const updated = await renamePasskeyCredential(endpoint, editing.id, name);
      if (operationGeneration !== endpointSettingsGeneration.current) return;
      setCredentials((current) => current.map((item) => item.id === updated.id ? updated : item));
      setEditing(null);
      showToast("success", "Passkey 名称已更新");
    } catch (error) {
      showToast("error", error instanceof Error ? error.message : "重命名 Passkey 失败");
    } finally {
      setSaving(false);
    }
  }

  function beginDelete(credential: PasskeyCredentialSummary) {
    setDeleting(credential);
    setPassword("");
  }

  async function confirmDelete() {
    if (!deleting || !endpoint || saving) return;
    if (!password) {
      showToast("error", "请输入主密码确认删除");
      return;
    }
    setSaving(true);
    const operationGeneration = endpointSettingsGeneration.current;
    try {
      const result = await deletePasskeyCredential(endpoint, deleting.id, password);
      if (operationGeneration !== endpointSettingsGeneration.current) return;
      setCredentials((current) => current.filter((item) => item.id !== deleting.id));
      onRegisteredChange(result.remaining > 0);
      setDeleting(null);
      setPassword("");
      showToast("success", result.remaining > 0 ? "Passkey 已删除" : "最后一个 Passkey 已删除，之后请使用主密码登录");
    } catch (error) {
      showToast("error", error instanceof Error ? error.message : "删除 Passkey 失败");
    } finally {
      setSaving(false);
    }
  }

  const deletingLast = deleting != null && credentials.length === 1;
  const empty = !loading && !loadError && !managementUnsupported && credentials.length === 0;

  return <section className="card p-5 md:p-6">
    <div className="flex flex-col gap-4 border-b border-line pb-4 sm:flex-row sm:items-start sm:justify-between">
      <div>
        <div className="text-xs font-semibold text-stone">安全与解锁</div>
        <h1 className="mt-2 text-2xl font-semibold tracking-[-0.02em] text-ink">Passkey</h1>
        <p className="mt-2 max-w-2xl text-sm leading-6 text-olive">管理用于登录和解锁敏感数据的凭据。这里显示的是当前后端“{backendLabel}”保存的 Passkey。</p>
      </div>
      <Button type="button" size="lg" className="h-11 w-full sm:w-auto" disabled={registering || loading || managementUnsupported || !endpoint} onClick={() => void register()}>
        <Plus className="h-4 w-4" />{registering ? "正在唤起系统…" : "添加 Passkey"}
      </Button>
    </div>

    <div className="mt-5 overflow-hidden rounded-xl border border-line bg-panel">
      {loading && <div className="flex min-h-32 items-center justify-center px-5 py-8 text-sm text-stone" role="status">正在读取 Passkey…</div>}
      {!loading && loadError && <div className="flex min-h-40 flex-col items-center justify-center px-6 py-8 text-center" role="alert">
        <h2 className="text-sm font-semibold text-ink">暂时无法读取 Passkey</h2>
        <p className="mt-2 max-w-md text-sm leading-6 text-stone">{loadError}</p>
        <Button type="button" variant="outline" className="mt-4" onClick={() => void loadCredentials()}>重试</Button>
      </div>}
      {!loading && managementUnsupported && <div className="flex min-h-40 flex-col items-center justify-center px-6 py-8 text-center" role="status">
        <h2 className="text-sm font-semibold text-ink">当前后端暂不支持 Passkey 管理</h2>
        <p className="mt-2 max-w-md text-sm leading-6 text-stone">升级“{backendLabel}”后，即可查看、重命名和删除多个 Passkey。已有 Passkey 仍可正常登录。</p>
      </div>}
      {empty && <div className="flex min-h-48 flex-col items-center justify-center px-6 py-10 text-center">
        <span className="grid h-11 w-11 place-items-center rounded-lg border border-line bg-paper text-brand"><Fingerprint className="h-5 w-5" /></span>
        <h2 className="mt-4 text-base font-semibold text-ink">还没有 Passkey</h2>
        <p className="mt-2 max-w-md text-sm leading-6 text-stone">添加后可使用 Face ID、Touch ID、设备密码或安全密钥登录。同步密码管理器中的同一个 Passkey 不需要在每台设备重复添加。</p>
        <Button type="button" className="mt-5 h-10" disabled={registering} onClick={() => void register()}><Plus className="h-4 w-4" />添加第一个 Passkey</Button>
      </div>}
      {!loading && credentials.length > 0 && <div className="divide-y divide-line">
        {credentials.map((credential) => <PasskeyRow key={credential.id} credential={credential} onRename={() => beginRename(credential)} onDelete={() => beginDelete(credential)} />)}
      </div>}
    </div>

    <p className="mt-3 flex items-start gap-2 text-xs leading-5 text-stone"><ShieldCheck className="mt-0.5 h-3.5 w-3.5 shrink-0 text-brand" />删除只会让 Ledger 停止接受该凭据，不会删除 iCloud 钥匙串、Google 密码管理器或安全密钥里的副本。</p>

    <Dialog open={editing != null} onOpenChange={(open) => !open && !saving && setEditing(null)}>
      <DialogContent className="border-line bg-panel text-ink sm:max-w-md">
        <DialogHeader>
          <DialogTitle>命名 Passkey</DialogTitle>
          <DialogDescription className="text-stone">使用容易识别的名称，例如“MacBook Touch ID”或“备用安全密钥”。</DialogDescription>
        </DialogHeader>
        <Input autoFocus maxLength={64} value={editName} onChange={(event) => setEditName(event.target.value)} onKeyDown={(event) => event.key === "Enter" && void saveName()} aria-label="Passkey 名称" />
        <DialogFooter>
          <Button type="button" variant="outline" disabled={saving} onClick={() => setEditing(null)}>稍后再说</Button>
          <Button type="button" disabled={saving || !editName.trim()} onClick={() => void saveName()}>{saving ? "保存中…" : "保存名称"}</Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>

    <AlertDialog open={deleting != null} onOpenChange={(open) => !open && !saving && setDeleting(null)}>
      <AlertDialogContent className="border-line bg-panel text-ink">
        <AlertDialogHeader>
          <AlertDialogTitle>{deletingLast ? "删除最后一个 Passkey？" : "删除这个 Passkey？"}</AlertDialogTitle>
          <AlertDialogDescription className="space-y-2 text-stone">
            <span className="block">即将删除“{deleting?.name}”。此操作不会删除系统密码管理器中的副本。</span>
            {deletingLast && <span className="block font-medium text-[var(--danger)]">删除后将无法使用 Passkey 登录或解锁，请确认主密码仍然可用。</span>}
          </AlertDialogDescription>
        </AlertDialogHeader>
        <div>
          <label htmlFor="delete-passkey-password" className="mb-2 block text-sm font-medium text-ink">输入主密码确认</label>
          <Input id="delete-passkey-password" autoFocus type="password" autoComplete="current-password" value={password} onChange={(event) => setPassword(event.target.value)} onKeyDown={(event) => event.key === "Enter" && void confirmDelete()} />
        </div>
        <AlertDialogFooter>
          <AlertDialogCancel disabled={saving}>取消</AlertDialogCancel>
          <Button type="button" variant="destructive" disabled={saving || !password} onClick={() => void confirmDelete()}>{saving ? "删除中…" : "确认删除"}</Button>
        </AlertDialogFooter>
      </AlertDialogContent>
    </AlertDialog>
  </section>;
}

function PasskeyRow({ credential, onRename, onDelete }: { credential: PasskeyCredentialSummary; onRename: () => void; onDelete: () => void }) {
  const backup = passkeyBackupPresentation(credential);
  const transport = useMemo(() => passkeyTransportLabel(credential.transports), [credential.transports]);
  return <div className="flex min-w-0 items-start gap-3 px-4 py-4 sm:items-center sm:px-5">
    <span className="mt-0.5 grid h-9 w-9 shrink-0 place-items-center rounded-lg border border-line bg-paper text-brand sm:mt-0"><KeyRound className="h-4 w-4" /></span>
    <div className="min-w-0 flex-1">
      <div className="flex flex-wrap items-center gap-2">
        <h2 className="min-w-0 truncate text-sm font-semibold text-ink" title={credential.name}>{credential.name}</h2>
        <span className="rounded-full bg-tag px-2 py-0.5 text-[11px] font-medium text-olive" title={backup.description}>{backup.label}</span>
      </div>
      <p className="mt-1 text-xs leading-5 text-stone">{lastUsedLabel(credential.lastUsedAt)} · {createdLabel(credential.createdAt)} · {transport}</p>
    </div>
    <DropdownMenu>
      <DropdownMenuTrigger asChild>
        <Button type="button" variant="ghost" size="icon-lg" className="h-11 w-11 shrink-0" aria-label={`管理 ${credential.name}`}><MoreHorizontal className="h-4 w-4" /></Button>
      </DropdownMenuTrigger>
      <DropdownMenuContent align="end" className="border-line bg-panel text-ink">
        <DropdownMenuItem onSelect={onRename}><Pencil className="h-4 w-4" />重命名</DropdownMenuItem>
        <DropdownMenuItem variant="destructive" onSelect={onDelete}><Trash2 className="h-4 w-4" />删除 Passkey</DropdownMenuItem>
      </DropdownMenuContent>
    </DropdownMenu>
  </div>;
}

function activeBackendLabel() {
  return apiEndpointLabel(currentApiEndpoint(readApiEndpointSettings()));
}

function passkeyTransportLabel(transports?: string[]) {
  const values = new Set(transports ?? []);
  if (values.has("usb") || values.has("nfc")) return "安全密钥";
  if (values.has("internal")) return "内建验证器";
  if (values.has("hybrid")) return "跨设备验证";
  return "验证方式未知";
}

function lastUsedLabel(value?: string) {
  return value ? `最近使用 ${formatPasskeyDate(value, true)}` : "尚未使用";
}

function createdLabel(value?: string) {
  return value ? `添加于 ${formatPasskeyDate(value, false)}` : "添加时间未知";
}

function formatPasskeyDate(value: string, includeTime: boolean) {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "时间未知";
  return new Intl.DateTimeFormat("zh-CN", includeTime ? { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit" } : { year: "numeric", month: "short", day: "numeric" }).format(date);
}
