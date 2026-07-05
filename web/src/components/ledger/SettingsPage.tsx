import { useEffect, useState } from "react";
import { ledgerNavItems } from "../AppShell";
import { Checkbox } from "@/components/ui/checkbox";
import { Switch } from "@/components/ui/switch";
import type { LedgerNavHref, PrivacySettings, ResolvedTheme, ThemeMode } from "./types";

const themeOptions: { value: ThemeMode; label: string; description: string }[] = [
  { value: "system", label: "跟随系统", description: "系统切换时自动同步" },
  { value: "light", label: "浅色", description: "固定使用纸张浅色" },
  { value: "dark", label: "深色", description: "固定使用夜间深色" },
];

type LocalAccessState = {
  origin: string;
  hostname: string;
  secure: boolean;
  standalone: boolean;
  localOnly: boolean;
  privateLan: boolean;
};

function readLocalAccessState(): LocalAccessState | null {
  if (typeof window === "undefined") return null;
  const hostname = window.location.hostname;
  const localOnly = hostname === "localhost" || hostname === "127.0.0.1" || hostname === "::1";
  const privateLan = /^(10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)/.test(hostname);
  const standalone = window.matchMedia("(display-mode: standalone)").matches || Boolean((navigator as Navigator & { standalone?: boolean }).standalone);
  return {
    origin: window.location.origin,
    hostname,
    secure: window.isSecureContext,
    standalone,
    localOnly,
    privateLan,
  };
}

export function SettingsPage({
  settings,
  commodities,
  onChange,
  themeMode,
  resolvedTheme,
  onThemeModeChange,
  mobileTabHrefs,
  onMobileTabHrefsChange,
}: {
  settings: PrivacySettings;
  commodities: string[];
  onChange: <K extends keyof PrivacySettings>(key: K, value: PrivacySettings[K]) => void;
  themeMode: ThemeMode;
  resolvedTheme: ResolvedTheme;
  onThemeModeChange: (mode: ThemeMode) => void;
  mobileTabHrefs: LedgerNavHref[];
  onMobileTabHrefsChange: (hrefs: LedgerNavHref[]) => void;
}) {
  function toggleMobileTab(href: LedgerNavHref, checked: boolean) {
    if (checked) onMobileTabHrefsChange(Array.from(new Set([...mobileTabHrefs, href])).slice(0, 5));
    else onMobileTabHrefsChange(mobileTabHrefs.filter((item) => item !== href));
  }
  const currencyOptions = Array.from(new Set(["CNY", ...commodities, settings.valuationCurrency].filter(Boolean))).sort();

  return <div className="space-y-6">
    <LocalAccessPanel />

    <section className="card p-5 md:p-6">
      <div className="border-l-4 border-brand pl-4">
        <div className="text-xs uppercase tracking-[0.24em] text-stone">valuation</div>
        <h1 className="mt-2 font-serif text-3xl font-medium">汇总估值</h1>
        <p className="mt-2 max-w-2xl text-sm leading-6 text-olive">用于首页、趋势看板、净资产和损益汇总。单个账户余额仍显示账户原币。</p>
      </div>
      <label className="mt-6 block max-w-xs">
        <span className="mb-2 block text-sm font-medium text-olive">估值币种</span>
        <select className="h-12 w-full rounded-xl border border-line bg-panel px-3 text-ink" value={settings.valuationCurrency} onChange={(event) => onChange("valuationCurrency", event.target.value.toUpperCase())}>
          {currencyOptions.map((currency) => <option key={currency} value={currency}>{currency}</option>)}
        </select>
      </label>
    </section>

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
          const checkboxId = `mobile-tab-${item.href.replace(/[^a-z0-9-]+/gi, "-")}`;
          return <div key={item.href} className={`flex items-center justify-between gap-3 rounded-xl border px-4 py-3 ${checked ? "border-brand bg-[var(--selected-bg)]" : "border-line bg-paper"} ${disabled ? "opacity-50" : "hover:bg-tag"}`}>
            <label htmlFor={checkboxId} className={`flex min-w-0 flex-1 items-center gap-3 ${disabled ? "cursor-not-allowed" : "cursor-pointer"}`}>
              <Icon className="h-4 w-4 shrink-0 text-brand" />
              <span className="font-medium text-ink">{item.label}</span>
            </label>
            <Checkbox id={checkboxId} className="size-5" checked={checked} disabled={disabled} onCheckedChange={(value) => toggleMobileTab(item.href, value === true)} />
          </div>;
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
        <SettingToggle id="show-home-summary-amounts" title="首页月度收入 / 支出 / 结余" description="关闭后首页三个指标默认显示为 ••••••。" checked={settings.showHomeSummaryAmounts} onChange={(checked) => onChange("showHomeSummaryAmounts", checked)} />
        <SettingToggle id="show-account-balances-by-default" title="账户页余额" description="控制进入账户页时是否默认展开全部账户余额；仍可在页面内临时切换。" checked={settings.showAccountBalancesByDefault} onChange={(checked) => onChange("showAccountBalancesByDefault", checked)} />
        <SettingToggle id="show-net-worth-by-default" title="净资产页金额与曲线" description="控制进入净资产页时是否默认显示资产、负债、净资产和曲线。" checked={settings.showNetWorthByDefault} onChange={(checked) => onChange("showNetWorthByDefault", checked)} />
        <SettingToggle id="show-income-statement-by-default" title="损益表金额" description="控制进入损益表时是否默认显示各分类的具体金额。" checked={settings.showIncomeStatementByDefault} onChange={(checked) => onChange("showIncomeStatementByDefault", checked)} />
      </div>
    </section>
  </div>;
}

function LocalAccessPanel() {
  const [state, setState] = useState<LocalAccessState | null>(() => readLocalAccessState());

  useEffect(() => {
    const sync = () => setState(readLocalAccessState());
    sync();
    const media = window.matchMedia("(display-mode: standalone)");
    media.addEventListener("change", sync);
    return () => media.removeEventListener("change", sync);
  }, []);

  if (!state) return null;

  const accessLabel = state.localOnly ? "仅本机" : state.privateLan ? "局域网" : "公网 / 隧道";
  const readiness = state.secure
    ? "当前 Origin 可用于 PWA 安装与 Passkey。"
    : "当前不是安全上下文；手机安装、Passkey 和通知建议切到 HTTPS。";
  const phoneHint = state.localOnly
    ? "手机无法直接访问 localhost；请使用局域网域名/IP、Tailscale、Cloudflare Tunnel 或 Caddy HTTPS。"
    : state.privateLan
      ? "手机可在同一网络下访问；若要使用 Passkey，请给这个地址配置稳定 HTTPS。"
      : "适合跨网络访问；请确认这个域名会长期保留，避免 Passkey Origin 变化。";

  return <section className="card p-5 md:p-6">
    <div className="border-l-4 border-brand pl-4">
      <div className="text-xs uppercase tracking-[0.24em] text-stone">local access</div>
      <h1 className="mt-2 font-serif text-3xl font-medium">本地优先访问</h1>
      <p className="mt-2 max-w-2xl text-sm leading-6 text-olive">{phoneHint}</p>
    </div>
    <div className="mt-6 grid gap-3 md:grid-cols-3">
      <StatusTile title="当前 Origin" value={state.origin} />
      <StatusTile title="访问范围" value={accessLabel} />
      <StatusTile title="PWA 模式" value={state.standalone ? "已独立打开" : "浏览器标签页"} />
    </div>
    <div className={`mt-4 rounded-xl border px-4 py-3 text-sm leading-6 ${state.secure ? "border-brand/30 bg-brand/10 text-brand" : "border-[var(--danger)]/30 bg-[var(--danger)]/10 text-[var(--danger)]"}`}>
      {readiness}
    </div>
    <a className="mt-4 inline-flex rounded-xl border border-line bg-panel px-3 py-2 text-sm text-brand hover:bg-tag" href="https://github.com/qiaoborui/beancount-ledger-web/blob/main/docs/local-first-pwa.md" target="_blank" rel="noreferrer">
      打开本地优先部署指南
    </a>
  </section>;
}

function StatusTile({ title, value }: { title: string; value: string }) {
  return <div className="rounded-xl border border-line bg-panel px-4 py-3">
    <div className="text-xs text-stone">{title}</div>
    <div className="mt-1 min-w-0 break-all text-sm font-medium text-ink">{value}</div>
  </div>;
}

function SettingToggle({ id, title, description, checked, onChange }: { id: string; title: string; description: string; checked: boolean; onChange: (checked: boolean) => void }) {
  return <div className="flex items-center justify-between gap-4 p-4">
    <label htmlFor={id} className="min-w-0 cursor-pointer">
      <span className="block font-medium text-ink">{title}</span>
      <span className="mt-1 block text-sm leading-6 text-olive">{description}</span>
    </label>
    <Switch id={id} checked={checked} onCheckedChange={onChange} />
  </div>;
}
