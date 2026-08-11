import { useCallback, useEffect, useRef, useState } from "react";
import { useTranslation } from "react-i18next";
import { Ban, Check, Copy, KeyRound, Plus, ShieldCheck } from "lucide-react";
import { AlertDialog, AlertDialogCancel, AlertDialogContent, AlertDialogDescription, AlertDialogFooter, AlertDialogHeader, AlertDialogTitle } from "@/components/ui/alert-dialog";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { apiEndpointSettingsChangeEvent } from "@/lib/apiEndpoints";
import i18n from "@/i18n";
import { AgentAccessTokenManagementUnsupportedError, createAgentAccessToken, listAgentAccessTokens, revokeAgentAccessToken, type AgentAccessTokenSummary } from "./agentAccessTokens";

type ToastFn = (kind: "info" | "success" | "error", text: string) => void;

export class AgentTokenOperationGate {
  private generation = 0;

  capture() {
    return this.generation;
  }

  invalidate() {
    this.generation += 1;
  }

  isCurrent(generation: number) {
    return generation === this.generation;
  }
}

export function AgentAccessTokenSettings({ headingId, sensitiveUnlocked, showToast }: { headingId?: string; sensitiveUnlocked: boolean; showToast: ToastFn }) {
  const { t } = useTranslation();
  const [tokens, setTokens] = useState<AgentAccessTokenSummary[]>([]);
  const [name, setName] = useState("");
  const [allowWrite, setAllowWrite] = useState(false);
  const [createdToken, setCreatedToken] = useState("");
  const [copied, setCopied] = useState(false);
  const [loading, setLoading] = useState(false);
  const [creating, setCreating] = useState(false);
  const [revoking, setRevoking] = useState<AgentAccessTokenSummary | null>(null);
  const [saving, setSaving] = useState(false);
  const [loadError, setLoadError] = useState("");
  const [unsupported, setUnsupported] = useState(false);
  const operationGate = useRef(new AgentTokenOperationGate());

  const load = useCallback(async () => {
    if (!sensitiveUnlocked) return;
    operationGate.current.invalidate();
    const current = operationGate.current.capture();
    setLoading(true);
    setLoadError("");
    setUnsupported(false);
    try {
      const next = await listAgentAccessTokens();
      if (operationGate.current.isCurrent(current)) setTokens(next);
    } catch (error) {
      if (!operationGate.current.isCurrent(current)) return;
      if (error instanceof AgentAccessTokenManagementUnsupportedError) {
        setUnsupported(true);
        setTokens([]);
      } else {
        const message = error instanceof Error ? error.message : i18n.t("agentTokensSettings.loadFailed");
        setLoadError(message);
        showToast("error", message);
      }
    } finally {
      if (operationGate.current.isCurrent(current)) setLoading(false);
    }
  }, [sensitiveUnlocked, showToast]);

  useEffect(() => {
    if (!sensitiveUnlocked) {
      operationGate.current.invalidate();
      setTokens([]);
      setCreatedToken("");
      setAllowWrite(false);
      setLoading(false);
      setCreating(false);
      setSaving(false);
      setRevoking(null);
      setLoadError("");
      return;
    }
    void load();
    const handleEndpointChange = () => {
      operationGate.current.invalidate();
      setTokens([]);
      setCreatedToken("");
      setAllowWrite(false);
      setCreating(false);
      setSaving(false);
      setRevoking(null);
      void load();
    };
    window.addEventListener(apiEndpointSettingsChangeEvent, handleEndpointChange);
    return () => {
      operationGate.current.invalidate();
      window.removeEventListener(apiEndpointSettingsChangeEvent, handleEndpointChange);
    };
  }, [load, sensitiveUnlocked]);

  async function create() {
    const trimmed = name.trim();
    if (!trimmed) {
      showToast("error", t("agentTokensSettings.createEmptyName"));
      return;
    }
    if (trimmed.length > 64) {
      showToast("error", t("agentTokensSettings.createNameTooLong"));
      return;
    }
    const current = operationGate.current.capture();
    setCreating(true);
    setCreatedToken("");
    try {
      const result = await createAgentAccessToken(trimmed, allowWrite ? ["read", "write"] : ["read"]);
      if (!operationGate.current.isCurrent(current)) return;
      setTokens((current) => [result.credential, ...current]);
      setCreatedToken(result.token);
      setCopied(false);
      setName("");
      setAllowWrite(false);
      showToast("success", t("agentTokensSettings.created"));
    } catch (error) {
      if (!operationGate.current.isCurrent(current)) return;
      showToast("error", error instanceof Error ? error.message : t("agentTokensSettings.createFailed"));
    } finally {
      if (operationGate.current.isCurrent(current)) setCreating(false);
    }
  }

  async function copyToken() {
    if (!createdToken) return;
    try {
      await navigator.clipboard.writeText(createdToken);
      setCopied(true);
      showToast("success", t("agentTokensSettings.copiedToast"));
    } catch {
      showToast("error", t("agentTokensSettings.copyDenied"));
    }
  }

  async function confirmRevoke() {
    if (!revoking || saving) return;
    const current = operationGate.current.capture();
    const tokenID = revoking.id;
    setSaving(true);
    try {
      await revokeAgentAccessToken(tokenID);
      if (!operationGate.current.isCurrent(current)) return;
      const revokedAt = new Date().toISOString();
      setTokens((tokens) => tokens.map((token) => token.id === tokenID ? { ...token, revokedAt } : token));
      setRevoking(null);
      showToast("success", t("agentTokensSettings.revoked"));
    } catch (error) {
      if (!operationGate.current.isCurrent(current)) return;
      showToast("error", error instanceof Error ? error.message : t("agentTokensSettings.revokeFailed"));
    } finally {
      if (operationGate.current.isCurrent(current)) setSaving(false);
    }
  }

  return <section className="min-w-0 bg-panel px-4 py-5 sm:px-6 sm:py-6 lg:px-8 lg:py-7">
    <div className="flex flex-col gap-4 border-b border-line pb-4 lg:flex-row lg:items-start lg:justify-between">
      <div className="min-w-0">
        <h1 id={headingId} className="text-2xl font-semibold tracking-[-0.02em] text-ink">{t("agentTokensSettings.title")}</h1>
        <p className="mt-2 max-w-2xl text-sm leading-6 text-olive">{t("agentTokensSettings.desc")}</p>
      </div>
      <div className="w-full space-y-2 lg:w-auto lg:min-w-80">
        <div className="flex gap-2">
          <Input aria-label={t("agentTokensSettings.tokenNameLabel")} maxLength={64} value={name} onChange={(event) => setName(event.target.value)} onKeyDown={(event) => event.key === "Enter" && void create()} placeholder={t("agentTokensSettings.tokenNamePlaceholder")} disabled={!sensitiveUnlocked || creating || unsupported} />
          <Button type="button" className="h-10 shrink-0" disabled={!sensitiveUnlocked || creating || unsupported || !name.trim()} onClick={() => void create()}><Plus className="h-4 w-4" />{creating ? t("agentTokensSettings.creating") : t("agentTokensSettings.create")}</Button>
        </div>
        <label className="flex min-h-10 cursor-pointer items-start gap-2 rounded-md bg-paper px-3 py-2 text-xs leading-5 text-olive">
          <input aria-label={t("agentTokensSettings.allowWriteLabel")} type="checkbox" className="mt-1 accent-[var(--brand)]" checked={allowWrite} onChange={(event) => setAllowWrite(event.target.checked)} disabled={!sensitiveUnlocked || creating || unsupported} />
          <span><span className="font-medium text-ink">{t("agentTokensSettings.allowWriteLabel")}</span>{t("agentTokensSettings.allowWriteDesc")}</span>
        </label>
      </div>
    </div>

    {!sensitiveUnlocked && <div className="mt-5 rounded-xl bg-tag px-4 py-3 text-sm leading-6 text-stone">{t("agentTokensSettings.lockedHint")}</div>}

    {sensitiveUnlocked && createdToken && <div className="mt-5 rounded-xl border border-brand/35 bg-[var(--selected-bg)] p-4" role="status">
      <div className="flex items-start gap-3">
        <span className="grid size-10 shrink-0 place-items-center rounded-md bg-brand text-paper"><KeyRound className="h-4 w-4" /></span>
        <div className="min-w-0 flex-1">
          <h2 className="text-sm font-semibold text-ink">{t("agentTokensSettings.saveNow")}</h2>
          <p className="mt-1 text-xs leading-5 text-olive">{t("agentTokensSettings.saveNowDescPrefix")}<code className="rounded bg-paper px-1 py-0.5 text-ink">LEDGER_AGENT_TOKEN</code>{t("agentTokensSettings.saveNowDescSuffix")}</p>
          <code className="mt-3 block max-h-28 overflow-auto rounded-md bg-paper px-3 py-2.5 font-mono text-xs leading-5 text-ink selection:bg-brand/20">{createdToken}</code>
          <div className="mt-3 flex flex-wrap gap-2">
            <Button type="button" size="sm" className="h-10" onClick={() => void copyToken()}>{copied ? <Check className="h-4 w-4" /> : <Copy className="h-4 w-4" />}{copied ? t("agentTokensSettings.copied") : t("agentTokensSettings.copyToken")}</Button>
            <Button type="button" size="sm" variant="outline" className="h-10" onClick={() => setCreatedToken("")}>{t("agentTokensSettings.saved")}</Button>
          </div>
        </div>
      </div>
    </div>}

    <div className="mt-5 overflow-hidden border-y border-line bg-panel">
      {loading && <div className="flex min-h-28 items-center justify-center px-5 py-8 text-sm text-stone" role="status">{t("agentTokensSettings.loading")}</div>}
      {!loading && unsupported && <div className="flex min-h-36 flex-col items-center justify-center px-6 py-8 text-center" role="status"><h2 className="text-sm font-semibold text-ink">{t("agentTokensSettings.unsupportedTitle")}</h2><p className="mt-2 max-w-md text-sm leading-6 text-stone">{t("agentTokensSettings.unsupportedDesc")}</p></div>}
      {!loading && loadError && <div className="flex min-h-36 flex-col items-center justify-center px-6 py-8 text-center" role="alert"><h2 className="text-sm font-semibold text-ink">{t("agentTokensSettings.loadErrorTitle")}</h2><p className="mt-2 max-w-md text-sm leading-6 text-stone">{loadError}</p><Button type="button" variant="outline" className="mt-4 h-10" onClick={() => void load()}>{t("agentTokensSettings.retry")}</Button></div>}
      {!loading && sensitiveUnlocked && !unsupported && !loadError && tokens.length === 0 && <div className="flex min-h-40 flex-col items-center justify-center px-6 py-9 text-center"><span className="grid size-11 place-items-center rounded-md border border-line bg-paper text-brand"><KeyRound className="h-5 w-5" /></span><h2 className="mt-4 text-sm font-semibold text-ink">{t("agentTokensSettings.emptyTitle")}</h2><p className="mt-2 max-w-md text-sm leading-6 text-stone">{t("agentTokensSettings.emptyDesc")}</p></div>}
      {!loading && tokens.length > 0 && <div className="divide-y divide-line">{tokens.map((token) => <AgentTokenRow key={token.id} token={token} onRevoke={() => setRevoking(token)} />)}</div>}
    </div>

    <p className="mt-3 flex items-start gap-2 text-xs leading-5 text-stone"><ShieldCheck className="mt-0.5 h-3.5 w-3.5 shrink-0 text-brand" />{t("agentTokensSettings.footerHint")}</p>

    <AlertDialog open={revoking != null} onOpenChange={(open) => !open && !saving && setRevoking(null)}>
      <AlertDialogContent className="border-line bg-panel text-ink">
        <AlertDialogHeader><AlertDialogTitle>{t("agentTokensSettings.revokeTitle")}</AlertDialogTitle><AlertDialogDescription className="text-stone">{t("agentTokensSettings.revokeDesc", { name: revoking?.name ?? "" })}</AlertDialogDescription></AlertDialogHeader>
        <AlertDialogFooter><AlertDialogCancel disabled={saving}>{t("agentTokensSettings.cancel")}</AlertDialogCancel><Button type="button" variant="destructive" disabled={saving} onClick={() => void confirmRevoke()}>{saving ? t("agentTokensSettings.revoking") : t("agentTokensSettings.confirmRevoke")}</Button></AlertDialogFooter>
      </AlertDialogContent>
    </AlertDialog>
  </section>;
}

function AgentTokenRow({ token, onRevoke }: { token: AgentAccessTokenSummary; onRevoke: () => void }) {
  const { t } = useTranslation();
  const presentation = agentTokenPresentation(token);
  return <div className="flex min-w-0 items-start gap-3 px-4 py-4 sm:items-center sm:px-5">
    <span className="mt-0.5 grid size-10 shrink-0 place-items-center rounded-md border border-line bg-paper text-brand sm:mt-0"><KeyRound className="h-4 w-4" /></span>
    <div className="min-w-0 flex-1">
      <div className="flex flex-wrap items-center gap-2"><h2 className="min-w-0 truncate text-sm font-semibold text-ink" title={token.name}>{token.name}</h2><span className={`rounded-full px-2 py-0.5 text-[11px] font-medium ${presentation.active ? "bg-tag text-olive" : "bg-[var(--danger)]/10 text-[var(--danger)]"}`}>{presentation.label}</span><span className="rounded-full bg-brand/10 px-2 py-0.5 text-[11px] font-medium text-brand">{agentTokenScopeLabel(token)}</span></div>
      <p className="mt-1 text-xs leading-5 text-stone tabular-nums">{agentTokenUsageLabel(token)} · {t("agentTokensSettings.createdOn", { date: formatAgentTokenDate(token.createdAt) })} · {t("agentTokensSettings.expiresOn", { date: formatAgentTokenDate(token.expiresAt) })}</p>
    </div>
    <Button type="button" variant="outline" size="sm" className="h-10 shrink-0" disabled={!presentation.active} onClick={onRevoke}><Ban className="h-4 w-4" />{presentation.active ? t("agentTokensSettings.revoke") : t("agentTokensSettings.deactivated")}</Button>
  </div>;
}

export function agentTokenPresentation(token: AgentAccessTokenSummary, now = Date.now()) {
  if (token.revokedAt) return { label: i18n.t("agentTokensSettings.revokedLabel"), active: false };
  const expiresAt = new Date(token.expiresAt).getTime();
  if (Number.isFinite(expiresAt) && expiresAt <= now) return { label: i18n.t("agentTokensSettings.expiredLabel"), active: false };
  return { label: i18n.t("agentTokensSettings.activeLabel"), active: true };
}

export function agentTokenUsageLabel(token: AgentAccessTokenSummary) {
  return token.lastUsedAt ? i18n.t("agentTokensSettings.usedOn", { date: formatAgentTokenDate(token.lastUsedAt, true) }) : i18n.t("agentTokensSettings.neverUsed");
}

export function agentTokenScopeLabel(token: AgentAccessTokenSummary) {
  if (token.legacy) return i18n.t("agentTokensSettings.scopeLegacy");
  return token.scopes.includes("write") ? i18n.t("agentTokensSettings.scopeReadWrite") : i18n.t("agentTokensSettings.scopeRead");
}

function formatAgentTokenDate(value: string, includeTime = false) {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return i18n.t("agentTokensSettings.unknownDate");
  return new Intl.DateTimeFormat(i18n.language, includeTime ? { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit" } : { year: "numeric", month: "short", day: "numeric" }).format(date);
}
