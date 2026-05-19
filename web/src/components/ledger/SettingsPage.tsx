import { useEffect, useState } from "react";
import { fetchJson } from "@/lib/clientFetch";
import { ledgerNavItems } from "../AppShell";
import type { LedgerNavHref, PrivacySettings, ResolvedTheme, ThemeMode } from "./types";

const themeOptions: { value: ThemeMode; label: string; description: string }[] = [
  { value: "system", label: "跟随系统", description: "系统切换时自动同步" },
  { value: "light", label: "浅色", description: "固定使用纸张浅色" },
  { value: "dark", label: "深色", description: "固定使用夜间深色" },
];

export function SettingsPage({
  settings,
  onChange,
  themeMode,
  resolvedTheme,
  onThemeModeChange,
  mobileTabHrefs,
  onMobileTabHrefsChange,
  onGitStatusRefresh,
  showToast,
  currentUserId,
  onLogout,
}: {
  settings: PrivacySettings;
  onChange: <K extends keyof PrivacySettings>(key: K, value: PrivacySettings[K]) => void;
  themeMode: ThemeMode;
  resolvedTheme: ResolvedTheme;
  onThemeModeChange: (mode: ThemeMode) => void;
  mobileTabHrefs: LedgerNavHref[];
  onMobileTabHrefsChange: (hrefs: LedgerNavHref[]) => void;
  onGitStatusRefresh?: () => void | Promise<void>;
  showToast?: (kind: "info" | "success" | "error", text: string) => void;
  currentUserId?: string | null;
  onLogout?: () => void | Promise<void>;
}) {
  function toggleMobileTab(href: LedgerNavHref, checked: boolean) {
    if (checked) onMobileTabHrefsChange(Array.from(new Set([...mobileTabHrefs, href])).slice(0, 5));
    else onMobileTabHrefsChange(mobileTabHrefs.filter((item) => item !== href));
  }

  return <div className="space-y-6">
    <AccountSettings currentUserId={currentUserId} onLogout={onLogout} />
    <GitRepositorySettings onGitStatusRefresh={onGitStatusRefresh} showToast={showToast} />

    <section className="card p-5 md:p-6">
      <div className="border-l-4 border-brand pl-4">
        <div className="text-xs uppercase tracking-[0.24em] text-stone">appearance</div>
        <h1 className="mt-2 font-serif text-3xl font-medium">外观设置</h1>
        <p className="mt-2 max-w-2xl text-sm leading-6 text-olive">默认跟随系统深浅色，也可以在这里手动固定。设置只保存在当前浏览器。</p>
      </div>
      <div className="mt-6 rounded-2xl border border-line bg-panel p-2">
        <div className="grid gap-2 md:grid-cols-3">
          {themeOptions.map((option) => {
            const active = themeMode === option.value;
            return <button
              key={option.value}
              type="button"
              className={`rounded-xl border px-4 py-3 text-left ${active ? "border-brand bg-[var(--selected-bg)] text-ink ring-1 ring-brand/30" : "border-line bg-paper text-ink hover:bg-tag"}`}
              onClick={() => onThemeModeChange(option.value)}
              aria-pressed={active}
            >
              <span className="block font-medium">{option.label}</span>
              <span className={`mt-1 block text-xs leading-5 ${active ? "text-olive" : "text-stone"}`}>{option.description}</span>
            </button>;
          })}
        </div>
        <p className="mt-3 px-2 text-xs text-stone">当前实际主题：{resolvedTheme === "dark" ? "深色" : "浅色"}</p>
      </div>
    </section>

    <section className="card p-5 md:p-6">
      <div className="border-l-4 border-brand pl-4">
        <div className="text-xs uppercase tracking-[0.24em] text-stone">mobile navigation</div>
        <h1 className="mt-2 font-serif text-3xl font-medium">底部 Tab</h1>
        <p className="mt-2 max-w-2xl text-sm leading-6 text-olive">选择移动端底部栏展示哪些页面，最多 5 个。未展示的页面仍可从左上角菜单进入。</p>
      </div>
      <div className="mt-6 grid gap-2 rounded-2xl border border-line bg-panel p-2 md:grid-cols-2">
        {ledgerNavItems.map((item) => {
          const Icon = item.icon;
          const checked = mobileTabHrefs.includes(item.href);
          const disabled = !checked && mobileTabHrefs.length >= 5;
          return <label key={item.href} className={`flex cursor-pointer items-center justify-between gap-3 rounded-xl border px-4 py-3 ${checked ? "border-brand bg-[var(--selected-bg)]" : "border-line bg-paper"} ${disabled ? "cursor-not-allowed opacity-50" : "hover:bg-tag"}`}>
            <span className="flex min-w-0 items-center gap-3">
              <Icon className="h-4 w-4 shrink-0 text-brand" />
              <span className="font-medium text-ink">{item.label}</span>
            </span>
            <input className="h-5 w-5 shrink-0 accent-brand" type="checkbox" checked={checked} disabled={disabled} onChange={(event) => toggleMobileTab(item.href, event.target.checked)} />
          </label>;
        })}
      </div>
      <p className="mt-3 text-xs text-stone">当前展示：{mobileTabHrefs.length ? ledgerNavItems.filter((item) => mobileTabHrefs.includes(item.href)).map((item) => item.label).join("、") : "无"}</p>
    </section>

    <section className="card p-5 md:p-6">
      <div className="border-l-4 border-brand pl-4">
        <div className="text-xs uppercase tracking-[0.24em] text-stone">privacy defaults</div>
        <h1 className="mt-2 font-serif text-3xl font-medium">默认显示设置</h1>
        <p className="mt-2 max-w-2xl text-sm leading-6 text-olive">控制打开账本时哪些金额默认可见。设置只保存在当前浏览器，不写入 Beancount 文件。</p>
      </div>
      <div className="mt-6 divide-y divide-line rounded-2xl border border-line bg-panel">
        <SettingToggle title="首页月度收入 / 支出 / 结余" description="关闭后首页三个指标默认显示为 ••••••。" checked={settings.showHomeSummaryAmounts} onChange={(checked) => onChange("showHomeSummaryAmounts", checked)} />
        <SettingToggle title="账户页余额" description="控制进入账户页时是否默认展开全部账户余额；仍可在页面内临时切换。" checked={settings.showAccountBalancesByDefault} onChange={(checked) => onChange("showAccountBalancesByDefault", checked)} />
        <SettingToggle title="净资产页金额与曲线" description="控制进入净资产页时是否默认显示资产、负债、净资产和曲线。" checked={settings.showNetWorthByDefault} onChange={(checked) => onChange("showNetWorthByDefault", checked)} />
        <SettingToggle title="损益表金额" description="控制进入损益表时是否默认显示各分类的具体金额。" checked={settings.showIncomeStatementByDefault} onChange={(checked) => onChange("showIncomeStatementByDefault", checked)} />
      </div>
    </section>
  </div>;
}

function AccountSettings({ currentUserId, onLogout }: { currentUserId?: string | null; onLogout?: () => void | Promise<void> }) {
  const [status, setStatus] = useState<RepoStatus | null>(null);

  useEffect(() => {
    let cancelled = false;
    fetchJson<RepoStatus>("/api/ledger/repo/status", undefined, null as unknown as RepoStatus)
      .then((data) => { if (!cancelled) setStatus(data); })
      .catch(() => undefined);
    return () => { cancelled = true; };
  }, [currentUserId]);

  return <section className="card p-5 md:p-6">
    <div className="flex flex-col gap-4 md:flex-row md:items-start md:justify-between">
      <div className="border-l-4 border-brand pl-4">
        <div className="text-xs uppercase tracking-[0.24em] text-stone">account</div>
        <h1 className="mt-2 font-serif text-3xl font-medium">当前用户</h1>
        <p className="mt-2 text-sm text-olive">已登录为 <span className="font-semibold text-ink">{currentUserId || "未知用户"}</span></p>
        {status?.localPath && <p className="mt-2 break-all text-xs text-stone">本地账本路径：{status.localPath}</p>}
      </div>
      {onLogout && <button type="button" className="rounded-xl border border-line bg-paper px-4 py-2 text-sm text-ink hover:bg-tag" onClick={() => void onLogout()}>退出登录</button>}
    </div>
  </section>;
}

type RepoStatus = {
  configured: boolean;
  gitWorkspace: boolean;
  localPath: string;
  config: null | {
    provider: "github" | "git";
    owner?: string;
    repo?: string;
    branch?: string;
    remoteUrl: string;
    localPath: string;
    hasToken: boolean;
    initializedAt?: string;
    lastSyncedAt?: string;
  };
};

function GitRepositorySettings({ onGitStatusRefresh, showToast }: { onGitStatusRefresh?: () => void | Promise<void>; showToast?: (kind: "info" | "success" | "error", text: string) => void }) {
  const [status, setStatus] = useState<RepoStatus | null>(null);
  const [remoteUrl, setRemoteUrl] = useState("");
  const [branch, setBranch] = useState("");
  const [token, setToken] = useState("");
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState("chore: update ledger");

  async function loadStatus() {
    try {
      setStatus(await fetchJson<RepoStatus>("/api/ledger/repo/status"));
    } catch (error) {
      showToast?.("error", error instanceof Error ? error.message : String(error));
    }
  }

  useEffect(() => {
    void loadStatus();
  }, []);

  async function connectRepo() {
    if (!remoteUrl.trim()) return showToast?.("error", "请填写 Git 仓库地址");
    setBusy(true);
    try {
      const result = await fetchJson<{ status: RepoStatus }>("/api/ledger/repo/connect", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ remoteUrl: remoteUrl.trim(), branch: branch.trim() || undefined, token: token.trim() || undefined, provider: remoteUrl.includes("github.com") ? "github" : "git" }),
      });
      setStatus(result.status);
      setRemoteUrl("");
      setToken("");
      showToast?.("success", "Git 仓库已连接");
      await onGitStatusRefresh?.();
    } catch (error) {
      showToast?.("error", error instanceof Error ? error.message : String(error));
    } finally {
      setBusy(false);
    }
  }

  async function updateToken() {
    if (!token.trim()) return showToast?.("error", "请填写 Access Token");
    setBusy(true);
    try {
      const result = await fetchJson<{ status: RepoStatus }>("/api/ledger/repo/token", {
        method: "PUT",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ token: token.trim() }),
      });
      setStatus(result.status);
      setToken("");
      showToast?.("success", "Token 已加密保存");
    } catch (error) {
      showToast?.("error", error instanceof Error ? error.message : String(error));
    } finally {
      setBusy(false);
    }
  }

  async function clearToken() {
    setBusy(true);
    try {
      const result = await fetchJson<{ status: RepoStatus }>("/api/ledger/repo/token", { method: "DELETE" });
      setStatus(result.status);
      showToast?.("success", "Token 已清除");
    } catch (error) {
      showToast?.("error", error instanceof Error ? error.message : String(error));
    } finally {
      setBusy(false);
    }
  }

  async function initTemplate() {
    setBusy(true);
    try {
      await fetchJson("/api/ledger/repo/init", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ commit: status?.gitWorkspace ?? false, message: "chore: initialize ledger" }),
      });
      showToast?.("success", "账本模板已初始化");
      await Promise.all([loadStatus(), onGitStatusRefresh?.()]);
    } catch (error) {
      showToast?.("error", error instanceof Error ? error.message : String(error));
    } finally {
      setBusy(false);
    }
  }

  async function sync(action: "pull" | "commit-push" | "status") {
    setBusy(true);
    try {
      await fetchJson("/api/ledger/repo/sync", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ action, message: action === "commit-push" ? message : undefined }),
      });
      showToast?.("success", action === "pull" ? "已拉取远端更新" : action === "commit-push" ? "已提交并推送" : "Git 状态已刷新");
      await Promise.all([loadStatus(), onGitStatusRefresh?.()]);
    } catch (error) {
      showToast?.("error", error instanceof Error ? error.message : String(error));
    } finally {
      setBusy(false);
    }
  }

  return <section className="card p-5 md:p-6">
    <div className="border-l-4 border-brand pl-4">
      <div className="text-xs uppercase tracking-[0.24em] text-stone">ledger repository</div>
      <h1 className="mt-2 font-serif text-3xl font-medium">账本 Git 仓库</h1>
      <p className="mt-2 max-w-2xl text-sm leading-6 text-olive">为当前用户连接私有 Git 仓库。可以先使用带 token 的 HTTPS 地址完成首次 clone，应用会保存去掉凭证后的 remote URL。</p>
    </div>

    <div className="mt-6 rounded-2xl border border-line bg-panel p-4">
      <div className="grid gap-3 text-sm md:grid-cols-2">
        <div>
          <div className="text-xs uppercase tracking-[0.18em] text-stone">status</div>
          <div className="mt-1 font-medium text-ink">{status ? (status.gitWorkspace ? "已连接 Git workspace" : "未连接 Git workspace") : "加载中…"}</div>
          <div className="mt-1 break-all text-xs text-stone">本地路径：{status?.localPath ?? "-"}</div>
        </div>
        <div>
          <div className="text-xs uppercase tracking-[0.18em] text-stone">remote</div>
          <div className="mt-1 break-all font-medium text-ink">{status?.config?.remoteUrl ?? "未配置"}</div>
          <div className="mt-1 text-xs text-stone">分支：{status?.config?.branch ?? "默认分支"} · Token：{status?.config?.hasToken ? "已加密保存" : "未保存"}</div>
        </div>
      </div>

      <div className="mt-5 grid gap-3">
        <label className="text-sm font-medium text-ink">
          Git 仓库地址
          <input className="mt-2 w-full rounded-xl border border-line bg-paper px-3 py-2 text-sm outline-none focus:border-brand" value={remoteUrl} onChange={(event) => setRemoteUrl(event.target.value)} placeholder="https://x-access-token:TOKEN@github.com/USERNAME/REPO.git" disabled={busy} />
        </label>
        <label className="text-sm font-medium text-ink">
          分支，可选
          <input className="mt-2 w-full rounded-xl border border-line bg-paper px-3 py-2 text-sm outline-none focus:border-brand" value={branch} onChange={(event) => setBranch(event.target.value)} placeholder="main" disabled={busy} />
        </label>
        <label className="text-sm font-medium text-ink">
          Access Token，可选
          <input className="mt-2 w-full rounded-xl border border-line bg-paper px-3 py-2 text-sm outline-none focus:border-brand" type="password" value={token} onChange={(event) => setToken(event.target.value)} placeholder="可单独填写，或放在 HTTPS URL 中" disabled={busy} />
        </label>
        <div className="flex flex-wrap gap-2">
          <button type="button" className="rounded-xl bg-brand px-4 py-2 text-sm font-medium text-paper disabled:opacity-50" onClick={connectRepo} disabled={busy}>{busy ? "处理中…" : "连接 / Clone"}</button>
          <button type="button" className="rounded-xl border border-line bg-paper px-4 py-2 text-sm text-ink hover:bg-tag disabled:opacity-50" onClick={initTemplate} disabled={busy}>初始化模板</button>
          <button type="button" className="rounded-xl border border-line bg-paper px-4 py-2 text-sm text-ink hover:bg-tag disabled:opacity-50" onClick={updateToken} disabled={busy || !status?.configured}>保存 Token</button>
          <button type="button" className="rounded-xl border border-line bg-paper px-4 py-2 text-sm text-ink hover:bg-tag disabled:opacity-50" onClick={clearToken} disabled={busy || !status?.config?.hasToken}>清除 Token</button>
          <button type="button" className="rounded-xl border border-line bg-paper px-4 py-2 text-sm text-ink hover:bg-tag disabled:opacity-50" onClick={() => sync("pull")} disabled={busy || !status?.gitWorkspace}>Pull</button>
          <button type="button" className="rounded-xl border border-line bg-paper px-4 py-2 text-sm text-ink hover:bg-tag disabled:opacity-50" onClick={() => sync("status")} disabled={busy || !status?.gitWorkspace}>刷新状态</button>
        </div>
      </div>

      <div className="mt-5 rounded-xl border border-line bg-paper p-3">
        <label className="text-sm font-medium text-ink">
          提交信息
          <input className="mt-2 w-full rounded-xl border border-line bg-panel px-3 py-2 text-sm outline-none focus:border-brand" value={message} onChange={(event) => setMessage(event.target.value)} disabled={busy} />
        </label>
        <button type="button" className="mt-3 rounded-xl bg-ink px-4 py-2 text-sm font-medium text-paper disabled:opacity-50" onClick={() => sync("commit-push")} disabled={busy || !status?.gitWorkspace}>提交并推送</button>
      </div>

      <p className="mt-3 text-xs leading-5 text-stone">安全提示：不要长期把 token 保存在 remote URL。当前实现会在 clone 后把 origin 改成不含凭证的地址；Token 会加密保存在当前用户 runtime 中，并仅在 pull/push 时临时注入。</p>
    </div>
  </section>;
}

function SettingToggle({ title, description, checked, onChange }: { title: string; description: string; checked: boolean; onChange: (checked: boolean) => void }) {
  return <label className="flex cursor-pointer items-center justify-between gap-4 p-4">
    <span className="min-w-0">
      <span className="block font-medium text-ink">{title}</span>
      <span className="mt-1 block text-sm leading-6 text-olive">{description}</span>
    </span>
    <input className="h-5 w-5 shrink-0 accent-brand" type="checkbox" checked={checked} onChange={(event) => onChange(event.target.checked)} />
  </label>;
}
