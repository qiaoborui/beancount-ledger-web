import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useTranslation } from "react-i18next";
import { Fingerprint, KeyRound, MoreHorizontal, Pencil, Plus, ShieldCheck, Trash2 } from "lucide-react";
import { AlertDialog, AlertDialogCancel, AlertDialogContent, AlertDialogDescription, AlertDialogFooter, AlertDialogHeader, AlertDialogTitle } from "@/components/ui/alert-dialog";
import { Button } from "@/components/ui/button";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { DropdownMenu, DropdownMenuContent, DropdownMenuItem, DropdownMenuTrigger } from "@/components/ui/dropdown-menu";
import { Input } from "@/components/ui/input";
import { apiEndpointLabel, apiEndpointSettingsChangeEvent, currentApiEndpoint, readApiEndpointSettings, type ApiEndpoint } from "@/lib/apiEndpoints";
import i18n from "@/i18n";
import { deletePasskeyCredential, listPasskeyCredentials, passkeyBackupPresentation, PasskeyManagementUnsupportedError, renamePasskeyCredential, type PasskeyCredentialSummary } from "./passkeys";

type ToastFn = (kind: "info" | "success" | "error", text: string) => void;

export function PasskeySettingsPanel({ onRegister, onRegisteredChange, showToast }: { onRegister: (endpoint: ApiEndpoint) => Promise<PasskeyCredentialSummary | null>; onRegisteredChange: (registered: boolean) => void; showToast: ToastFn }) {
  const { t } = useTranslation();
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
      const message = error instanceof Error ? error.message : i18n.t("passkeySettings.readFailed");
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
      showToast("error", t("passkeySettings.enterNameError"));
      return;
    }
    setSaving(true);
    try {
      const updated = await renamePasskeyCredential(endpoint, editing.id, name);
      if (operationGeneration !== endpointSettingsGeneration.current) return;
      setCredentials((current) => current.map((item) => item.id === updated.id ? updated : item));
      setEditing(null);
      showToast("success", t("passkeySettings.nameUpdated"));
    } catch (error) {
      showToast("error", error instanceof Error ? error.message : t("passkeySettings.renameFailed"));
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
      showToast("error", t("passkeySettings.enterPasswordError"));
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
      showToast("success", result.remaining > 0 ? t("passkeySettings.deleted") : t("passkeySettings.lastDeleted"));
    } catch (error) {
      showToast("error", error instanceof Error ? error.message : t("passkeySettings.deleteFailed"));
    } finally {
      setSaving(false);
    }
  }

  const deletingLast = deleting != null && credentials.length === 1;
  const empty = !loading && !loadError && !managementUnsupported && credentials.length === 0;

  return <section className="card p-5 md:p-6">
    <div className="flex flex-col gap-4 border-b border-line pb-4 sm:flex-row sm:items-start sm:justify-between">
      <div>
        <div className="text-xs font-semibold text-stone">{t("passkeySettings.eyebrow")}</div>
        <h1 className="mt-2 text-2xl font-semibold tracking-[-0.02em] text-ink">{t("passkeySettings.title")}</h1>
        <p className="mt-2 max-w-2xl text-sm leading-6 text-olive">{t("passkeySettings.desc", { backend: backendLabel })}</p>
      </div>
      <Button type="button" size="lg" className="h-11 w-full sm:w-auto" disabled={registering || loading || managementUnsupported || !endpoint} onClick={() => void register()}>
        <Plus className="h-4 w-4" />{registering ? t("passkeySettings.invokeSystem") : t("passkeySettings.add")}
      </Button>
    </div>

    <div className="mt-5 overflow-hidden rounded-xl border border-line bg-panel">
      {loading && <div className="flex min-h-32 items-center justify-center px-5 py-8 text-sm text-stone" role="status">{t("passkeySettings.loading")}</div>}
      {!loading && loadError && <div className="flex min-h-40 flex-col items-center justify-center px-6 py-8 text-center" role="alert">
        <h2 className="text-sm font-semibold text-ink">{t("passkeySettings.loadErrorTitle")}</h2>
        <p className="mt-2 max-w-md text-sm leading-6 text-stone">{loadError}</p>
        <Button type="button" variant="outline" className="mt-4" onClick={() => void loadCredentials()}>{t("passkeySettings.retry")}</Button>
      </div>}
      {!loading && managementUnsupported && <div className="flex min-h-40 flex-col items-center justify-center px-6 py-8 text-center" role="status">
        <h2 className="text-sm font-semibold text-ink">{t("passkeySettings.unsupportedTitle")}</h2>
        <p className="mt-2 max-w-md text-sm leading-6 text-stone">{t("passkeySettings.unsupportedDesc", { backend: backendLabel })}</p>
      </div>}
      {empty && <div className="flex min-h-48 flex-col items-center justify-center px-6 py-10 text-center">
        <span className="grid h-11 w-11 place-items-center rounded-lg border border-line bg-paper text-brand"><Fingerprint className="h-5 w-5" /></span>
        <h2 className="mt-4 text-base font-semibold text-ink">{t("passkeySettings.emptyTitle")}</h2>
        <p className="mt-2 max-w-md text-sm leading-6 text-stone">{t("passkeySettings.emptyDesc")}</p>
        <Button type="button" className="mt-5 h-10" disabled={registering} onClick={() => void register()}><Plus className="h-4 w-4" />{t("passkeySettings.addFirst")}</Button>
      </div>}
      {!loading && credentials.length > 0 && <div className="divide-y divide-line">
        {credentials.map((credential) => <PasskeyRow key={credential.id} credential={credential} onRename={() => beginRename(credential)} onDelete={() => beginDelete(credential)} />)}
      </div>}
    </div>

    <p className="mt-3 flex items-start gap-2 text-xs leading-5 text-stone"><ShieldCheck className="mt-0.5 h-3.5 w-3.5 shrink-0 text-brand" />{t("passkeySettings.footerHint")}</p>

    <Dialog open={editing != null} onOpenChange={(open) => !open && !saving && setEditing(null)}>
      <DialogContent className="border-line bg-panel text-ink sm:max-w-md">
        <DialogHeader>
          <DialogTitle>{t("passkeySettings.renameTitle")}</DialogTitle>
          <DialogDescription className="text-stone">{t("passkeySettings.renameDesc")}</DialogDescription>
        </DialogHeader>
        <Input autoFocus maxLength={64} value={editName} onChange={(event) => setEditName(event.target.value)} onKeyDown={(event) => event.key === "Enter" && void saveName()} aria-label={t("passkeySettings.nameLabel")} />
        <DialogFooter>
          <Button type="button" variant="outline" disabled={saving} onClick={() => setEditing(null)}>{t("passkeySettings.later")}</Button>
          <Button type="button" disabled={saving || !editName.trim()} onClick={() => void saveName()}>{saving ? t("passkeySettings.saving") : t("passkeySettings.saveName")}</Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>

    <AlertDialog open={deleting != null} onOpenChange={(open) => !open && !saving && setDeleting(null)}>
      <AlertDialogContent className="border-line bg-panel text-ink">
        <AlertDialogHeader>
          <AlertDialogTitle>{deletingLast ? t("passkeySettings.deleteLastTitle") : t("passkeySettings.deleteTitle")}</AlertDialogTitle>
          <AlertDialogDescription className="space-y-2 text-stone">
            <span className="block">{t("passkeySettings.deleteDesc", { name: deleting?.name ?? "" })}</span>
            {deletingLast && <span className="block font-medium text-[var(--danger)]">{t("passkeySettings.deleteLastWarning")}</span>}
          </AlertDialogDescription>
        </AlertDialogHeader>
        <div>
          <label htmlFor="delete-passkey-password" className="mb-2 block text-sm font-medium text-ink">{t("passkeySettings.confirmPasswordLabel")}</label>
          <Input id="delete-passkey-password" autoFocus type="password" autoComplete="current-password" value={password} onChange={(event) => setPassword(event.target.value)} onKeyDown={(event) => event.key === "Enter" && void confirmDelete()} />
        </div>
        <AlertDialogFooter>
          <AlertDialogCancel disabled={saving}>{t("passkeySettings.cancel")}</AlertDialogCancel>
          <Button type="button" variant="destructive" disabled={saving || !password} onClick={() => void confirmDelete()}>{saving ? t("passkeySettings.deleting") : t("passkeySettings.confirmDelete")}</Button>
        </AlertDialogFooter>
      </AlertDialogContent>
    </AlertDialog>
  </section>;
}

function PasskeyRow({ credential, onRename, onDelete }: { credential: PasskeyCredentialSummary; onRename: () => void; onDelete: () => void }) {
  const { t } = useTranslation();
  const backup = passkeyBackupPresentation(credential);
  const transport = useMemo(() => passkeyTransportLabel(credential.transports), [credential.transports]);
  return <div className="flex min-w-0 items-start gap-3 px-4 py-4 sm:items-center sm:px-5">
    <span className="mt-0.5 grid h-9 w-9 shrink-0 place-items-center rounded-lg border border-line bg-paper text-brand sm:mt-0"><KeyRound className="h-4 w-4" /></span>
    <div className="min-w-0 flex-1">
      <div className="flex flex-wrap items-center gap-2">
        <h2 className="min-w-0 truncate text-sm font-semibold text-ink" title={credential.name}>{credential.name}</h2>
        <span className="rounded-full bg-tag px-2 py-0.5 text-[11px] font-medium text-olive" title={backup.description}>{backup.label}</span>
      </div>
      <p className="mt-1 text-xs leading-5 text-stone">{lastUsedLabel(credential.lastUsedAt, t)} · {createdLabel(credential.createdAt, t)} · {transport}</p>
    </div>
    <DropdownMenu>
      <DropdownMenuTrigger asChild>
        <Button type="button" variant="ghost" size="icon-lg" className="h-11 w-11 shrink-0" aria-label={t("passkeySettings.manageLabel", { name: credential.name })}><MoreHorizontal className="h-4 w-4" /></Button>
      </DropdownMenuTrigger>
      <DropdownMenuContent align="end" className="border-line bg-panel text-ink">
        <DropdownMenuItem onSelect={onRename}><Pencil className="h-4 w-4" />{t("passkeySettings.rename")}</DropdownMenuItem>
        <DropdownMenuItem variant="destructive" onSelect={onDelete}><Trash2 className="h-4 w-4" />{t("passkeySettings.deletePasskey")}</DropdownMenuItem>
      </DropdownMenuContent>
    </DropdownMenu>
  </div>;
}

function activeBackendLabel() {
  return apiEndpointLabel(currentApiEndpoint(readApiEndpointSettings()));
}

function passkeyTransportLabel(transports?: string[]) {
  const values = new Set(transports ?? []);
  if (values.has("usb") || values.has("nfc")) return i18n.t("passkeySettings.transportSecurityKey");
  if (values.has("internal")) return i18n.t("passkeySettings.transportInternal");
  if (values.has("hybrid")) return i18n.t("passkeySettings.transportHybrid");
  return i18n.t("passkeySettings.transportUnknown");
}

function lastUsedLabel(value: string | undefined, t: (key: string, options?: Record<string, unknown>) => string) {
  return value ? t("passkeySettings.lastUsed", { date: formatPasskeyDate(value, true) }) : t("passkeySettings.neverUsed");
}

function createdLabel(value: string | undefined, t: (key: string, options?: Record<string, unknown>) => string) {
  return value ? t("passkeySettings.addedOn", { date: formatPasskeyDate(value, false) }) : t("passkeySettings.addedUnknown");
}

function formatPasskeyDate(value: string, includeTime: boolean) {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return i18n.t("passkeySettings.unknownTime");
  return new Intl.DateTimeFormat(i18n.language, includeTime ? { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit" } : { year: "numeric", month: "short", day: "numeric" }).format(date);
}
