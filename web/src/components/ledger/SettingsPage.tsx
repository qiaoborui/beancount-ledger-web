import { useEffect, useState } from "react";
import type { KeyboardEvent, ReactNode } from "react";
import { useTranslation } from "react-i18next";
import i18n from "@/i18n";
import { ArrowDown, ArrowUp, Check, Database, Globe2, Minus, MonitorCog, Plus, RotateCcw, Save, Send, ShieldCheck, Zap } from "lucide-react";
import { ledgerNavItems } from "../AppShell";
import { Checkbox } from "@/components/ui/checkbox";
import { Switch } from "@/components/ui/switch";
import { fetchJson } from "@/lib/clientFetch";
import { useBrowserRouter } from "@/lib/browserRouter";
import { apiEndpointHealthChangeEvent, apiEndpointLabel, apiEndpointRuntimeStatus, applyApiEndpointProbe, createApiEndpointId, displayApiEndpointUrl, hasKnownApiEndpointAuthentication, isSameOriginApiEndpoint, normalizeApiEndpointUrl, probeApiEndpoint, readApiEndpointSettings, withActiveApiEndpoint, writeApiEndpointSettings, type ApiEndpoint, type ApiEndpointProbeResult, type ApiEndpointSettings } from "@/lib/apiEndpoints";
import { getWebPushPresentation, useWebPush } from "./hooks/useWebPush";
import { useAppLanguage } from "./hooks/useAppLanguage";
import { PasskeySettingsPanel } from "./PasskeySettingsPanel";
import { AgentAccessTokenSettings } from "./AgentAccessTokenSettings";
import type { PasskeyCredentialSummary } from "./passkeys";
import type { QuickUnlockMode } from "./quickUnlock";
import type { LedgerNavHref, PrivacySettings, ResolvedTheme, ThemeMode } from "./types";

type ToastFn = (kind: "info" | "success" | "error", text: string) => void;

type SettingsCategoryId = "workspace" | "privacy" | "connections" | "instance";
type SettingsGroupId = "appearance" | "language" | "navigation" | "valuation" | "visibility" | "passkeys" | "quick-unlock" | "local-access" | "notifications" | "endpoints" | "runtime" | "agent-tokens";

export type SettingsSelection = { category: SettingsCategoryId; group: SettingsGroupId };

type SettingsGroup = { id: SettingsGroupId; labelKey: string };
type SettingsCategory = {
  id: SettingsCategoryId;
  labelKey: string;
  descriptionKey: string;
  icon: typeof MonitorCog;
  groups: readonly SettingsGroup[];
};

export const settingsCategories: readonly SettingsCategory[] = [
  {
    id: "workspace",
    labelKey: "settingsNavigation.workspace",
    descriptionKey: "settingsNavigation.workspaceDesc",
    icon: MonitorCog,
    groups: [
      { id: "appearance", labelKey: "settingsNavigation.appearance" },
      { id: "language", labelKey: "settingsNavigation.language" },
      { id: "navigation", labelKey: "settingsNavigation.navigation" },
      { id: "valuation", labelKey: "settingsNavigation.valuation" },
    ],
  },
  {
    id: "privacy",
    labelKey: "settingsNavigation.privacy",
    descriptionKey: "settingsNavigation.privacyDesc",
    icon: ShieldCheck,
    groups: [
      { id: "visibility", labelKey: "settingsNavigation.visibility" },
      { id: "passkeys", labelKey: "settingsNavigation.passkeys" },
      { id: "quick-unlock", labelKey: "settingsNavigation.quickUnlock" },
    ],
  },
  {
    id: "connections",
    labelKey: "settingsNavigation.connections",
    descriptionKey: "settingsNavigation.connectionsDesc",
    icon: Globe2,
    groups: [
      { id: "local-access", labelKey: "settingsNavigation.localAccess" },
      { id: "notifications", labelKey: "settingsNavigation.notifications" },
      { id: "endpoints", labelKey: "settingsNavigation.endpoints" },
    ],
  },
  {
    id: "instance",
    labelKey: "settingsNavigation.instance",
    descriptionKey: "settingsNavigation.instanceDesc",
    icon: Database,
    groups: [
      { id: "runtime", labelKey: "settingsNavigation.runtime" },
      { id: "agent-tokens", labelKey: "settingsNavigation.agentTokens" },
    ],
  },
] as const;

const DEFAULT_SETTINGS_SELECTION: SettingsSelection = { category: "workspace", group: "appearance" };
const SETTINGS_CONTENT_ID = "settings-active-pane";
const SETTINGS_SECTION_CLASS = "min-w-0 bg-panel px-4 py-5 sm:px-6 sm:py-6 lg:px-8 lg:py-7";

function settingsPaneHeadingId(group: SettingsGroupId) {
  return `settings-pane-heading-${group}`;
}

function settingsCategory(category: SettingsCategoryId) {
  return settingsCategories.find((item) => item.id === category) ?? settingsCategories[0];
}

function isSelectionEqual(left: SettingsSelection, right: SettingsSelection) {
  return left.category === right.category && left.group === right.group;
}

export function parseSettingsSelectionSearch(search: string): SettingsSelection {
  const match = /^([a-z-]+)\.([a-z-]+)$/.exec(new URLSearchParams(search).get("settings") ?? "");
  if (!match) return DEFAULT_SETTINGS_SELECTION;
  const category = settingsCategories.find((item) => item.id === match[1]);
  const group = category?.groups.find((item) => item.id === match[2]);
  return category && group ? { category: category.id, group: group.id } : DEFAULT_SETTINGS_SELECTION;
}

function readSettingsSelection() {
  return typeof window === "undefined" ? DEFAULT_SETTINGS_SELECTION : parseSettingsSelectionSearch(window.location.search);
}

function handleSettingsNavKeyDown(event: KeyboardEvent<HTMLButtonElement>) {
  if (!["ArrowDown", "ArrowUp", "Home", "End"].includes(event.key)) return;
  const container = event.currentTarget.closest<HTMLElement>("[data-settings-navigation]");
  if (!container) return;
  const items = Array.from(container.querySelectorAll<HTMLButtonElement>("button[data-settings-nav-item]"));
  const index = items.indexOf(event.currentTarget);
  if (index < 0) return;
  event.preventDefault();
  const nextIndex = event.key === "Home" ? 0 : event.key === "End" ? items.length - 1 : (index + (event.key === "ArrowDown" ? 1 : -1) + items.length) % items.length;
  items[nextIndex]?.focus();
  items[nextIndex]?.click();
}

const themeOptions: { value: ThemeMode; labelKey: string; descriptionKey: string }[] = [
  { value: "system", labelKey: "settings.themeSystem", descriptionKey: "settings.themeSystemDesc" },
  { value: "light", labelKey: "settings.themeLight", descriptionKey: "settings.themeLightDesc" },
  { value: "dark", labelKey: "settings.themeDark", descriptionKey: "settings.themeDarkDesc" },
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

export type SettingsPageProps = {
  settings: PrivacySettings;
  commodities: string[];
  onChange: <K extends keyof PrivacySettings>(key: K, value: PrivacySettings[K]) => void;
  themeMode: ThemeMode;
  resolvedTheme: ResolvedTheme;
  onThemeModeChange: (mode: ThemeMode) => void;
  mobileTabHrefs: LedgerNavHref[];
  onMobileTabHrefsChange: (hrefs: LedgerNavHref[]) => void;
  sensitiveUnlocked: boolean;
  quickUnlockEnabled: boolean;
  quickUnlockMode: QuickUnlockMode;
  onEnableQuickUnlock: (secret: string, mode: QuickUnlockMode) => void | Promise<void>;
  onDisableQuickUnlock: () => void | Promise<void>;
  onRegisterPasskey: (endpoint?: ApiEndpoint) => Promise<PasskeyCredentialSummary | null>;
  onPasskeyRegisteredChange: (registered: boolean) => void;
  showToast: ToastFn;
};

export function SettingsPage(props: SettingsPageProps) {
  const [selection, setSelection] = useState<SettingsSelection>(readSettingsSelection);
  const router = useBrowserRouter();

  useEffect(() => {
    const syncFromLocation = () => {
      const next = readSettingsSelection();
      setSelection((current) => isSelectionEqual(current, next) ? current : next);
    };
    window.addEventListener("popstate", syncFromLocation);
    return () => {
      window.removeEventListener("popstate", syncFromLocation);
    };
  }, []);

  function select(next: SettingsSelection) {
    if (isSelectionEqual(selection, next)) return;
    setSelection(next);
    if (typeof window !== "undefined") {
      const params = new URLSearchParams(window.location.search);
      params.set("settings", `${next.category}.${next.group}`);
      const search = params.toString();
      router.push(`${window.location.pathname}${search ? `?${search}` : ""}${window.location.hash}`, { scroll: false });
    }
  }

  return <div className="min-w-0 border-y border-line bg-panel [&_button:not([role=switch])]:transition-transform [&_button:not([role=switch])]:active:scale-95 [&_button]:motion-reduce:transition-none [&_button]:motion-reduce:active:scale-100">
    <div className="grid min-h-[calc(100dvh-9rem)] min-w-0 xl:grid-cols-[13rem_12rem_minmax(0,1fr)]">
      <SettingsNavigation selection={selection} onSelect={select} />
      <div id={SETTINGS_CONTENT_ID} role="region" aria-labelledby={settingsPaneHeadingId(selection.group)} className="min-w-0 border-t border-line bg-panel xl:border-t-0">
        <SettingsGroupContent {...props} selection={selection} />
      </div>
    </div>
  </div>;
}

export function SettingsNavigation({ selection, onSelect }: { selection: SettingsSelection; onSelect: (selection: SettingsSelection) => void }) {
  const { t } = useTranslation();
  const activeCategory = settingsCategory(selection.category);

  return <>
    <div className="border-b border-line bg-paper p-3 xl:hidden">
      <div className="grid gap-3 sm:grid-cols-2">
        <label className="grid gap-1.5 text-xs font-semibold text-olive">
          <span>{t("settingsNavigation.categoryLabel")}</span>
          <select aria-controls={SETTINGS_CONTENT_ID} className="h-11 min-w-0 rounded-md border border-line bg-panel px-3 text-sm font-medium text-ink" value={selection.category} onChange={(event) => {
            const category = settingsCategory(event.target.value as SettingsCategoryId);
            onSelect({ category: category.id, group: category.groups[0].id });
          }}>
            {settingsCategories.map((category) => <option key={category.id} value={category.id}>{t(category.labelKey)}</option>)}
          </select>
        </label>
        <label className="grid gap-1.5 text-xs font-semibold text-olive">
          <span>{t("settingsNavigation.groupLabel")}</span>
          <select aria-controls={SETTINGS_CONTENT_ID} className="h-11 min-w-0 rounded-md border border-line bg-panel px-3 text-sm font-medium text-ink" value={selection.group} onChange={(event) => onSelect({ category: selection.category, group: event.target.value as SettingsGroupId })}>
            {activeCategory.groups.map((group) => <option key={group.id} value={group.id}>{t(group.labelKey)}</option>)}
          </select>
        </label>
      </div>
    </div>

    <nav className="hidden border-r border-line bg-paper px-2 py-4 xl:sticky xl:top-0 xl:block xl:h-dvh xl:self-start xl:overflow-y-auto" aria-label={t("settingsNavigation.categoryLabel")}>
      <div className="px-2 pb-2 text-[11px] font-semibold text-stone">{t("settingsNavigation.categories")}</div>
      <div className="space-y-1" data-settings-navigation>
        {settingsCategories.map((category) => {
          const active = category.id === selection.category;
          const Icon = category.icon;
          return <button key={category.id} type="button" data-settings-nav-item className={`flex min-h-10 w-full items-center gap-2.5 rounded-md px-2.5 py-2 text-left text-sm transition-[color,background-color,transform] active:scale-95 motion-reduce:transition-none motion-reduce:active:scale-100 ${active ? "bg-[var(--selected-bg)] font-semibold text-brand" : "text-olive hover:bg-tag hover:text-ink"}`} aria-current={active ? "page" : undefined} aria-controls={SETTINGS_CONTENT_ID} tabIndex={active ? 0 : -1} onClick={() => onSelect(active ? selection : { category: category.id, group: category.groups[0].id })} onKeyDown={handleSettingsNavKeyDown}>
            <Icon className="h-4 w-4 shrink-0" aria-hidden="true" />
            <span className="min-w-0 break-words">{t(category.labelKey)}</span>
          </button>;
        })}
      </div>
    </nav>

    <nav className="hidden border-r border-line bg-[color-mix(in_srgb,var(--paper)_70%,var(--panel))] px-2 py-4 xl:sticky xl:top-0 xl:block xl:h-dvh xl:self-start xl:overflow-y-auto" aria-label={t("settingsNavigation.groupLabel")}>
      <div className="px-2 pb-1 text-sm font-semibold text-ink">{t(activeCategory.labelKey)}</div>
      <p className="px-2 pb-3 text-xs leading-5 text-stone">{t(activeCategory.descriptionKey)}</p>
      <div className="space-y-1" data-settings-navigation>
        {activeCategory.groups.map((group) => {
          const active = group.id === selection.group;
          return <button id={`settings-group-${group.id}`} key={group.id} type="button" data-settings-nav-item className={`flex min-h-10 w-full items-center justify-between gap-2 rounded-md px-2.5 py-2 text-left text-sm transition-[color,background-color,transform] active:scale-95 motion-reduce:transition-none motion-reduce:active:scale-100 ${active ? "bg-[var(--selected-bg)] font-semibold text-brand" : "text-olive hover:bg-tag hover:text-ink"}`} aria-current={active ? "page" : undefined} aria-controls={SETTINGS_CONTENT_ID} tabIndex={active ? 0 : -1} onClick={() => onSelect({ category: selection.category, group: group.id })} onKeyDown={handleSettingsNavKeyDown}>
            <span className="min-w-0 break-words">{t(group.labelKey)}</span>
            {active && <span className="h-1.5 w-1.5 shrink-0 rounded-full bg-brand" aria-hidden="true" />}
          </button>;
        })}
      </div>
    </nav>
  </>;
}

export function SettingsGroupContent({
  selection,
  settings,
  commodities,
  onChange,
  themeMode,
  resolvedTheme,
  onThemeModeChange,
  mobileTabHrefs,
  onMobileTabHrefsChange,
  sensitiveUnlocked,
  quickUnlockEnabled,
  quickUnlockMode,
  onEnableQuickUnlock,
  onDisableQuickUnlock,
  onRegisterPasskey,
  onPasskeyRegisteredChange,
  showToast,
}: SettingsPageProps & { selection: SettingsSelection }) {
  const { t } = useTranslation();
  const { language, setLanguage } = useAppLanguage();
  function toggleMobileTab(href: LedgerNavHref, checked: boolean) {
    if (checked) onMobileTabHrefsChange(Array.from(new Set([...mobileTabHrefs, href])).slice(0, 5));
    else onMobileTabHrefsChange(mobileTabHrefs.filter((item) => item !== href));
  }
  const currencyOptions = Array.from(new Set(["CNY", ...commodities, settings.valuationCurrency].filter(Boolean))).sort();

  return <div>
    <div hidden={selection.group !== "local-access"}><LocalAccessPanel headingId={settingsPaneHeadingId("local-access")} /></div>
    <div hidden={selection.group !== "runtime"}><RuntimeConfigPanel headingId={settingsPaneHeadingId("runtime")} sensitiveUnlocked={sensitiveUnlocked} showToast={showToast} /></div>
    <div hidden={selection.group !== "agent-tokens"}><AgentAccessTokenSettings headingId={settingsPaneHeadingId("agent-tokens")} sensitiveUnlocked={sensitiveUnlocked} showToast={showToast} /></div>
    <div hidden={selection.group !== "passkeys"}><PasskeySettingsPanel headingId={settingsPaneHeadingId("passkeys")} onRegister={onRegisterPasskey} onRegisteredChange={onPasskeyRegisteredChange} showToast={showToast} /></div>
    <div hidden={selection.group !== "notifications"}><NotificationSettingsPanel headingId={settingsPaneHeadingId("notifications")} showToast={showToast} /></div>
    <div hidden={selection.group !== "endpoints"}><ApiEndpointSettingsPanel headingId={settingsPaneHeadingId("endpoints")} showToast={showToast} /></div>
    <div hidden={selection.group !== "quick-unlock"}><QuickUnlockSettings headingId={settingsPaneHeadingId("quick-unlock")} enabled={quickUnlockEnabled} mode={quickUnlockMode} sensitiveUnlocked={sensitiveUnlocked} onEnable={onEnableQuickUnlock} onDisable={onDisableQuickUnlock} showToast={showToast} /></div>
    <section hidden={selection.group !== "valuation"} className={SETTINGS_SECTION_CLASS}>
      <div className="border-b border-line pb-4">
        <h1 id={settingsPaneHeadingId("valuation")} className="text-2xl font-semibold tracking-[-0.02em] text-ink">{t("settings.valuationTitle")}</h1>
        <p className="mt-2 max-w-2xl text-sm leading-6 text-olive">{t("settings.valuationDesc")}</p>
      </div>
      <label className="mt-6 block max-w-xs">
        <span className="mb-2 block text-sm font-medium text-olive">{t("settings.valuationCurrency")}</span>
        <select className="h-11 w-full rounded-md border border-line bg-panel px-3 text-ink" value={settings.valuationCurrency} onChange={(event) => onChange("valuationCurrency", event.target.value.toUpperCase())}>
          {currencyOptions.map((currency) => <option key={currency} value={currency}>{currency}</option>)}
        </select>
      </label>
    </section>

    <section hidden={selection.group !== "appearance"} className={SETTINGS_SECTION_CLASS}>
      <div className="border-b border-line pb-4">
        <h1 id={settingsPaneHeadingId("appearance")} className="text-2xl font-semibold tracking-[-0.02em] text-ink">{t("settings.appearanceTitle")}</h1>
        <p className="mt-2 max-w-2xl text-sm leading-6 text-olive">{t("settings.appearanceDesc")}</p>
      </div>
      <div className="mt-6 border-y border-line bg-line">
        <div className="grid gap-px md:grid-cols-3">
          {themeOptions.map((option) => {
            const active = themeMode === option.value;
            return <button
              key={option.value}
              type="button"
              className={`min-h-11 bg-panel px-4 py-3 text-left transition-[color,background-color,transform] active:scale-95 motion-reduce:transition-none motion-reduce:active:scale-100 ${active ? "bg-[var(--selected-bg)] font-semibold text-ink" : "text-ink hover:bg-tag"}`}
              onClick={() => onThemeModeChange(option.value)}
              aria-pressed={active}
            >
              <span className="block font-medium">{t(option.labelKey)}</span>
              <span className={`mt-1 block text-xs leading-5 ${active ? "text-olive" : "text-stone"}`}>{t(option.descriptionKey)}</span>
            </button>;
          })}
        </div>
        <p className="mt-3 px-2 text-xs text-stone">{t("settings.currentTheme", { theme: t(resolvedTheme === "dark" ? "settings.themeDarkResolved" : "settings.themeLightResolved") })}</p>
      </div>
    </section>

    <section hidden={selection.group !== "language"} className={SETTINGS_SECTION_CLASS}>
      <div className="border-b border-line pb-4">
        <h1 id={settingsPaneHeadingId("language")} className="text-2xl font-semibold tracking-[-0.02em] text-ink">{t("settings.languageTitle")}</h1>
        <p className="mt-2 max-w-2xl text-sm leading-6 text-olive">{t("settings.languageDesc")}</p>
      </div>
      <div className="mt-6 grid gap-px border-y border-line bg-line md:grid-cols-2">
        {(["zh-CN", "en-US"] as const).map((value) => {
          const active = language === value;
          return <button
            key={value}
            type="button"
            className={`flex min-h-11 items-center justify-between gap-3 bg-panel px-4 py-3 text-left transition-[color,background-color,transform] active:scale-95 motion-reduce:transition-none motion-reduce:active:scale-100 ${active ? "bg-[var(--selected-bg)] font-semibold" : "hover:bg-tag"}`}
            onClick={() => setLanguage(value)}
            aria-pressed={active}
          >
            <span className="font-medium text-ink">{value === "zh-CN" ? t("settings.languageChinese") : t("settings.languageEnglish")}</span>
            {active && <Check className="h-4 w-4 shrink-0 text-brand" />}
          </button>;
        })}
      </div>
    </section>

    <section hidden={selection.group !== "navigation"} className={SETTINGS_SECTION_CLASS}>
      <div className="border-b border-line pb-4">
        <h1 id={settingsPaneHeadingId("navigation")} className="text-2xl font-semibold tracking-[-0.02em] text-ink">{t("settings.mobileNavTitle")}</h1>
        <p className="mt-2 max-w-2xl text-sm leading-6 text-olive">{t("settings.mobileNavDesc")}</p>
      </div>
      <div className="mt-6 divide-y divide-line border-y border-line bg-panel">
        {ledgerNavItems.map((item) => {
          const Icon = item.icon;
          const checked = mobileTabHrefs.includes(item.href);
          const disabled = !checked && mobileTabHrefs.length >= 5;
          const checkboxId = `mobile-tab-${item.href.replace(/[^a-z0-9-]+/gi, "-")}`;
          return <div key={item.href} className={`flex min-h-11 items-center justify-between gap-3 px-4 py-3 ${checked ? "bg-[var(--selected-bg)]" : "bg-panel"} ${disabled ? "opacity-50" : "hover:bg-tag"}`}>
            <label htmlFor={checkboxId} className={`flex min-w-0 flex-1 items-center gap-3 ${disabled ? "cursor-not-allowed" : "cursor-pointer"}`}>
              <Icon className="h-4 w-4 shrink-0 text-brand" />
              <span className="font-medium text-ink">{t(item.labelKey)}</span>
            </label>
            <Checkbox id={checkboxId} className="size-5" checked={checked} disabled={disabled} onCheckedChange={(value) => toggleMobileTab(item.href, value === true)} />
          </div>;
        })}
      </div>
      <p className="mt-3 text-xs text-stone">{mobileTabHrefs.length ? t("settings.currentlyShown", { labels: ledgerNavItems.filter((item) => mobileTabHrefs.includes(item.href)).map((item) => t(item.labelKey)).join("、") }) : t("settings.currentlyShownNone")}</p>
    </section>

    <section hidden={selection.group !== "navigation"} className={`${SETTINGS_SECTION_CLASS} border-t border-line`}>
      <div className="border-b border-line pb-4"><h2 className="text-lg font-semibold text-ink">{t("settings.homePageTitle")}</h2><p className="mt-2 max-w-2xl text-sm leading-6 text-olive">{t("settings.homePageDescPrefix")}<code className="rounded bg-tag px-1.5 py-0.5 text-xs text-ink">/</code>{t("settings.homePageDescSuffix")}</p></div>
      <div className="mt-6 grid gap-px border-y border-line bg-line md:grid-cols-2">
        <button type="button" className={`min-h-11 bg-panel p-4 text-left transition-[color,background-color,transform] active:scale-95 motion-reduce:transition-none motion-reduce:active:scale-100 ${settings.homePage === "agent" ? "bg-[var(--selected-bg)] font-semibold" : "hover:bg-tag"}`} onClick={() => onChange("homePage", "agent")} aria-pressed={settings.homePage === "agent"}><span className="block font-medium text-ink">{t("settings.homePageAgent")}</span><span className="mt-1 block text-sm font-normal leading-6 text-olive">{t("settings.homePageAgentDesc")}</span></button>
        <button type="button" className={`min-h-11 bg-panel p-4 text-left transition-[color,background-color,transform] active:scale-95 motion-reduce:transition-none motion-reduce:active:scale-100 ${settings.homePage === "overview" ? "bg-[var(--selected-bg)] font-semibold" : "hover:bg-tag"}`} onClick={() => onChange("homePage", "overview")} aria-pressed={settings.homePage === "overview"}><span className="block font-medium text-ink">{t("settings.homePageOverview")}</span><span className="mt-1 block text-sm font-normal leading-6 text-olive">{t("settings.homePageOverviewDesc")}</span></button>
      </div>
    </section>

    <section hidden={selection.group !== "visibility"} className={SETTINGS_SECTION_CLASS}>
      <div className="border-b border-line pb-4">
        <h1 id={settingsPaneHeadingId("visibility")} className="text-2xl font-semibold tracking-[-0.02em] text-ink">{t("settings.privacyDefaultsTitle")}</h1>
        <p className="mt-2 max-w-2xl text-sm leading-6 text-olive">{t("settings.privacyDefaultsDesc")}</p>
      </div>
      <div className="mt-6 divide-y divide-line border-y border-line bg-panel">
        <SettingToggle id="show-home-summary-amounts" title={t("settings.showHomeSummaryAmounts")} description={t("settings.showHomeSummaryAmountsDesc")} checked={settings.showHomeSummaryAmounts} onChange={(checked) => onChange("showHomeSummaryAmounts", checked)} />
        <SettingToggle id="show-account-balances-by-default" title={t("settings.showAccountBalancesByDefault")} description={t("settings.showAccountBalancesByDefaultDesc")} checked={settings.showAccountBalancesByDefault} onChange={(checked) => onChange("showAccountBalancesByDefault", checked)} />
        <SettingToggle id="show-net-worth-by-default" title={t("settings.showNetWorthByDefault")} description={t("settings.showNetWorthByDefaultDesc")} checked={settings.showNetWorthByDefault} onChange={(checked) => onChange("showNetWorthByDefault", checked)} />
        <SettingToggle id="show-income-statement-by-default" title={t("settings.showIncomeStatementByDefault")} description={t("settings.showIncomeStatementByDefaultDesc")} checked={settings.showIncomeStatementByDefault} onChange={(checked) => onChange("showIncomeStatementByDefault", checked)} />
      </div>
    </section>
  </div>;
}

type RuntimeConfigView = {
  setupComplete: boolean;
  configSource: string;
  instanceId?: string;
  githubOwner?: string;
  githubRepo?: string;
  githubBranch?: string;
  githubApiUrl?: string;
  githubWriteTokenConfigured: boolean;
  githubIndexTokenConfigured: boolean;
  aiProvider?: string;
  aiBaseUrl?: string;
  aiModel?: string;
  aiApiKeyConfigured: boolean;
  indexerIntervalSeconds?: number;
  indexerRetryInitialSeconds?: number;
  indexerRetryMaximumSeconds?: number;
};

function RuntimeConfigPanel({ headingId, sensitiveUnlocked, showToast }: { headingId: string; sensitiveUnlocked: boolean; showToast: ToastFn }) {
  const { t } = useTranslation();
  const [status, setStatus] = useState<RuntimeConfigView | null | undefined>(undefined);
  const [loadRevision, setLoadRevision] = useState(0);
  const [form, setForm] = useState({
    githubOwner: "", githubRepo: "", githubBranch: "main", githubApiUrl: "",
    githubWriteToken: "", githubIndexToken: "",
    aiProvider: "openai-compatible", aiBaseUrl: "", aiModel: "", aiApiKey: "",
    adminPassword: "", indexerIntervalSeconds: 60, indexerRetryInitialSeconds: 5, indexerRetryMaximumSeconds: 60,
  });
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    if (!sensitiveUnlocked) {
      setStatus(undefined);
      return;
    }
    let cancelled = false;
    void fetchJson<RuntimeConfigView>("/api/runtime-config", { cache: "no-store" }, undefined, { kind: "read" })
      .then((next) => {
        if (cancelled) return;
        setStatus(next);
        setForm((current) => ({
          ...current,
          githubOwner: next.githubOwner ?? "",
          githubRepo: next.githubRepo ?? "",
          githubBranch: next.githubBranch ?? "main",
          githubApiUrl: next.githubApiUrl ?? "",
          aiProvider: next.aiProvider ?? "openai-compatible",
          aiBaseUrl: next.aiBaseUrl ?? "",
          aiModel: next.aiModel ?? "",
          indexerIntervalSeconds: next.indexerIntervalSeconds ?? 60,
          indexerRetryInitialSeconds: next.indexerRetryInitialSeconds ?? 5,
          indexerRetryMaximumSeconds: next.indexerRetryMaximumSeconds ?? 60,
        }));
      })
      .catch(() => { if (!cancelled) setStatus(null); });
    return () => { cancelled = true; };
  }, [loadRevision, sensitiveUnlocked]);

  function update(key: keyof typeof form, value: string | number | boolean) {
    setForm((current) => ({ ...current, [key]: value }));
  }

  async function save() {
    setSaving(true);
    try {
      const next = await fetchJson<RuntimeConfigView>("/api/runtime-config", {
        method: "PUT",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(form),
      }, undefined, { kind: "write" });
      setStatus(next);
      setForm((current) => ({ ...current, githubWriteToken: "", githubIndexToken: "", aiApiKey: "", adminPassword: "" }));
      showToast("success", t("settingsRuntime.saved"));
    } catch (error) {
      showToast("error", error instanceof Error ? error.message : t("settingsRuntime.saveFailed"));
    } finally {
      setSaving(false);
    }
  }

  const inputClass = "h-11 min-w-0 rounded-md border border-line bg-panel px-3 text-sm text-ink";
  return <section className={SETTINGS_SECTION_CLASS}>
    <div className="border-b border-line pb-4">
      <h1 id={headingId} className="text-2xl font-semibold tracking-[-0.02em] text-ink">{t("settingsRuntime.title")}</h1>
      <p className="mt-2 max-w-2xl text-sm leading-6 text-olive">{t("settingsRuntime.desc")}</p>
    </div>
    {!sensitiveUnlocked ? <p className="mt-5 rounded-xl bg-tag px-4 py-3 text-sm text-stone">{t("settingsRuntime.lockedHint")}</p> :
      status === undefined ? <p className="mt-5 text-sm text-stone">{t("settingsRuntime.loading")}</p> :
      status === null ? <div className="mt-5 border-y border-line py-5" role="alert">
        <p className="text-sm text-[var(--danger)]">{t("settingsRuntime.loadFailed")}</p>
        <button type="button" className="mt-3 h-10 rounded-md border border-line bg-panel px-3 text-sm font-medium text-brand hover:bg-tag" onClick={() => { setStatus(undefined); setLoadRevision((value) => value + 1); }}>{t("settingsRuntime.retry")}</button>
      </div> :
      <div className="mt-6 space-y-6">
        <div className="flex flex-wrap gap-2 text-xs text-stone">
          <span className="rounded-full bg-tag px-2.5 py-1">{t("settingsRuntime.source", { source: status.configSource })}</span>
          {status.instanceId && <span className="rounded-full bg-tag px-2.5 py-1 font-mono">{status.instanceId}</span>}
        </div>
        <div className="grid gap-3 md:grid-cols-3">
          <RuntimeField label={t("settingsRuntime.githubOwner")}><input required className={inputClass} value={form.githubOwner} onChange={(event) => update("githubOwner", event.target.value)} /></RuntimeField>
          <RuntimeField label={t("settingsRuntime.privateRepo")}><input required className={inputClass} value={form.githubRepo} onChange={(event) => update("githubRepo", event.target.value)} /></RuntimeField>
          <RuntimeField label={t("settingsRuntime.branch")}><input required className={inputClass} value={form.githubBranch} onChange={(event) => update("githubBranch", event.target.value)} /></RuntimeField>
        </div>
        <RuntimeField label={t("settingsRuntime.githubApiUrl")}><input type="url" className={inputClass} value={form.githubApiUrl} onChange={(event) => update("githubApiUrl", event.target.value)} placeholder={t("settingsRuntime.githubApiUrlPlaceholder")} /></RuntimeField>
        <div className="grid gap-3 md:grid-cols-2">
          <RuntimeField label={`${t("settingsRuntime.writeToken")}${status.githubWriteTokenConfigured ? t("settingsRuntime.configuredSuffix") : ""}`}><input type="password" className={inputClass} value={form.githubWriteToken} onChange={(event) => update("githubWriteToken", event.target.value)} placeholder={t("settingsRuntime.keepCurrentPlaceholder")} /></RuntimeField>
          <RuntimeField label={`${t("settingsRuntime.indexerToken")}${status.githubIndexTokenConfigured ? t("settingsRuntime.configuredSuffix") : ""}`}><input type="password" className={inputClass} value={form.githubIndexToken} onChange={(event) => update("githubIndexToken", event.target.value)} placeholder={t("settingsRuntime.keepCurrentPlaceholder")} /></RuntimeField>
        </div>
        <div className="grid gap-3 md:grid-cols-3">
          <RuntimeField label={t("settingsRuntime.aiProvider")}><input required className={inputClass} value={form.aiProvider} onChange={(event) => update("aiProvider", event.target.value)} /></RuntimeField>
          <RuntimeField label={t("settingsRuntime.aiBaseUrl")}><input required type="url" className={inputClass} value={form.aiBaseUrl} onChange={(event) => update("aiBaseUrl", event.target.value)} /></RuntimeField>
          <RuntimeField label={t("settingsRuntime.model")}><input required className={inputClass} value={form.aiModel} onChange={(event) => update("aiModel", event.target.value)} /></RuntimeField>
        </div>
        <div className="grid gap-3 md:grid-cols-2">
          <RuntimeField label={`${t("settingsRuntime.aiApiKey")}${status.aiApiKeyConfigured ? t("settingsRuntime.configuredSuffix") : ""}`}><input type="password" className={inputClass} value={form.aiApiKey} onChange={(event) => update("aiApiKey", event.target.value)} placeholder={t("settingsRuntime.keepCurrentPlaceholder")} /></RuntimeField>
          <RuntimeField label={t("settingsRuntime.newAdminPassword")}><input type="password" minLength={12} className={inputClass} value={form.adminPassword} onChange={(event) => update("adminPassword", event.target.value)} placeholder={t("settingsRuntime.keepUnchangedPlaceholder")} /></RuntimeField>
        </div>
        <div className="grid gap-3 md:grid-cols-3">
          {([
            [t("settingsRuntime.pollSeconds"), "indexerIntervalSeconds"],
            [t("settingsRuntime.retryInitialSeconds"), "indexerRetryInitialSeconds"],
            [t("settingsRuntime.retryMaximumSeconds"), "indexerRetryMaximumSeconds"],
          ] as const).map(([label, key]) => <RuntimeField key={key} label={label}><input type="number" min={1} className={inputClass} value={form[key]} onChange={(event) => update(key, Number(event.target.value))} /></RuntimeField>)}
        </div>
        <button type="button" disabled={saving} onClick={() => void save()} className="inline-flex h-11 items-center gap-2 rounded-md bg-brand px-4 text-sm font-medium text-paper transition-transform active:scale-95 motion-reduce:transition-none motion-reduce:active:scale-100 disabled:opacity-50">
          {saving ? <RotateCcw className="h-4 w-4 animate-spin" /> : <Save className="h-4 w-4" />}{saving ? t("settingsRuntime.saving") : t("settingsRuntime.save")}
        </button>
      </div>}
  </section>;
}

function RuntimeField({ label, children }: { label: string; children: ReactNode }) {
  return <label className="grid gap-2 text-sm font-medium text-olive">{label}{children}</label>;
}

function NotificationSettingsPanel({ headingId, showToast }: { headingId: string; showToast: ToastFn }) {
  const { t } = useTranslation();
  const { state, refresh, subscribe, unsubscribe, sendTest } = useWebPush(showToast);
  const presentation = getWebPushPresentation(state);
  const statusClassName = presentation.tone === "success"
    ? "bg-brand/10 text-brand"
    : presentation.tone === "warning"
      ? "bg-[var(--danger)]/10 text-[var(--danger)]"
      : "bg-tag text-stone";

  async function updateSubscription(checked: boolean) {
    if (checked) await subscribe();
    else await unsubscribe();
  }

  return <section className={SETTINGS_SECTION_CLASS}>
    <div className="border-b border-line pb-4">
      <h1 id={headingId} className="text-2xl font-semibold tracking-[-0.02em] text-ink">{t("settingsNotifications.title")}</h1>
      <p className="mt-2 max-w-2xl text-sm leading-6 text-olive">{t("settingsNotifications.desc")}</p>
    </div>

    <div className="mt-6 flex items-center justify-between gap-4 border-y border-line bg-panel py-4">
      <label htmlFor="web-push-enabled" className={`min-w-0 ${presentation.toggleDisabled ? "cursor-default" : "cursor-pointer"}`}>
        <span className="flex flex-wrap items-center gap-2">
          <span className="font-medium text-ink">{t("settingsNotifications.autoImportToggle")}</span>
          <span className={`rounded-full px-2 py-0.5 text-xs ${statusClassName}`}>{presentation.status}</span>
        </span>
        <span id="web-push-description" className="mt-1 block max-w-2xl text-sm leading-6 text-olive">{presentation.description}</span>
      </label>
      <span className="grid size-11 shrink-0 place-items-center md:size-10">
        <Switch
          id="web-push-enabled"
          className="transition-[background-color,transform] active:scale-95 motion-reduce:transition-none motion-reduce:active:scale-100"
          checked={state.subscribed}
          disabled={presentation.toggleDisabled}
          aria-describedby="web-push-description"
          onCheckedChange={(checked) => void updateSubscription(checked)}
        />
      </span>
    </div>

    <div className="mt-3 flex min-h-10 flex-wrap items-center gap-3">
      {presentation.testAvailable && <button type="button" className="inline-flex h-10 items-center gap-2 rounded-md bg-brand px-3.5 text-sm font-medium text-paper disabled:opacity-50" disabled={state.loading} onClick={() => void sendTest()}>
        <Send className="h-4 w-4" aria-hidden="true" />
        {t("settingsNotifications.sendTest")}
      </button>}
      <button type="button" className="inline-flex h-10 items-center gap-2 rounded-md border border-line bg-panel px-3.5 text-sm font-medium text-brand hover:bg-tag disabled:opacity-50" disabled={state.loading} onClick={() => void refresh()}>
        <RotateCcw className={`h-4 w-4 ${state.loading ? "animate-spin" : ""}`} aria-hidden="true" />
        {state.loading ? t("settingsNotifications.checking") : t("settingsNotifications.recheck")}
      </button>
      {state.error && <span className="text-sm text-[var(--danger)]">{state.error}</span>}
    </div>
  </section>;
}

function ApiEndpointSettingsPanel({ headingId, showToast }: { headingId: string; showToast: ToastFn }) {
  const { t } = useTranslation();
  const [settings, setSettings] = useState<ApiEndpointSettings>(() => readApiEndpointSettings());
  const [draftUrl, setDraftUrl] = useState("");
  const [testingId, setTestingId] = useState<string | null>(null);
  const [probeResults, setProbeResults] = useState<Record<string, ApiEndpointProbeResult>>({});
  const [, setHealthRevision] = useState(0);

  useEffect(() => {
    const refresh = () => setHealthRevision((value) => value + 1);
    window.addEventListener(apiEndpointHealthChangeEvent, refresh);
    return () => window.removeEventListener(apiEndpointHealthChangeEvent, refresh);
  }, []);

  function save(next: ApiEndpointSettings, notice = "") {
    setSettings(next);
    writeApiEndpointSettings(next);
    if (notice) showToast("success", notice);
  }

  function addEndpoint() {
    try {
      const url = normalizeApiEndpointUrl(draftUrl);
      if (settings.endpoints.some((endpoint) => endpoint.url === url)) {
        showToast("info", t("settingsEndpoints.alreadyAdded"));
        return;
      }
      const endpoint = { id: createApiEndpointId(), url, enabled: true };
      const next: ApiEndpointSettings = {
        ...settings,
        endpoints: [...settings.endpoints, endpoint],
      };
      setDraftUrl("");
      save(next, t("settingsEndpoints.addedNotice"));
    } catch (error) {
      showToast("error", error instanceof Error ? error.message : t("settingsEndpoints.addFailed"));
    }
  }

  async function activateEndpoint(endpoint: ApiEndpoint) {
    if (!endpoint.enabled || endpoint.id === settings.activeId) return;
    showToast("info", t("settingsEndpoints.verifying"));
    try {
      const result = await probeApiEndpoint(endpoint);
      setProbeResults((current) => ({ ...current, [endpoint.id]: result }));
      const verified = applyApiEndpointProbe(settings, endpoint.id, result);
      const next = withActiveApiEndpoint(verified, endpoint.id);
      if (next.activeId !== endpoint.id) throw new Error(t("settingsEndpoints.incompatible"));
      save(next, t("settingsEndpoints.switchedNotice"));
    } catch (error) {
      showToast("error", error instanceof Error ? error.message : t("settingsEndpoints.switchFailed"));
    }
  }

  function updateEndpoint(id: string, update: Partial<ApiEndpoint>) {
    const nextEndpoints = settings.endpoints.map((endpoint) => endpoint.id === id ? { ...endpoint, ...update } : endpoint);
    const activeStillEnabled = nextEndpoints.some((endpoint) => endpoint.id === settings.activeId && endpoint.enabled);
    save({ ...settings, activeId: activeStillEnabled ? settings.activeId : nextEndpoints.find((endpoint) => endpoint.enabled)?.id ?? settings.endpoints[0].id, endpoints: nextEndpoints });
  }

  function moveEndpoint(id: string, direction: -1 | 1) {
    const index = settings.endpoints.findIndex((endpoint) => endpoint.id === id);
    const nextIndex = index + direction;
    if (index <= 0 || nextIndex <= 0 || nextIndex >= settings.endpoints.length) return;
    const nextEndpoints = [...settings.endpoints];
    const [endpoint] = nextEndpoints.splice(index, 1);
    nextEndpoints.splice(nextIndex, 0, endpoint);
    save({ ...settings, endpoints: nextEndpoints });
  }

  function removeEndpoint(id: string) {
    const nextEndpoints = settings.endpoints.filter((endpoint) => endpoint.id !== id || isSameOriginApiEndpoint(endpoint));
    const nextActiveId = nextEndpoints.some((endpoint) => endpoint.id === settings.activeId) ? settings.activeId : nextEndpoints[0].id;
    save({ ...settings, activeId: nextActiveId, endpoints: nextEndpoints }, t("settingsEndpoints.removedNotice"));
  }

  async function testEndpoint(endpoint: ApiEndpoint) {
    if (testingId || !endpoint.enabled) return;
    setTestingId(endpoint.id);
    try {
      const result = await probeApiEndpoint(endpoint);
      let compatibleResult = result;
      if (result.ok) {
        try {
          const next = applyApiEndpointProbe(settings, endpoint.id, result);
          save(next, t("settingsEndpoints.testComplete", { label: endpointLabel(endpoint), ms: result.latencyMs }));
        } catch (error) {
          compatibleResult = { ...result, ok: false, error: error instanceof Error ? error.message : t("settingsEndpoints.incompatibleShort") };
          showToast("error", compatibleResult.error ?? t("settingsEndpoints.incompatibleShort"));
        }
      } else {
        showToast("error", result.error ?? t("settingsEndpoints.testFailed"));
      }
      setProbeResults((current) => ({ ...current, [endpoint.id]: compatibleResult }));
    } finally {
      setTestingId(null);
    }
  }

  return <section className={SETTINGS_SECTION_CLASS}>
    <div className="flex flex-col gap-4 border-b border-line pb-4 md:flex-row md:items-start md:justify-between">
      <div>
        <h1 id={headingId} className="text-2xl font-semibold tracking-[-0.02em] text-ink">{t("settingsEndpoints.title")}</h1>
        <p className="mt-2 max-w-2xl text-sm leading-6 text-olive">{t("settingsEndpoints.desc")}</p>
      </div>
    </div>
    <div className="mt-6 grid gap-3 md:grid-cols-[minmax(0,1fr)_auto]">
        <input className="h-11 min-w-0 rounded-md border border-line bg-panel px-3 text-ink" value={draftUrl} onChange={(event) => setDraftUrl(event.target.value)} onKeyDown={(event) => event.key === "Enter" && void addEndpoint()} placeholder="https://api.example.com" />
      <button type="button" className="inline-flex h-11 items-center justify-center gap-2 rounded-md border border-line bg-panel px-4 text-sm font-medium text-brand hover:bg-tag" onClick={() => void addEndpoint()}>
        <Plus className="h-4 w-4" />
        {t("settingsEndpoints.add")}
      </button>
    </div>
    <div className="mt-6 divide-y divide-line border-y border-line">
      {settings.endpoints.map((endpoint, index) => {
        const active = endpoint.id === settings.activeId;
        const sameOrigin = isSameOriginApiEndpoint(endpoint);
        const knownAuthentication = hasKnownApiEndpointAuthentication(endpoint.id);
        const result = probeResults[endpoint.id];
        return <div key={endpoint.id} className={`p-3 ${active ? "bg-[var(--selected-bg)]" : "bg-panel"}`}>
          <div className="flex flex-col gap-3 lg:flex-row lg:items-center">
            <button type="button" className="flex min-w-0 flex-1 items-center gap-3 text-left" onClick={() => void activateEndpoint(endpoint)} disabled={!endpoint.enabled}>
              <span className={`grid h-7 w-7 shrink-0 place-items-center rounded-full ${active ? "bg-brand text-paper" : "bg-tag text-brand"}`}>{active ? <Check className="h-4 w-4" /> : <span className="h-2 w-2 rounded-full bg-current" />}</span>
              <span className="min-w-0">
                <span className="flex flex-wrap items-center gap-2">
                  <span className="font-medium text-ink">{sameOrigin ? t("settingsEndpoints.currentSite") : endpoint.label || t("settingsEndpoints.backupEndpoint", { index })}</span>
                  {active && <span className="rounded-full bg-brand px-2 py-0.5 text-xs text-paper">{t("settingsEndpoints.default")}</span>}
                  {!active && endpoint.enabled && <span className={`rounded-full px-2 py-0.5 text-xs ${knownAuthentication ? "bg-brand/10 text-brand" : "bg-tag text-stone"}`}>{knownAuthentication ? t("settingsEndpoints.fullTakeover") : t("settingsEndpoints.needsLogin")}</span>}
                  {!endpoint.enabled && <span className="rounded-full bg-tag px-2 py-0.5 text-xs text-stone">{t("settingsEndpoints.disabled")}</span>}
                </span>
                <span className="mt-1 block break-all text-sm leading-6 text-olive">{displayApiEndpointUrl(endpoint)}</span>
              </span>
            </button>
            <div className="flex shrink-0 flex-wrap items-center gap-2">
              <EndpointProbeBadge result={result} endpointId={endpoint.id} t={t} />
              <button type="button" className="inline-flex h-10 items-center gap-1.5 rounded-md border border-line px-3 text-sm text-olive hover:bg-tag disabled:opacity-50" disabled={!endpoint.enabled || testingId !== null} onClick={() => void testEndpoint(endpoint)}>
                {testingId === endpoint.id ? <RotateCcw className="h-4 w-4 animate-spin" /> : <Zap className="h-4 w-4" />}
                {t("settingsEndpoints.speedTest")}
              </button>
              <IconButton label={t("settingsEndpoints.moveUp")} disabled={sameOrigin || index <= 1} onClick={() => moveEndpoint(endpoint.id, -1)}><ArrowUp className="h-4 w-4" /></IconButton>
              <IconButton label={t("settingsEndpoints.moveDown")} disabled={sameOrigin || index === settings.endpoints.length - 1} onClick={() => moveEndpoint(endpoint.id, 1)}><ArrowDown className="h-4 w-4" /></IconButton>
              <button type="button" className="h-10 rounded-md border border-line px-3 text-sm text-olive hover:bg-tag disabled:opacity-50" disabled={sameOrigin || active} onClick={() => updateEndpoint(endpoint.id, { enabled: !endpoint.enabled })}>{endpoint.enabled ? t("settingsEndpoints.disabled") : t("settingsEndpoints.enable")}</button>
              <IconButton label={t("settingsEndpoints.remove")} disabled={sameOrigin} onClick={() => removeEndpoint(endpoint.id)}><Minus className="h-4 w-4" /></IconButton>
            </div>
          </div>
        </div>;
      })}
    </div>
    <p className="mt-3 text-xs leading-5 text-stone">{t("settingsEndpoints.footerHint")}</p>
  </section>;
}

function endpointLabel(endpoint?: ApiEndpoint) {
  if (!endpoint) return i18n.t("settingsEndpoints.unknownBackend");
  return apiEndpointLabel(endpoint);
}

function EndpointProbeBadge({ result, endpointId, t }: { result?: ApiEndpointProbeResult; endpointId: string; t: (key: string) => string }) {
  const runtime = apiEndpointRuntimeStatus(endpointId);
  if (runtime.cooldownUntil && runtime.cooldownUntil > Date.now()) return <span className="rounded-full bg-[var(--danger)]/10 px-2 py-1 text-xs text-[var(--danger)]">{t("settingsEndpoints.coolingDown")}</span>;
  if (runtime.reachable && runtime.latencyMs) return <span className="rounded-full bg-brand/10 px-2 py-1 text-xs text-brand">{runtime.latencyMs}ms</span>;
  if (!result) return <span className="rounded-full bg-tag px-2 py-1 text-xs text-stone">{t("settingsEndpoints.notTested")}</span>;
  if (result.ok) return <span className="rounded-full bg-brand/10 px-2 py-1 text-xs text-brand">{result.latencyMs}ms</span>;
  return <span className="max-w-[12rem] truncate rounded-full bg-[var(--danger)]/10 px-2 py-1 text-xs text-[var(--danger)]" title={result.error}>{result.error ?? t("settingsEndpoints.unavailable")}</span>;
}

function IconButton({ label, disabled, onClick, children }: { label: string; disabled?: boolean; onClick: () => void; children: ReactNode }) {
  return <button type="button" className="grid h-10 w-10 place-items-center rounded-md border border-line bg-paper text-olive hover:bg-tag disabled:opacity-40" aria-label={label} title={label} disabled={disabled} onClick={onClick}>{children}</button>;
}

function QuickUnlockSettings({ headingId, enabled, mode: initialMode, sensitiveUnlocked, onEnable, onDisable, showToast }: { headingId: string; enabled: boolean; mode: QuickUnlockMode; sensitiveUnlocked: boolean; onEnable: (secret: string, mode: QuickUnlockMode) => void | Promise<void>; onDisable: () => void | Promise<void>; showToast: ToastFn }) {
  const { t } = useTranslation();
  const [mode, setMode] = useState<QuickUnlockMode>(initialMode);
  const [secret, setSecret] = useState("");
  const [confirm, setConfirm] = useState("");
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    setMode(initialMode);
  }, [initialMode]);

  function updateSecret(value: string) {
    setSecret(mode === "numeric" ? value.replace(/\D+/g, "") : value);
  }

  function updateConfirm(value: string) {
    setConfirm(mode === "numeric" ? value.replace(/\D+/g, "") : value);
  }

  async function submit() {
    if (saving) return;
    if (!sensitiveUnlocked) {
      showToast("error", t("settingsQuickUnlock.unlockFirst"));
      return;
    }
    if (!secret) {
      showToast("error", mode === "numeric" ? t("settingsQuickUnlock.enterCode") : t("settingsQuickUnlock.enterPassphrase"));
      return;
    }
    if (secret !== confirm) {
      showToast("error", t("settingsQuickUnlock.mismatch"));
      return;
    }
    setSaving(true);
    try {
      await onEnable(secret, mode);
      setSecret("");
      setConfirm("");
    } catch (error) {
      showToast("error", error instanceof Error ? error.message : t("settingsQuickUnlock.enableFailed"));
    } finally {
      setSaving(false);
    }
  }

  async function disable() {
    if (saving) return;
    setSaving(true);
    try {
      await onDisable();
    } catch (error) {
      showToast("error", error instanceof Error ? error.message : t("settingsQuickUnlock.disableFailed"));
    } finally {
      setSaving(false);
    }
  }

  return <section className={SETTINGS_SECTION_CLASS}>
    <div className="border-b border-line pb-4">
      <h1 id={headingId} className="text-2xl font-semibold tracking-[-0.02em] text-ink">{t("settingsQuickUnlock.title")}</h1>
      <p className="mt-2 max-w-2xl text-sm leading-6 text-olive">{enabled ? t("settingsQuickUnlock.enabledDesc") : t("settingsQuickUnlock.disabledDesc")}</p>
    </div>
    <div className="mt-6 grid gap-3 md:grid-cols-[minmax(0,14rem)_1fr_1fr_auto]">
      <div className="grid grid-cols-2 overflow-hidden rounded-xl border border-line bg-panel p-1">
        {(["numeric", "text"] as const).map((item) => <button
          key={item}
          type="button"
          className={`h-10 rounded text-sm ${mode === item ? "bg-brand text-paper" : "text-warm hover:bg-tag"}`}
          onClick={() => {
            setMode(item);
            setSecret("");
            setConfirm("");
          }}
          disabled={!sensitiveUnlocked || saving}
        >
          {item === "numeric" ? t("settingsQuickUnlock.numeric") : t("settingsQuickUnlock.text")}
        </button>)}
      </div>
      <input type="password" inputMode={mode === "numeric" ? "numeric" : "text"} className="h-11 rounded-md border border-line bg-panel px-3 text-ink" value={secret} onChange={(event) => updateSecret(event.target.value)} placeholder={mode === "numeric" ? t("settingsQuickUnlock.numericPlaceholder") : t("settingsQuickUnlock.textPlaceholder")} disabled={!sensitiveUnlocked || saving} />
      <input type="password" inputMode={mode === "numeric" ? "numeric" : "text"} className="h-11 rounded-md border border-line bg-panel px-3 text-ink" value={confirm} onChange={(event) => updateConfirm(event.target.value)} placeholder={t("settingsQuickUnlock.confirmPlaceholder")} disabled={!sensitiveUnlocked || saving} onKeyDown={(event) => event.key === "Enter" && void submit()} />
      <button type="button" className="h-11 rounded-md bg-brand px-4 text-paper disabled:opacity-50" disabled={!sensitiveUnlocked || saving} onClick={() => void submit()}>{saving ? t("settingsRuntime.saving") : enabled ? t("settingsQuickUnlock.update") : t("settingsQuickUnlock.enable")}</button>
    </div>
    <div className="mt-3 flex flex-wrap items-center gap-3 text-xs text-stone">
      <span>{mode === "numeric" ? t("settingsQuickUnlock.numericModeHint") : t("settingsQuickUnlock.textModeHint")}</span>
      {enabled && <button type="button" className="text-brand disabled:opacity-50" disabled={saving} onClick={() => void disable()}>{t("settingsQuickUnlock.disable")}</button>}
    </div>
    {!sensitiveUnlocked && <p className="mt-3 text-xs text-stone">{t("settingsQuickUnlock.lockedHint")}</p>}
  </section>;
}

function LocalAccessPanel({ headingId }: { headingId: string }) {
  const { t } = useTranslation();
  const [state, setState] = useState<LocalAccessState | null>(() => readLocalAccessState());

  useEffect(() => {
    const sync = () => setState(readLocalAccessState());
    sync();
    const media = window.matchMedia("(display-mode: standalone)");
    media.addEventListener("change", sync);
    return () => media.removeEventListener("change", sync);
  }, []);

  if (!state) return <section className={SETTINGS_SECTION_CLASS}>
    <h1 id={headingId} className="text-2xl font-semibold tracking-[-0.02em] text-ink">{t("settingsLocalAccess.title")}</h1>
    <p className="mt-3 text-sm text-stone">{t("settingsLocalAccess.loading")}</p>
  </section>;

  const accessLabel = state.localOnly ? t("settingsLocalAccess.localOnly") : state.privateLan ? t("settingsLocalAccess.lan") : t("settingsLocalAccess.publicTunnel");
  const readiness = state.secure
    ? t("settingsLocalAccess.secureReady")
    : t("settingsLocalAccess.notSecure");
  const phoneHint = state.localOnly
    ? t("settingsLocalAccess.phoneLocalHint")
    : state.privateLan
      ? t("settingsLocalAccess.phoneLanHint")
      : t("settingsLocalAccess.phonePublicHint");

  return <section className={SETTINGS_SECTION_CLASS}>
    <div className="border-b border-line pb-4">
      <h1 id={headingId} className="text-2xl font-semibold tracking-[-0.02em] text-ink">{t("settingsLocalAccess.title")}</h1>
      <p className="mt-2 max-w-2xl text-sm leading-6 text-olive">{phoneHint}</p>
    </div>
    <div className="mt-6 grid gap-px border-y border-line bg-line md:grid-cols-3">
      <StatusTile title={t("settingsLocalAccess.currentOrigin")} value={state.origin} />
      <StatusTile title={t("settingsLocalAccess.accessScope")} value={accessLabel} />
      <StatusTile title={t("settingsLocalAccess.pwaMode")} value={state.standalone ? t("settingsLocalAccess.standalone") : t("settingsLocalAccess.browserTab")} />
    </div>
    <div className={`mt-4 rounded-xl border px-4 py-3 text-sm leading-6 ${state.secure ? "border-brand/30 bg-brand/10 text-brand" : "border-[var(--danger)]/30 bg-[var(--danger)]/10 text-[var(--danger)]"}`}>
      {readiness}
    </div>
    <a className="mt-4 inline-flex min-h-11 items-center rounded-md border border-line bg-panel px-3 py-2 text-sm text-brand transition-transform active:scale-95 motion-reduce:transition-none motion-reduce:active:scale-100 hover:bg-tag" href="https://github.com/qiaoborui/beancount-ledger-web/blob/main/docs/local-first-pwa.md" target="_blank" rel="noreferrer">
      {t("settingsLocalAccess.openGuide")}
    </a>
  </section>;
}

function StatusTile({ title, value }: { title: string; value: string }) {
  return <div className="bg-panel px-4 py-3">
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
    <span className="grid size-11 shrink-0 place-items-center md:size-10"><Switch id={id} className="transition-[background-color,transform] active:scale-95 motion-reduce:transition-none motion-reduce:active:scale-100" checked={checked} onCheckedChange={onChange} /></span>
  </div>;
}
