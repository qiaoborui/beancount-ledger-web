"use client";

import { lazy, Suspense, useCallback, useEffect, useMemo, useRef, useState, useTransition, type ComponentProps } from "react";
import { createPortal } from "react-dom";
import { RefreshCw, WifiOff, X } from "lucide-react";
import { AppShell, ledgerNavItems } from "./AppShell";
import { useBrowserLocation, useBrowserRouter } from "@/lib/browserRouter";
import { makeTimeRange, navigateTimeRange, formatTimeRangeLabel } from "@/lib/timeRange";
import type { TimeRange, TimePreset } from "@/lib/timeRange";
import { defaultMobileTabHrefs, readMobileTabHrefs, writeMobileTabHrefs } from "./ledger/storage";
import { useEntryActions } from "./ledger/hooks/useEntryActions";
import { useLedgerAuth } from "./ledger/hooks/useLedgerAuth";
import { fetchLedgerIndexInfo, useLedgerData } from "./ledger/hooks/useLedgerData";
import type { LedgerIndexInfo } from "./ledger/types";
import { useLedgerDerivedData } from "./ledger/hooks/useLedgerDerivedData";
import { useLedgerLock } from "./ledger/hooks/useLedgerLock";
import { useLedgerMutations } from "./ledger/hooks/useLedgerMutations";
import { usePrivacySettings } from "./ledger/hooks/usePrivacySettings";
import { useNetworkStatus } from "./ledger/hooks/useNetworkStatus";
import { usePullToRefresh } from "./ledger/hooks/usePullToRefresh";
import { usePendingLedgerWrites } from "./ledger/hooks/usePendingLedgerWrites";
import { applyPendingLedgerOperations } from "./ledger/pendingLedgerOperations";
import { shouldOfferHeaderSensitiveUnlock } from "./ledger/headerUnlock";
import { hasKnownLedgerAuthentication, readInitialLedgerAuthState } from "./ledger/authState";
import { enableOfflineLedgerUnlock, hasOfflineLedgerUnlock } from "./ledger/offlineUnlock";
import { enableQuickLedgerUnlock, getQuickLedgerUnlockMode, hasQuickLedgerUnlock, revokeQuickLedgerUnlock, type QuickUnlockMode } from "./ledger/quickUnlock";
import { useRouteScrollMemory } from "./ledger/hooks/useRouteScrollMemory";
import { useSwipeBack } from "./ledger/hooks/useSwipeBack";
import { useThemeMode } from "./ledger/hooks/useThemeMode";
import { useToast } from "./ledger/hooks/useToast";
import { AppSkeleton, LoginScreen, PasskeyBanner, SensitiveUnlockPanel } from "./ledger/AuthScreens";
import type { CommandAction } from "./ledger/CommandPalette";
import { HomePage } from "./ledger/HomePage";
import { Toast } from "./ledger/shared";
import { haptic } from "./ledger/haptics";
import {
  loadAccountDetailPage,
  loadAccountPanels,
  loadAiBookkeepingChat,
  loadCommandPalette,
  loadCurrencyPage,
  loadDashboardPage,
  loadEntryModal,
  loadImportPage,
  loadIncomeStatementPage,
  loadInvestmentsPage,
  loadLedgerEditorPage,
  loadNetWorthPage,
  loadQuickActionsSheet,
  loadReconcilePage,
  loadSettingsPage,
  loadTransactionList,
  preloadOfflineCoreRoutes,
  preloadLedgerRoute,
} from "./ledger/routePreload";
import type { LedgerNavHref, LedgerPage } from "./ledger/types";

const LazyNetWorthPage = lazy(() => loadNetWorthPage().then((mod) => ({ default: mod.NetWorthPage })));

const LazyIncomeStatementPage = lazy(() => loadIncomeStatementPage().then((mod) => ({ default: mod.IncomeStatementPage })));
const LazyInvestmentsPage = lazy(() => loadInvestmentsPage().then((mod) => ({ default: mod.InvestmentsPage })));

const LazyDashboardPage = lazy(() => loadDashboardPage().then((mod) => ({ default: mod.DashboardPage })));

const LazyAiBookkeepingChat = lazy(() => loadAiBookkeepingChat().then((mod) => ({ default: mod.AiBookkeepingChat })));

const LazyCommandPalette = lazy(() => loadCommandPalette().then((mod) => ({ default: mod.CommandPalette })));
const LazyEntryModal = lazy(() => loadEntryModal().then((mod) => ({ default: mod.EntryModal })));
const LazyEntryPanel = lazy(() => loadEntryModal().then((mod) => ({ default: mod.EntryPanel })));
const LazyQuickActionsSheet = lazy(() => loadQuickActionsSheet().then((mod) => ({ default: mod.QuickActionsSheet })));
const LazyImportPage = lazy(() => loadImportPage().then((mod) => ({ default: mod.ImportPage })));
const LazyLedgerEditorPage = lazy(() => loadLedgerEditorPage().then((mod) => ({ default: mod.LedgerEditorPage })));
const LazyAccountDetailPage = lazy(() => loadAccountDetailPage().then((mod) => ({ default: mod.AccountDetailPage })));
const LazyCurrencyPage = lazy(() => loadCurrencyPage().then((mod) => ({ default: mod.CurrencyPage })));
const LazyReconcilePage = lazy(() => loadReconcilePage().then((mod) => ({ default: mod.ReconcilePage })));
const LazySettingsPage = lazy(() => loadSettingsPage().then((mod) => ({ default: mod.SettingsPage })));
const LazyTransactionList = lazy(() => loadTransactionList().then((mod) => ({ default: mod.TransactionList })));
const LazyAccountManager = lazy(() => loadAccountPanels().then((mod) => ({ default: mod.AccountManager })));
const LazyBalanceGrid = lazy(() => loadAccountPanels().then((mod) => ({ default: mod.BalanceGrid })));
const LazyCreditCardPanel = lazy(() => loadAccountPanels().then((mod) => ({ default: mod.CreditCardPanel })));

function NetWorthPage(props: ComponentProps<typeof LazyNetWorthPage>) {
  return <Suspense fallback={<section className="card p-6 text-sm text-stone">正在准备净资产图表…</section>}><LazyNetWorthPage {...props} /></Suspense>;
}

function InvestmentsPage(props: ComponentProps<typeof LazyInvestmentsPage>) {
  return <Suspense fallback={<section className="card p-6 text-sm text-stone">正在准备股票持仓…</section>}><LazyInvestmentsPage {...props} /></Suspense>;
}

function IncomeStatementPage(props: ComponentProps<typeof LazyIncomeStatementPage>) {
  return <Suspense fallback={<section className="card p-6 text-sm text-stone">正在准备损益分析…</section>}><LazyIncomeStatementPage {...props} /></Suspense>;
}

function DashboardPage(props: ComponentProps<typeof LazyDashboardPage>) {
  return <Suspense fallback={<section className="card p-6 text-sm text-stone">正在准备看板…</section>}><LazyDashboardPage {...props} /></Suspense>;
}

function AiBookkeepingChat(props: ComponentProps<typeof LazyAiBookkeepingChat>) {
  return <Suspense fallback={null}><LazyAiBookkeepingChat {...props} /></Suspense>;
}

function RouteFallback({ label }: { label: string }) {
  return <section className="card p-6 text-sm text-stone">{label}</section>;
}

function pageFromPathname(pathname: string): LedgerPage {
  if (pathname.startsWith("/dashboard")) return "dashboard";
  if (pathname.startsWith("/net-worth")) return "net-worth";
  if (pathname.startsWith("/investments")) return "investments";
  if (pathname.startsWith("/transactions")) return "transactions";
  if (pathname.startsWith("/imports")) return "imports";
  if (pathname.startsWith("/editor")) return "editor";
  if (pathname.startsWith("/reconcile")) return "reconcile";
  if (pathname.startsWith("/settings")) return "settings";
  if (pathname.startsWith("/income-statement")) return "income-statement";
  if (pathname.startsWith("/currencies")) return "currencies";
  if (pathname.startsWith("/accounts")) return "accounts";
  return "home";
}

/** 从路径提取账户详情参数，如 /accounts/Assets:Bank:Checking → Assets:Bank:Checking */
function accountFromPathname(pathname: string): string | null {
  const match = pathname.match(/^\/accounts\/(.+)/);
  if (!match) return null;
  try {
    return decodeURIComponent(match[1]);
  } catch {
    return null;
  }
}

const TIME_PRESETS: { key: TimePreset; label: string }[] = [
  { key: "week", label: "本周" },
  { key: "month", label: "本月" },
  { key: "quarter", label: "本季" },
  { key: "year", label: "今年" },
  { key: "all", label: "全部" },
  { key: "custom", label: "自定义" },
];

const TRANSACTION_QUICK_VIEWS = [
  { id: "food", label: "本月餐饮", detail: "Expenses:Food 及子分类", category: "Expenses:Food", mode: "prefix" as const },
  { id: "unknown", label: "Unknown 待整理", detail: "精确查看 Expenses:Unknown", category: "Expenses:Unknown", mode: "exact" as const },
  { id: "reimburse", label: "报销相关", detail: "搜索报销线索", search: "报销" },
];

function isTypingTarget(target: EventTarget | null) {
  const element = target instanceof HTMLElement ? target : null;
  if (!element) return false;
  return ["INPUT", "TEXTAREA", "SELECT"].includes(element.tagName) || element.isContentEditable;
}

export function LedgerApp({ page: pageProp }: { page?: LedgerPage }) {
  const router = useBrowserRouter();
  const { pathname, search } = useBrowserLocation();
  const searchParams = useMemo(() => new URLSearchParams(search), [search]);
  const [isRoutePending, startRouteTransition] = useTransition();
  const page = pageProp ?? pageFromPathname(pathname);
  const homeSecondaryReady = useDeferredIdleReady(page === "home", 1200);
  const [authed, setAuthed] = useState<boolean | null>(() => readInitialLedgerAuthState());
  const [password, setPassword] = useState("");
  const [timeRange, setTimeRange] = useState<TimeRange>(() => makeTimeRange("month"));
  const [customStart, setCustomStart] = useState(timeRange.start);
  const [customEnd, setCustomEnd] = useState(timeRange.end);
  const { toast, setToast, showToast } = useToast();
  const online = useNetworkStatus();
  const { getScrollTop, scrollToTop } = useRouteScrollMemory(pathname);
  const { themeMode, resolvedTheme, setThemeMode } = useThemeMode();
  const {
    privacySettings,
    updatePrivacySetting,
    revealAllAmounts,
    allBalancesVisible,
    setAllBalancesVisible,
    netWorthVisible,
    setNetWorthVisible,
    incomeStatementVisible,
    setIncomeStatementVisible,
    visibleAccountMap,
    setVisibleAccountMap,
  } = usePrivacySettings();
  const valuationCurrency = privacySettings.valuationCurrency || "CNY";
  const initialCategoryQuery = searchParams.get("category") ?? "";
  const initialMetadataQuery = searchParams.get("metadata") ?? "";
  const initialSearchQuery = searchParams.get("q") ?? "";
  const initialMatchMode = searchParams.get("mode") === "exact" ? "exact" : "prefix";
  const [txnCategoryQuery, setTxnCategoryQuery] = useState(initialCategoryQuery);
  const [txnMetadataQuery, setTxnMetadataQuery] = useState(initialMetadataQuery);
  const [txnSearchQuery, setTxnSearchQuery] = useState(initialSearchQuery);
  const [categoryMatchMode, setCategoryMatchMode] = useState<"exact" | "prefix">(initialMatchMode);
  const [txnViewMode, setTxnViewMode] = useState<"compact" | "full">("compact");
  const [quickActionsOpen, setQuickActionsOpen] = useState(false);
  const [commandOpen, setCommandOpen] = useState(false);
  const [aiOpenSignal, setAiOpenSignal] = useState(0);
  const [aiChatMounted, setAiChatMounted] = useState(false);
  const [indexInfo, setIndexInfo] = useState<LedgerIndexInfo | null>(null);
  const [creditSummaryVisible, setCreditSummaryVisible] = useState(true);
  const [passkeyRegistered, setPasskeyRegistered] = useState<boolean | null>(null);
  const [quickUnlockEnabled, setQuickUnlockEnabled] = useState(() => hasQuickLedgerUnlock());
  const [quickUnlockMode, setQuickUnlockMode] = useState<QuickUnlockMode>(() => getQuickLedgerUnlockMode());
  const [showUnlockModal, setShowUnlockModal] = useState(false);
  const [unlocking, setUnlocking] = useState(false);
  const [offlineUnlockEnabled, setOfflineUnlockEnabled] = useState(() => hasOfflineLedgerUnlock());
  const [offlineUnlockSecret, setOfflineUnlockSecret] = useState("");
  const offlineUnlockInputRef = useRef<HTMLInputElement | null>(null);
  const [mobileTabHrefs, setMobileTabHrefs] = useState<LedgerNavHref[]>(defaultMobileTabHrefs);
  const hasPasskey = passkeyRegistered === true;
  const passkeyStatusLoaded = passkeyRegistered !== null;
  useEffect(() => {
    fetchLedgerIndexInfo().then(setIndexInfo).catch(() => setIndexInfo(null));
  }, []);

  const { unlocked, setUnlocked } = useLedgerLock({ passkeyRegistered: hasPasskey, authed });
  useEffect(() => {
    if (unlocked) revealAllAmounts();
  }, [revealAllAmounts, unlocked]);

  useEffect(() => {
    if (!authed || !online) return;
    let idleId: number | null = null;
    let timeoutId: number | null = null;
    const preload = () => preloadOfflineCoreRoutes();
    timeoutId = window.setTimeout(() => {
      if (window.requestIdleCallback) idleId = window.requestIdleCallback(preload, { timeout: 6000 });
      else preload();
    }, 2500);
    return () => {
      if (timeoutId != null) window.clearTimeout(timeoutId);
      if (idleId != null) {
        if (window.cancelIdleCallback) window.cancelIdleCallback(idleId);
        else window.clearTimeout(idleId);
      }
    };
  }, [authed, online]);

  const handleSensitiveLocked = useCallback(() => {
    sessionStorage.removeItem("ledger_unlocked");
    sessionStorage.setItem("ledger_locked_at", String(Date.now()));
    setUnlocked(false);
  }, [setUnlocked]);

  const lockSensitive = useCallback(async () => {
    handleSensitiveLocked();
    try {
      await fetch("/api/auth/lock", { method: "POST" });
    } catch {
      showToast("error", "已在本机隐藏敏感数据，但服务端锁定请求失败；请刷新后确认。");
    }
  }, [handleSensitiveLocked, showToast]);
  const {
    summary,
    balances,
    accountBalances,
    txns,
    netWorthRows,
    reconciliationRows,
    accounts,
    incomeStatement,
    accountStatuses,
    monthEndNetWorthRows,
    netWorthWindows,
    creditCards,
    commodities,
    prices,
    investments,
    loadingFresh,
    refreshing,
    lastSyncedAt,
    ledgerVersion,
    load,
    unlockOfflineSensitiveCache,
    refreshLedger,
  } = useLedgerData({
    timeRange,
    unlocked,
    valuationCurrency,
    onSensitiveLocked: handleSensitiveLocked,
    onSensitiveUnlockChange: setUnlocked,
    onAuthChange: setAuthed,
    onPasskeyRegistered: setPasskeyRegistered,
    showToast,
  });

  const { login, loginWithPasskey, loginWithQuickUnlock, registerPasskey } = useLedgerAuth({
    password,
    setPassword,
    setAuthed,
    setUnlocked,
    setPasskeyRegistered,
    load,
    showToast,
    clearToast: () => setToast(null),
  });

  const { pendingOperations, pendingWriteCount, pendingWriteSummary, enqueuePendingWrites, enqueueTransactionUpdate, enqueueTransactionDelete, syncPendingWrites, syncingPendingWrites } = usePendingLedgerWrites({ load, showToast, ledgerVersion });
  const { nl, setNl, previews, parseStatus, parseMessage, appendStatus, entryOpen, setEntryOpen, manual, setManual, parseNl, previewManualEntry, removePreview, appendPreviews, appendEntry } = useEntryActions({ load, showToast, enqueuePendingWrites });
  const { updateTransaction, deleteTransaction, reverseTransaction, reconcileAccount } = useLedgerMutations({ appendEntry, load, showToast, enqueuePendingWrites, enqueueTransactionUpdate, enqueueTransactionDelete });
  const { accountLabelMap, accountPageAccounts, expenseAccounts, incomeAccounts, paymentAccounts, visibleBalances, netWorthChart } = useLedgerDerivedData({ summary, accounts, balances, accountBalances, netWorthRows, page, valuationCurrency });
  const dataValuationCurrency = summary?.currency ?? incomeStatement?.valuationCurrency ?? valuationCurrency;
  const incomeStatementCurrency = incomeStatement?.valuationCurrency ?? dataValuationCurrency;
  const projectedTxns = useMemo(() => applyPendingLedgerOperations(txns, pendingOperations, timeRange), [pendingOperations, timeRange, txns]);
  const { handleTouchStart, handleTouchMove, handleTouchEnd, pullDistance, pullState } = usePullToRefresh(refreshLedger, refreshing || loadingFresh);
  const detailAccount = page === "accounts" ? accountFromPathname(pathname) : null;
  useSwipeBack({ enabled: Boolean(detailAccount), onBack: () => router.push("/accounts") });

  function setPreset(preset: TimePreset) {
    if (preset === "custom") {
      const range: TimeRange = { start: timeRange.start, end: timeRange.end, preset: "custom" };
      setCustomStart(range.start);
      setCustomEnd(range.end);
      setTimeRange(range);
    } else {
      setTimeRange(makeTimeRange(preset));
    }
  }

  function applyCustomRange() {
    const range: TimeRange = { start: customStart, end: customEnd, preset: "custom" };
    setTimeRange(range);
  }

  useEffect(() => {
    setMobileTabHrefs(readMobileTabHrefs());
  }, []);

  function updateMobileTabHrefs(hrefs: LedgerNavHref[]) {
    const next = Array.from(new Set(hrefs)).slice(0, 5);
    setMobileTabHrefs(next);
    writeMobileTabHrefs(next);
    window.dispatchEvent(new Event("ledger-mobile-tabs-change"));
  }

  async function enableOfflineUnlock(secret: string) {
    await enableOfflineLedgerUnlock(secret);
    setOfflineUnlockEnabled(true);
    showToast("success", "离线解锁已启用，正在写入加密缓存");
    await load(true);
  }

  async function enableQuickUnlock(secret: string, mode: QuickUnlockMode) {
    await enableQuickLedgerUnlock(secret, mode);
    setQuickUnlockEnabled(true);
    setQuickUnlockMode(mode);
    showToast("success", "本机快速解锁已启用");
  }

  async function disableQuickUnlock() {
    await revokeQuickLedgerUnlock();
    setQuickUnlockEnabled(false);
    setQuickUnlockMode(getQuickLedgerUnlockMode());
    showToast("success", "本机快速解锁已关闭");
  }

  const searchKey = searchParams.toString();
  const shortcutAction = searchParams.get("action");

  useEffect(() => {
    if (page !== "transactions") return;
    setTxnCategoryQuery(searchParams.get("category") ?? "");
    setTxnMetadataQuery(searchParams.get("metadata") ?? "");
    setTxnSearchQuery(searchParams.get("q") ?? "");
    setCategoryMatchMode(searchParams.get("mode") === "exact" ? "exact" : "prefix");
  }, [page, searchKey, searchParams]);

  useEffect(() => {
    if (page !== "transactions") return;
    const id = window.setTimeout(() => {
      const params = new URLSearchParams(searchParams.toString());
      const setOrDelete = (key: string, value: string) => {
        if (value) params.set(key, value);
        else params.delete(key);
      };
      setOrDelete("category", txnCategoryQuery.trim());
      setOrDelete("metadata", txnMetadataQuery.trim());
      setOrDelete("q", txnSearchQuery.trim());
      if (categoryMatchMode === "exact") params.set("mode", "exact");
      else params.delete("mode");
      const query = params.toString();
      if (query === searchKey) return;
      router.replace(query ? `${pathname}?${query}` : pathname, { scroll: false });
    }, 180);
    return () => window.clearTimeout(id);
  }, [categoryMatchMode, page, pathname, router, searchKey, searchParams, txnCategoryQuery, txnMetadataQuery, txnSearchQuery]);

  useEffect(() => {
    if (!authed || !shortcutAction) return;
    haptic(8);
    if (shortcutAction === "quick-entry" || shortcutAction === "new-entry") setEntryOpen(true);
    if (shortcutAction === "ai-entry") {
      setAiChatMounted(true);
      setAiOpenSignal((value) => value + 1);
    }
    if (shortcutAction === "quick-actions") {
      void loadQuickActionsSheet();
      setQuickActionsOpen(true);
    }
    if (shortcutAction === "sync-pending") void syncPendingWrites();

    const params = new URLSearchParams(searchParams.toString());
    params.delete("action");
    const query = params.toString();
    router.replace(query ? `${pathname}?${query}` : pathname, { scroll: false });
  }, [authed, pathname, router, searchParams, shortcutAction, syncPendingWrites]);

  function openCategoryTransactions(account: string, mode: "exact" | "prefix" = "prefix") {
    const params = new URLSearchParams();
    params.set("category", account);
    if (mode === "exact") params.set("mode", "exact");
    preloadLedgerRoute("/transactions");
    startRouteTransition(() => {
      router.push(`/transactions?${params.toString()}`);
    });
  }

  function openTransactionsHref(href: string) {
    preloadLedgerRoute(href);
    startRouteTransition(() => {
      router.push(href);
    });
  }

  function applyTransactionQuickView(view: (typeof TRANSACTION_QUICK_VIEWS)[number]) {
    const category = ("category" in view ? view.category : "") ?? "";
    const metadata = "";
    const search = ("search" in view ? view.search : "") ?? "";
    const mode = ("mode" in view ? view.mode : "prefix") ?? "prefix";
    setTxnCategoryQuery(category);
    setTxnMetadataQuery(metadata);
    setTxnSearchQuery(search);
    setCategoryMatchMode(mode);
    const params = new URLSearchParams();
    if (category) params.set("category", category);
    if (metadata) params.set("metadata", metadata);
    if (search) params.set("q", search);
    if (mode === "exact") params.set("mode", "exact");
    const query = params.toString();
    preloadLedgerRoute("/transactions");
    startRouteTransition(() => {
      router.push(query ? `/transactions?${query}` : "/transactions");
    });
  }

  function focusTransactionSearch() {
    if (page !== "transactions") {
      preloadLedgerRoute("/transactions");
      startRouteTransition(() => router.push("/transactions"));
      window.setTimeout(() => document.getElementById("transaction-search-input")?.focus(), 220);
      return;
    }
    document.getElementById("transaction-search-input")?.focus();
  }

  useEffect(() => {
    const handleKeyDown = (event: KeyboardEvent) => {
      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "k") {
        event.preventDefault();
        void loadCommandPalette();
        setCommandOpen(true);
        return;
      }
      if (isTypingTarget(event.target)) return;
      if (event.key === "/" && page === "transactions") {
        event.preventDefault();
        focusTransactionSearch();
      }
      if (!event.metaKey && !event.ctrlKey && !event.altKey && event.key.toLowerCase() === "n") {
        event.preventDefault();
        openManualEntry();
      }
      if (event.altKey && (event.key === "ArrowLeft" || event.key === "ArrowRight")) {
        const currentHeader = pageHeader(page, timeRange);
        const canMove = currentHeader.monthScoped && timeRange.preset !== "all" && timeRange.preset !== "custom";
        if (!canMove) return;
        event.preventDefault();
        setTimeRange(navigateTimeRange(timeRange, event.key === "ArrowLeft" ? -1 : 1));
      }
    };
    window.addEventListener("keydown", handleKeyDown);
    return () => window.removeEventListener("keydown", handleKeyDown);
  }, [page, router, timeRange]);

  if (authed === null && !online && hasKnownLedgerAuthentication()) return <AppSkeleton />;
  if (authed === null && !online) return <LoginScreen password={password} setPassword={setPassword} passkeyRegistered={hasPasskey} toastText={toast?.text ?? "离线冷启动需要先联网验证一次，之后已缓存的数据才能在 PWA 中继续使用。"} onLogin={login} onPasskeyLogin={loginWithPasskey} />;
  if (authed === null) return <AppSkeleton />;
  if (!authed) return <LoginScreen password={password} setPassword={setPassword} passkeyRegistered={hasPasskey} toastText={toast?.text} onLogin={login} onPasskeyLogin={loginWithPasskey} />;

  const unlockedPrivacySettings = unlocked ? { ...privacySettings, showHomeSummaryAmounts: true } : privacySettings;
  const sensitiveMessage = toast?.kind === "error" ? toast.text : "";
  const offlineSensitiveUnlockAvailable = !online && offlineUnlockEnabled && !unlocked;
  const headerSensitiveUnlockAvailable = shouldOfferHeaderSensitiveUnlock({
    hasPasskey,
    passkeyStatusLoaded,
    quickUnlockEnabled,
    offlineSensitiveUnlockAvailable,
    online,
    unlocked,
  });
  const unlockOfflineSensitive = async () => {
    try {
      const ok = await unlockOfflineSensitiveCache(offlineUnlockSecret);
      if (ok) setOfflineUnlockSecret("");
    } catch (error) {
      showToast("error", error instanceof Error ? error.message : "离线解锁失败");
    }
  };
  const unlockQuickSensitive = async (secret: string) => {
    setUnlocking(true);
    try {
      await loginWithQuickUnlock(secret);
      setShowUnlockModal(false);
    } catch {
      // Error handled by loginWithQuickUnlock
    } finally {
      setUnlocking(false);
    }
  };
  const unlockOnlineSensitive = () => {
    if (quickUnlockEnabled) {
      setShowUnlockModal(true);
      return;
    }
    void loginWithPasskey();
  };
  const handleHeaderUnlockSensitive = () => {
    if (!offlineSensitiveUnlockAvailable) {
      unlockOnlineSensitive();
      return;
    }
    if (offlineUnlockSecret.trim()) {
      void unlockOfflineSensitive();
      return;
    }
    offlineUnlockInputRef.current?.focus();
  };
  const requireSensitiveUnlock = (title?: string, description?: string) => (
    <SensitiveUnlockPanel
      title={title}
      description={description}
      message={sensitiveMessage}
      offline={!online}
      offlineUnlockAvailable={offlineUnlockEnabled}
      offlineSecret={offlineUnlockSecret}
      onOfflineSecretChange={setOfflineUnlockSecret}
      onOfflineUnlock={() => void unlockOfflineSensitive()}
      quickUnlockEnabled={quickUnlockEnabled}
      quickUnlockMode={quickUnlockMode}
      passkeyRegistered={hasPasskey}
      onQuickUnlock={(secret) => { void unlockQuickSensitive(secret); }}
      onUnlock={loginWithPasskey}
      unlocking={unlocking}
    />
  );
  const header = pageHeader(page, timeRange);
  const canShowTimeControls = header.monthScoped;
  const canNavigate = canShowTimeControls && timeRange.preset !== "all" && timeRange.preset !== "custom";

  function handleActiveRouteTap() {
    if (getScrollTop() > 8) {
      scrollToTop(pathname);
      return;
    }
    void refreshLedger();
  }

  function openManualEntry() {
    void loadEntryModal();
    setEntryOpen(true);
  }

  function openAiEntry() {
    void loadAiBookkeepingChat();
    setAiChatMounted(true);
    setAiOpenSignal((value) => value + 1);
  }

  function openQuickActions() {
    void loadQuickActionsSheet();
    setQuickActionsOpen(true);
  }

  function openImportPage() {
    preloadLedgerRoute("/imports");
    router.push("/imports");
  }

  function openReconcilePage() {
    preloadLedgerRoute("/reconcile");
    router.push("/reconcile");
    if (!unlocked) unlockOnlineSensitive();
  }

  const offlineWriteMessage = "当前离线，写入操作会失败，请联网后再试。";
  const guardOnline = () => {
    if (online) return true;
    showToast("error", offlineWriteMessage);
    return false;
  };

  const guardedAppendPreviews = () => { appendPreviews(); };
  const guardedUpdateTransaction = (...args: Parameters<typeof updateTransaction>) => { updateTransaction(...args); };
  const guardedDeleteTransaction = (...args: Parameters<typeof deleteTransaction>) => { deleteTransaction(...args); };
  const guardedReverseTransaction = (...args: Parameters<typeof reverseTransaction>) => { if (guardOnline()) reverseTransaction(...args); };
  const guardedReconcileAccount = (...args: Parameters<typeof reconcileAccount>) => { if (guardOnline()) reconcileAccount(...args); };
  const guardedImportRefresh = () => {
    if (!guardOnline()) return;
    load(true);
  };

  const commandActions: CommandAction[] = [
    { id: "new-entry", label: "新建手动记账", detail: "打开快速记账表单", shortcut: "N", keywords: ["entry", "transaction"], run: openManualEntry },
    { id: "ai-entry", label: "AI 记账助理", detail: "用自然语言生成预览", keywords: ["ai", "chat"], run: openAiEntry },
    { id: "search-transactions", label: "搜索流水", detail: "跳到流水页并聚焦搜索框", shortcut: "/", keywords: ["transactions", "search"], run: focusTransactionSearch },
    { id: "refresh", label: "刷新账本数据", detail: "重新读取私有账本", keywords: ["sync", "reload"], run: () => { void refreshLedger(); } },
    { id: "previous-period", label: "上一周期", detail: "按当前时间范围向前移动", shortcut: "Alt ←", keywords: ["period", "month"], run: () => canNavigate && setTimeRange(navigateTimeRange(timeRange, -1)) },
    { id: "next-period", label: "下一周期", detail: "按当前时间范围向后移动", shortcut: "Alt →", keywords: ["period", "month"], run: () => canNavigate && setTimeRange(navigateTimeRange(timeRange, 1)) },
    ...ledgerNavItems.map((item) => ({ id: `nav-${item.href}`, label: `前往${item.label}`, detail: item.href, keywords: ["go", "page"], run: () => { preloadLedgerRoute(item.href); router.push(item.href); } })),
    ...TRANSACTION_QUICK_VIEWS.map((view) => ({ id: `view-${view.id}`, label: view.label, detail: view.detail, keywords: ["view", "saved", "transactions"], run: () => applyTransactionQuickView(view) })),
  ];

  return (
    <AppShell
      pathname={pathname}
      onAdd={openQuickActions}
      routePending={isRoutePending}
      sensitiveUnlocked={unlocked}
      passkeyEnabled={hasPasskey}
      sensitiveUnlockAvailable={headerSensitiveUnlockAvailable}
      sensitiveUnlockLabel={offlineSensitiveUnlockAvailable ? "离线解锁" : "解锁"}
      sensitiveUnlockTitle={offlineSensitiveUnlockAvailable ? "使用离线解锁码查看敏感数据" : "解锁敏感数据"}
      onUnlockSensitive={handleHeaderUnlockSensitive}
      onLockSensitive={() => void lockSensitive()}
      onActiveRouteTap={handleActiveRouteTap}
      themeMode={themeMode}
      resolvedTheme={resolvedTheme}
      onThemeModeChange={setThemeMode}
    >
      <Toast toast={toast} />
      {commandOpen && <Suspense fallback={null}><LazyCommandPalette open={commandOpen} actions={commandActions} onOpenChange={setCommandOpen} /></Suspense>}
      {showUnlockModal && !unlocked && createPortal(
        <div className="fixed inset-0 z-[120] bg-[rgba(20,20,19,0.72)] p-3 backdrop-blur-sm sm:p-5 flex items-center justify-center" role="dialog" aria-modal="true" aria-label="快速解锁" onClick={() => setShowUnlockModal(false)}>
          <div className="w-full max-w-md" onClick={(e) => e.stopPropagation()}>
            <button type="button" className="absolute right-5 top-5 z-10 grid h-10 w-10 place-items-center rounded-lg border border-line bg-panel text-stone hover:bg-tag" onClick={() => setShowUnlockModal(false)} aria-label="关闭"><X className="h-5 w-5" /></button>
            <SensitiveUnlockPanel
              title="快速解锁"
              description="输入本机快速解锁码查看敏感数据。"
              message={sensitiveMessage}
              quickUnlockEnabled={quickUnlockEnabled}
              quickUnlockMode={quickUnlockMode}
              passkeyRegistered={hasPasskey}
              onQuickUnlock={(secret) => { void unlockQuickSensitive(secret); }}
              onUnlock={loginWithPasskey}
              unlocking={unlocking}
            />
          </div>
        </div>,
        document.body
      )}
      {quickActionsOpen && <Suspense fallback={null}><LazyQuickActionsSheet open={quickActionsOpen} refreshing={refreshing || loadingFresh} pendingWriteCount={pendingWriteCount} syncingPendingWrites={syncingPendingWrites} onClose={() => setQuickActionsOpen(false)} onManualEntry={openManualEntry} onAiEntry={openAiEntry} onImport={openImportPage} onReconcile={openReconcilePage} onRefresh={refreshLedger} onSyncPendingWrites={syncPendingWrites} /></Suspense>}
      <PullRefreshIndicator state={pullState} distance={pullDistance} refreshing={refreshing} />
      {passkeyStatusLoaded && !hasPasskey && <PasskeyBanner onRegister={registerPasskey} />}

      <div
        key={pathname}
        className={`app-page-transition app-pull-surface min-w-0 max-w-full [overflow-x:clip] ${pullDistance > 0 ? "app-pull-surface-active" : ""}`}
        style={pullDistance > 0 ? { transform: `translate3d(0, ${Math.min(34, pullDistance * 0.28)}px, 0)` } : undefined}
        onTouchStart={handleTouchStart}
        onTouchMove={handleTouchMove}
        onTouchEnd={handleTouchEnd}
        onTouchCancel={handleTouchEnd}
      >
      {/* ── 时间范围选择器 ── */}
      <div className="mb-6 min-w-0 max-w-full">
        {/* 第一行：标题 + 翻页按钮 */}
        <div className="flex flex-wrap items-center justify-between gap-3">
          {canNavigate && (
            <button
              className="rounded-xl border border-line bg-panel px-3 py-2 text-brand"
              onClick={() => setTimeRange(navigateTimeRange(timeRange, -1))}
            >
              ‹
            </button>
          )}
          <div className="min-w-0 flex-1">
            <div className="text-xs uppercase tracking-[0.22em] text-stone">{header.eyebrow}</div>
            <strong className="font-serif text-2xl font-medium">{header.title}</strong>
            <div className="mt-1 flex flex-wrap items-center gap-2 text-xs text-stone">
              {!online && <span className="inline-flex items-center gap-1 rounded-full bg-tag px-2 py-0.5 text-warm"><WifiOff className="h-3 w-3" /> 离线模式</span>}
              {pendingWriteCount > 0 && <button type="button" className="inline-flex items-center gap-1 rounded-full bg-brand/10 px-2 py-0.5 text-brand disabled:opacity-60" onClick={syncPendingWrites} disabled={syncingPendingWrites}>{syncingPendingWrites ? "待同步写入中…" : pendingWriteSummary}</button>}
              <span>{lastSyncedAt ? `本地优先 · ${new Date(lastSyncedAt).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })} 已同步` : "下拉可刷新"}</span>
              {indexInfo?.active && indexInfo.gitSHA && <span className="inline-flex items-center gap-1 rounded-full bg-tag px-2 py-0.5 text-tertiary" title={`索引来源: ${indexInfo.source ?? ""}`}>PG 索引 · {indexInfo.gitSHA.slice(0, 7)}</span>}
              {(refreshing || loadingFresh) && <span className="text-brand">后台同步中…</span>}
              {unlocked && <button type="button" className="inline-flex items-center gap-1 rounded-full bg-brand/10 px-2 py-0.5 text-brand" onClick={() => void lockSensitive()}>敏感数据已解锁 · 重新隐藏</button>}
            </div>
            {offlineSensitiveUnlockAvailable && (
              <form className="mt-3 flex max-w-md flex-col gap-2 sm:flex-row" onSubmit={(event) => { event.preventDefault(); void unlockOfflineSensitive(); }}>
                <input
                  ref={offlineUnlockInputRef}
                  type="password"
                  className="h-10 min-w-0 rounded-xl border border-line bg-panel px-3 text-sm text-ink"
                  value={offlineUnlockSecret}
                  onChange={(event) => setOfflineUnlockSecret(event.target.value)}
                  placeholder="离线解锁码"
                  autoComplete="current-password"
                />
                <button type="submit" className="h-10 shrink-0 rounded-xl bg-brand px-4 text-sm text-paper disabled:opacity-50" disabled={!offlineUnlockSecret.trim()}>离线解锁</button>
              </form>
            )}
          </div>
          <div className="flex items-center gap-2">
            {canNavigate && (
              <button
                className="rounded-xl border border-line bg-panel px-3 py-2 text-brand"
                onClick={() => setTimeRange(navigateTimeRange(timeRange, 1))}
              >
                ›
              </button>
            )}
          </div>
        </div>

        {/* 第二行：快捷按钮组 */}
        {canShowTimeControls && (
          <div className="mt-3 flex min-w-0 max-w-full flex-wrap items-center gap-2">
            <div className="grid w-full min-w-0 grid-cols-6 overflow-hidden rounded-xl border border-line sm:flex sm:w-auto">
              {TIME_PRESETS.map((p) => (
                <button
                  key={p.key}
                  className={`min-w-0 whitespace-nowrap px-2 py-1.5 text-sm transition-colors sm:px-3 ${timeRange.preset === p.key ? "bg-brand text-paper" : "bg-panel text-warm hover:bg-tag"}`}
                  onClick={() => setPreset(p.key)}
                >
                  {p.label}
                </button>
              ))}
            </div>

            {/* 自定义范围：date input */}
            {timeRange.preset === "custom" && (
              <div className="flex min-w-0 flex-wrap items-center gap-2">
                <input
                  type="date"
                  className="rounded-xl border border-line bg-panel px-2 py-1.5 text-sm"
                  value={customStart}
                  onChange={(e) => setCustomStart(e.target.value)}
                />
                <span className="text-sm text-stone">~</span>
                <input
                  type="date"
                  className="rounded-xl border border-line bg-panel px-2 py-1.5 text-sm"
                  value={customEnd}
                  onChange={(e) => setCustomEnd(e.target.value)}
                />
                <button
                  className="rounded-xl border border-line bg-panel px-3 py-1.5 text-sm text-brand hover:bg-tag"
                  onClick={applyCustomRange}
                >
                  确定
                </button>
              </div>
            )}
          </div>
        )}
      </div>

      {page === "home" && <HomePage summary={summary} valuationCurrency={dataValuationCurrency} privacySettings={unlockedPrivacySettings} sensitiveUnlocked={unlocked} creditCards={creditCards} expenseAnalytics={incomeStatement?.expenseAnalytics ?? []} accountStatuses={accountStatuses} onPrivacyChange={updatePrivacySetting} onSelectCategory={openCategoryTransactions} />}

      {page === "dashboard" && (unlocked ? <DashboardPage timeRange={timeRange} valuationCurrency={valuationCurrency} visible={netWorthVisible} onToggleVisible={() => setNetWorthVisible((value) => !value)} onSensitiveLocked={handleSensitiveLocked} onSelectCategory={openCategoryTransactions} onOpenTransactions={openTransactionsHref} /> : requireSensitiveUnlock("趋势看板已隐藏", "此页会展示净资产、收入、账户余额和大额支出，需要解锁后查看。"))}
      {page === "net-worth" && (unlocked ? <NetWorthPage rows={netWorthChart} monthEndRows={monthEndNetWorthRows} windows={netWorthWindows} accountBalances={accountBalances} accounts={accounts} incomeStatement={incomeStatement} valuationCurrency={dataValuationCurrency} visible={netWorthVisible} onToggleVisible={() => setNetWorthVisible((value) => !value)} /> : requireSensitiveUnlock("净资产已隐藏", "此页会展示净资产、账户余额和资产配置，需要解锁后查看。"))}
      {page === "investments" && (unlocked ? <InvestmentsPage investments={investments} /> : requireSensitiveUnlock("股票持仓已隐藏", "此页会展示证券商品、持仓份额、最新价格和折算市值，需要解锁后查看。"))}
      {page === "income-statement" && <IncomeStatementPage income={incomeStatement?.income ?? []} expense={incomeStatement?.expense ?? []} expenseAnalytics={incomeStatement?.expenseAnalytics ?? []} topPayees={incomeStatement?.topPayees ?? []} topPaymentAccounts={incomeStatement?.topPaymentAccounts ?? []} totalIncome={incomeStatement?.totalIncome ?? 0} totalExpense={incomeStatement?.totalExpense ?? 0} netIncome={incomeStatement?.netIncome ?? 0} valuationCurrency={incomeStatementCurrency} visible={incomeStatementVisible} sensitiveUnlocked={unlocked} onToggleVisible={() => setIncomeStatementVisible((value) => !value)} onUnlockSensitive={unlockOnlineSensitive} onSelectCategory={openCategoryTransactions} />}
      {page === "currencies" && <Suspense fallback={<RouteFallback label="正在准备货币与汇率…" />}><LazyCurrencyPage commodities={commodities} prices={prices} accountBalances={accountBalances} accounts={accounts} valuationCurrency={valuationCurrency} sensitiveUnlocked={unlocked} onUnlockSensitive={unlockOnlineSensitive} onValuationCurrencyChange={(currency) => updatePrivacySetting("valuationCurrency", currency)} /></Suspense>}
      {page === "accounts" && (() => {
        const detailAccount = accountFromPathname(pathname);
        if (detailAccount) return unlocked ? <Suspense fallback={<RouteFallback label="正在准备账户明细…" />}><LazyAccountDetailPage account={detailAccount} onSensitiveLocked={handleSensitiveLocked} /></Suspense> : requireSensitiveUnlock("账户明细已隐藏", "单个账户详情包含当前余额和账户级流水，需要解锁后查看。");
        return <Suspense fallback={<RouteFallback label="正在准备账户面板…" />}><>{unlocked ? <><LazyBalanceGrid rows={visibleBalances} full allVisible={allBalancesVisible} visibleAccountMap={visibleAccountMap} onToggleAll={() => setAllBalancesVisible((value) => !value)} onToggleAccount={(account) => setVisibleAccountMap((current) => ({ ...current, [account]: !(current[account] ?? allBalancesVisible) }))} statuses={accountStatuses} txns={projectedTxns} /><LazyCreditCardPanel cards={creditCards} statuses={accountStatuses} valuationCurrency={dataValuationCurrency} visible={allBalancesVisible} visibleAccountMap={visibleAccountMap} summaryVisible={creditSummaryVisible} onToggleSummaryVisible={() => setCreditSummaryVisible((value) => !value)} onToggleAccount={(account) => setVisibleAccountMap((current) => ({ ...current, [account]: !(current[account] ?? allBalancesVisible) }))} /></> : requireSensitiveUnlock("账户余额已隐藏", "账户定义可以直接管理；当前余额和账户健康需要解锁后查看。")}<LazyAccountManager accounts={unlocked ? accountPageAccounts : accounts} balances={balances} onAdded={() => load(true)} showToast={showToast} /></></Suspense>;
      })()}
      {page === "settings" && <Suspense fallback={<RouteFallback label="正在准备设置…" />}><LazySettingsPage settings={privacySettings} commodities={commodities} onChange={updatePrivacySetting} themeMode={themeMode} resolvedTheme={resolvedTheme} onThemeModeChange={setThemeMode} mobileTabHrefs={mobileTabHrefs} onMobileTabHrefsChange={updateMobileTabHrefs} sensitiveUnlocked={unlocked} quickUnlockEnabled={quickUnlockEnabled} quickUnlockMode={quickUnlockMode} offlineUnlockEnabled={offlineUnlockEnabled} onEnableQuickUnlock={enableQuickUnlock} onDisableQuickUnlock={disableQuickUnlock} onEnableOfflineUnlock={enableOfflineUnlock} /></Suspense>}
      {page === "imports" && <Suspense fallback={<RouteFallback label="正在准备账单导入…" />}><LazyImportPage onImported={guardedImportRefresh} /></Suspense>}
      {page === "editor" && (unlocked ? <Suspense fallback={<RouteFallback label="正在准备账本编辑器…" />}><LazyLedgerEditorPage online={online} onSaved={() => { void load(true); }} showToast={showToast} /></Suspense> : requireSensitiveUnlock("账本编辑器已隐藏", "在线编辑会展示完整 Beancount 文件和金额，需要解锁后查看。"))}
      {page === "reconcile" && (unlocked ? <Suspense fallback={<RouteFallback label="正在准备对账…" />}><LazyReconcilePage timeRange={timeRange} rows={reconciliationRows} onSubmit={guardedReconcileAccount} statuses={accountStatuses} /></Suspense> : requireSensitiveUnlock("对账数据已隐藏", "对账会展示账户余额、余额断言和差额调整，需要解锁后查看。"))}
      {page === "transactions" && <TransactionQuickViews views={TRANSACTION_QUICK_VIEWS} onSelect={applyTransactionQuickView} />}
      {page === "home" && (homeSecondaryReady ? (
        <Suspense fallback={<RouteFallback label="正在准备流水列表…" />}>
          <LazyTransactionList
            txns={projectedTxns}
            accounts={accounts}
            searchable={false}
            categoryQuery=""
            metadataQuery=""
            searchQuery=""
            matchMode="prefix"
            viewMode={txnViewMode}
            setViewMode={setTxnViewMode}
            onUpdate={guardedUpdateTransaction}
            onDelete={guardedDeleteTransaction}
            onReverse={guardedReverseTransaction}
          />
        </Suspense>
      ) : <RouteFallback label="流水列表稍后加载…" />)}
      {page === "transactions" && (
        <Suspense fallback={<RouteFallback label="正在准备流水列表…" />}>
          <LazyTransactionList
            txns={projectedTxns}
            accounts={accounts}
            searchable={page === "transactions"}
            categoryQuery={page === "transactions" ? txnCategoryQuery : ""}
            setCategoryQuery={page === "transactions" ? setTxnCategoryQuery : undefined}
            metadataQuery={page === "transactions" ? txnMetadataQuery : ""}
            setMetadataQuery={page === "transactions" ? setTxnMetadataQuery : undefined}
            searchQuery={page === "transactions" ? txnSearchQuery : ""}
            setSearchQuery={page === "transactions" ? setTxnSearchQuery : undefined}
            matchMode={page === "transactions" ? categoryMatchMode : "prefix"}
            setMatchMode={page === "transactions" ? setCategoryMatchMode : undefined}
            viewMode={txnViewMode}
            setViewMode={setTxnViewMode}
            onUpdate={guardedUpdateTransaction}
            onDelete={guardedDeleteTransaction}
            onReverse={guardedReverseTransaction}
          />
        </Suspense>
      )}
      </div>

      {aiChatMounted && <AiBookkeepingChat load={load} showToast={showToast} openSignal={aiOpenSignal} />}

      {entryOpen && <Suspense fallback={null}><LazyEntryModal onClose={() => setEntryOpen(false)}><LazyEntryPanel nl={nl} setNl={setNl} onParse={parseNl} manual={manual} setManual={setManual} onPreviewManual={previewManualEntry} previews={previews} onRemovePreview={removePreview} onAppendPreviews={guardedAppendPreviews} parseStatus={parseStatus} parseMessage={parseMessage} appendStatus={appendStatus} expenseAccounts={expenseAccounts} incomeAccounts={incomeAccounts} paymentAccounts={paymentAccounts} accountLabels={accountLabelMap} /></LazyEntryModal></Suspense>}
    </AppShell>
  );
}

function PullRefreshIndicator({ state, distance, refreshing }: { state: "idle" | "pull" | "release" | "refreshing"; distance: number; refreshing: boolean }) {
  if (state === "idle" && !refreshing) return null;
  const label = refreshing || state === "refreshing" ? "正在刷新…" : state === "release" ? "松开刷新" : "下拉刷新";
  const top = Math.max(12, Math.min(76, distance));
  return <div className="pointer-events-none fixed left-1/2 z-50 -translate-x-1/2 rounded-full border border-line bg-panel/95 px-3 py-1.5 text-xs text-olive shadow-sm backdrop-blur" style={{ top: `calc(${top}px + env(safe-area-inset-top))` }}><RefreshCw className={`mr-1 inline h-3.5 w-3.5 text-brand ${refreshing || state === "refreshing" ? "animate-spin" : ""}`} />{label}</div>;
}

function useDeferredIdleReady(enabled: boolean, delayMs: number) {
  const [ready, setReady] = useState(!enabled);

  useEffect(() => {
    if (!enabled) {
      setReady(true);
      return;
    }

    setReady(false);
    let timeoutId: number | null = null;
    let idleId: number | null = null;
    const markReady = () => setReady(true);

    timeoutId = window.setTimeout(() => {
      if (window.requestIdleCallback) idleId = window.requestIdleCallback(markReady, { timeout: 2400 });
      else markReady();
    }, delayMs);

    return () => {
      if (timeoutId != null) window.clearTimeout(timeoutId);
      if (idleId != null) {
        if (window.cancelIdleCallback) window.cancelIdleCallback(idleId);
        else window.clearTimeout(idleId);
      }
    };
  }, [delayMs, enabled]);

  return ready;
}

function TransactionQuickViews({ views, onSelect }: { views: typeof TRANSACTION_QUICK_VIEWS; onSelect: (view: (typeof TRANSACTION_QUICK_VIEWS)[number]) => void }) {
  return (
    <section className="mb-4 hidden items-center justify-between gap-3 rounded-2xl border border-line bg-panel p-3 lg:flex">
      <div>
        <div className="text-xs uppercase tracking-[0.2em] text-stone">saved views</div>
        <div className="mt-0.5 text-sm text-olive">常用流水视图</div>
      </div>
      <div className="flex flex-wrap justify-end gap-2">
        {views.map((view) => (
          <button key={view.id} type="button" className="rounded-xl border border-line bg-paper px-3 py-2 text-sm text-warm hover:bg-tag" onClick={() => onSelect(view)} title={view.detail}>
            {view.label}
          </button>
        ))}
      </div>
    </section>
  );
}

function pageHeader(page: LedgerPage, range: TimeRange) {
  const label = formatTimeRangeLabel(range);
  const isMonthScoped = page !== "accounts" && page !== "settings" && page !== "imports" && page !== "editor" && page !== "currencies" && page !== "investments";
  const headers: Record<LedgerPage, { eyebrow: string; title: string }> = {
    home: { eyebrow: "monthly overview", title: `${label} 总览` },
    dashboard: { eyebrow: "analytics dashboard", title: `${label} 看板` },
    transactions: { eyebrow: "transactions", title: `${label} 流水` },
    imports: { eyebrow: "statement import", title: "账单导入" },
    editor: { eyebrow: "ledger editor", title: "账本编辑器" },
    reconcile: { eyebrow: "reconcile period", title: `${label} 对账` },
    accounts: { eyebrow: "account book", title: "账户与余额" },
    "net-worth": { eyebrow: "net worth range", title: `${label} 净资产` },
    investments: { eyebrow: "securities", title: "股票持仓" },
    "income-statement": { eyebrow: "income statement", title: `${label} 损益表` },
    currencies: { eyebrow: "currencies and fx", title: "货币与汇率" },
    settings: { eyebrow: "preferences", title: "设置" },
  };
  return { ...headers[page], monthScoped: isMonthScoped };
}
