import { useCallback, useEffect, useRef, useState } from "react";
import { Ban, Check, Copy, KeyRound, Plus, ShieldCheck, Terminal } from "lucide-react";
import { AlertDialog, AlertDialogCancel, AlertDialogContent, AlertDialogDescription, AlertDialogFooter, AlertDialogHeader, AlertDialogTitle } from "@/components/ui/alert-dialog";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { apiEndpointSettingsChangeEvent } from "@/lib/apiEndpoints";
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

export function AgentAccessTokenSettings({ sensitiveUnlocked, showToast }: { sensitiveUnlocked: boolean; showToast: ToastFn }) {
  const [tokens, setTokens] = useState<AgentAccessTokenSummary[]>([]);
  const [name, setName] = useState("");
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
        const message = error instanceof Error ? error.message : "读取 Agent 访问令牌失败";
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
      showToast("error", "请输入令牌名称");
      return;
    }
    if (trimmed.length > 64) {
      showToast("error", "令牌名称不能超过 64 个字符");
      return;
    }
    const current = operationGate.current.capture();
    setCreating(true);
    setCreatedToken("");
    try {
      const result = await createAgentAccessToken(trimmed);
      if (!operationGate.current.isCurrent(current)) return;
      setTokens((current) => [result.credential, ...current]);
      setCreatedToken(result.token);
      setCopied(false);
      setName("");
      showToast("success", "本地 Agent Token 已创建");
    } catch (error) {
      if (!operationGate.current.isCurrent(current)) return;
      showToast("error", error instanceof Error ? error.message : "创建 Agent 访问令牌失败");
    } finally {
      if (operationGate.current.isCurrent(current)) setCreating(false);
    }
  }

  async function copyToken() {
    if (!createdToken) return;
    try {
      await navigator.clipboard.writeText(createdToken);
      setCopied(true);
      showToast("success", "令牌已复制");
    } catch {
      showToast("error", "浏览器未允许复制，请手动选择令牌");
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
      showToast("success", "Agent 访问令牌已吊销");
    } catch (error) {
      if (!operationGate.current.isCurrent(current)) return;
      showToast("error", error instanceof Error ? error.message : "吊销 Agent 访问令牌失败");
    } finally {
      if (operationGate.current.isCurrent(current)) setSaving(false);
    }
  }

  return <section className="card p-5 md:p-6">
    <div className="flex flex-col gap-4 border-b border-line pb-4 lg:flex-row lg:items-start lg:justify-between">
      <div className="flex min-w-0 items-start gap-3">
        <span className="grid size-10 shrink-0 place-items-center rounded-xl bg-brand/10 text-brand"><Terminal className="h-5 w-5" /></span>
        <div>
          <div className="text-xs uppercase tracking-[0.24em] text-stone">local bub access</div>
          <h1 className="mt-2 font-serif text-3xl font-medium">本地 Agent 访问</h1>
          <p className="mt-2 max-w-2xl text-sm leading-6 text-olive">签发给本地 <code className="rounded bg-tag px-1.5 py-0.5 text-xs text-ink">bub chat</code> 的可吊销 Token，默认提供完整账本工具。写入前 Agent 必须先在一轮对话中展示完整草稿，等你下一轮明确确认后才能调用写工具。</p>
        </div>
      </div>
      <div className="flex w-full gap-2 lg:w-auto lg:min-w-80">
        <Input aria-label="令牌名称" maxLength={64} value={name} onChange={(event) => setName(event.target.value)} onKeyDown={(event) => event.key === "Enter" && void create()} placeholder="例如：MacBook Bub" disabled={!sensitiveUnlocked || creating || unsupported} />
        <Button type="button" className="h-10 shrink-0" disabled={!sensitiveUnlocked || creating || unsupported || !name.trim()} onClick={() => void create()}><Plus className="h-4 w-4" />{creating ? "创建中…" : "创建"}</Button>
      </div>
    </div>

    {!sensitiveUnlocked && <div className="mt-5 rounded-xl bg-tag px-4 py-3 text-sm leading-6 text-stone">解锁敏感数据后才能创建、查看或吊销本地 Agent 访问令牌。</div>}

    {sensitiveUnlocked && createdToken && <div className="mt-5 rounded-xl border border-brand/35 bg-[var(--selected-bg)] p-4" role="status">
      <div className="flex items-start gap-3">
        <span className="grid size-9 shrink-0 place-items-center rounded-lg bg-brand text-paper"><KeyRound className="h-4 w-4" /></span>
        <div className="min-w-0 flex-1">
          <h2 className="text-sm font-semibold text-ink">请立即保存，这个 Token 只显示一次</h2>
          <p className="mt-1 text-xs leading-5 text-olive">把它设置为本地 Bub 的 <code className="rounded bg-paper px-1 py-0.5 text-ink">LEDGER_AGENT_TOKEN</code>。关闭或刷新页面后无法再次查看，只能重新创建。</p>
          <code className="mt-3 block max-h-28 overflow-auto rounded-lg bg-paper px-3 py-2.5 font-mono text-xs leading-5 text-ink selection:bg-brand/20">{createdToken}</code>
          <div className="mt-3 flex flex-wrap gap-2">
            <Button type="button" size="sm" onClick={() => void copyToken()}>{copied ? <Check className="h-4 w-4" /> : <Copy className="h-4 w-4" />}{copied ? "已复制" : "复制 Token"}</Button>
            <Button type="button" size="sm" variant="outline" onClick={() => setCreatedToken("")}>我已保存</Button>
          </div>
        </div>
      </div>
    </div>}

    <div className="mt-5 overflow-hidden rounded-xl border border-line bg-panel">
      {loading && <div className="flex min-h-28 items-center justify-center px-5 py-8 text-sm text-stone" role="status">正在读取 Agent 访问令牌…</div>}
      {!loading && unsupported && <div className="flex min-h-36 flex-col items-center justify-center px-6 py-8 text-center" role="status"><h2 className="text-sm font-semibold text-ink">当前后端暂不支持 Token 管理</h2><p className="mt-2 max-w-md text-sm leading-6 text-stone">升级后端后，即可为本地 Bub 签发 Agent Token。</p></div>}
      {!loading && loadError && <div className="flex min-h-36 flex-col items-center justify-center px-6 py-8 text-center" role="alert"><h2 className="text-sm font-semibold text-ink">暂时无法读取 Token</h2><p className="mt-2 max-w-md text-sm leading-6 text-stone">{loadError}</p><Button type="button" variant="outline" className="mt-4" onClick={() => void load()}>重试</Button></div>}
      {!loading && sensitiveUnlocked && !unsupported && !loadError && tokens.length === 0 && <div className="flex min-h-40 flex-col items-center justify-center px-6 py-9 text-center"><span className="grid size-11 place-items-center rounded-lg border border-line bg-paper text-brand"><KeyRound className="h-5 w-5" /></span><h2 className="mt-4 text-sm font-semibold text-ink">还没有本地 Agent Token</h2><p className="mt-2 max-w-md text-sm leading-6 text-stone">创建后可在自己的电脑上运行 Bub，通过远程 API 使用查询和写入工具。</p></div>}
      {!loading && tokens.length > 0 && <div className="divide-y divide-line">{tokens.map((token) => <AgentTokenRow key={token.id} token={token} onRevoke={() => setRevoking(token)} />)}</div>}
    </div>

    <p className="mt-3 flex items-start gap-2 text-xs leading-5 text-stone"><ShieldCheck className="mt-0.5 h-3.5 w-3.5 shrink-0 text-brand" />服务端只保存 Token 密钥的哈希。capability 本身有效期为 15 分钟，但 Token 吊销后会立即失效；账本写入仍会执行参数校验、来源版本校验、bean-check 和失败回滚。</p>

    <AlertDialog open={revoking != null} onOpenChange={(open) => !open && !saving && setRevoking(null)}>
      <AlertDialogContent className="border-line bg-panel text-ink">
        <AlertDialogHeader><AlertDialogTitle>吊销这个 Agent Token？</AlertDialogTitle><AlertDialogDescription className="text-stone">本地设备“{revoking?.name}”将无法继续获取新的账本工具权限。需要恢复访问时，请创建一个新 Token。</AlertDialogDescription></AlertDialogHeader>
        <AlertDialogFooter><AlertDialogCancel disabled={saving}>取消</AlertDialogCancel><Button type="button" variant="destructive" disabled={saving} onClick={() => void confirmRevoke()}>{saving ? "吊销中…" : "确认吊销"}</Button></AlertDialogFooter>
      </AlertDialogContent>
    </AlertDialog>
  </section>;
}

function AgentTokenRow({ token, onRevoke }: { token: AgentAccessTokenSummary; onRevoke: () => void }) {
  const presentation = agentTokenPresentation(token);
  return <div className="flex min-w-0 items-start gap-3 px-4 py-4 sm:items-center sm:px-5">
    <span className="mt-0.5 grid size-9 shrink-0 place-items-center rounded-lg border border-line bg-paper text-brand sm:mt-0"><KeyRound className="h-4 w-4" /></span>
    <div className="min-w-0 flex-1">
      <div className="flex flex-wrap items-center gap-2"><h2 className="min-w-0 truncate text-sm font-semibold text-ink" title={token.name}>{token.name}</h2><span className={`rounded-full px-2 py-0.5 text-[11px] font-medium ${presentation.active ? "bg-tag text-olive" : "bg-[var(--danger)]/10 text-[var(--danger)]"}`}>{presentation.label}</span></div>
      <p className="mt-1 text-xs leading-5 text-stone tabular-nums">{agentTokenUsageLabel(token)} · 创建于 {formatAgentTokenDate(token.createdAt)} · 到期 {formatAgentTokenDate(token.expiresAt)}</p>
    </div>
    <Button type="button" variant="outline" size="sm" className="h-10 shrink-0" disabled={!presentation.active} onClick={onRevoke}><Ban className="h-4 w-4" />{presentation.active ? "吊销" : "已停用"}</Button>
  </div>;
}

export function agentTokenPresentation(token: AgentAccessTokenSummary, now = Date.now()) {
  if (token.revokedAt) return { label: "已吊销", active: false };
  const expiresAt = new Date(token.expiresAt).getTime();
  if (Number.isFinite(expiresAt) && expiresAt <= now) return { label: "已过期", active: false };
  return { label: "可用", active: true };
}

export function agentTokenUsageLabel(token: AgentAccessTokenSummary) {
  return token.lastUsedAt ? `最近使用 ${formatAgentTokenDate(token.lastUsedAt, true)}` : "尚未使用";
}

function formatAgentTokenDate(value: string, includeTime = false) {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "时间未知";
  return new Intl.DateTimeFormat("zh-CN", includeTime ? { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit" } : { year: "numeric", month: "short", day: "numeric" }).format(date);
}
