"use client";

import { lazy, memo, Suspense, useCallback, useEffect, useMemo, useRef, useState, useTransition, type ComponentProps, type ReactNode } from "react";
import { createPortal } from "react-dom";
import { Bot, RefreshCw, WifiOff, X } from "lucide-react";
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from "@/components/ui/alert-dialog";
import { AppShell, ledgerNavItems } from "./AppShell";
import { useBrowserLocation, useBrowserRouter } from "@/lib/browserRouter";
import { useTranslation } from "react-i18next";
import { pageFromPathname } from "./ledger/routes";
import { queryDateRange } from "@/lib/queryDateRange";
import { canNavigateTimeRange, makeTimeRange, navigateTimeRange, formatTimeRangeLabel, timeRangeToParams } from "@/lib/timeRange";
import type { TimeRange } from "@/lib/timeRange";
import { apiEndpointSettingsChangeEvent, apiFetch, apiSensitiveDataLockedEvent, readApiEndpointSettings } from "@/lib/apiEndpoints";
import { fetchJson } from "@/lib/clientFetch";
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
import { enableQuickLedgerUnlock, getQuickLedgerUnlockMode, hasQuickLedgerUnlock, revokeQuickLedgerUnlock, type QuickUnlockMode } from "./ledger/quickUnlock";
import { useRouteScrollMemory } from "./ledger/hooks/useRouteScrollMemory";
import { useSwipeBack } from "./ledger/hooks/useSwipeBack";
import { useThemeMode } from "./ledger/hooks/useThemeMode";
import { useToast } from "./ledger/hooks/useToast";
import { useDesktopViewport } from "./ledger/hooks/useDesktopViewport";
import { AppSkeleton, LoginScreen, PasskeyBanner, SensitiveUnlockPanel } from "./ledger/AuthScreens";
import type { CommandAction } from "./ledger/CommandPalette";
import { HomePage } from "./ledger/HomePage";
import { OnboardingPrototype, type OnboardingPayload } from "./ledger/OnboardingPrototype";
import { InstanceSetupPage } from "./ledger/InstanceSetupPage";
import { Toast } from "./ledger/shared";
import { haptic } from "./ledger/haptics";
import { TimeRangePicker } from "./ledger/TimeRangePicker";
import {
  loadAccountDetailPage,
  loadAccountPanels,
  loadBQLQueryPage,
  loadCommandPalette,
  loadCurrencyPage,
  loadDashboardPage,
  loadEntryModal,
  loadImportPage,
  loadIncomeStatementPage,
  loadInvestmentsPage,
  loadLedgerEditorPage,
  loadLedgerAgentWorkspace,
  loadNetWorthPage,
  loadQuickActionsSheet,
  loadReconcilePage,
  loadSettingsPage,
  loadTransactionList,
  preloadOfflineCoreRoutes,
  preloadLedgerRoute,
} from "./ledger/routePreload";
import type { LedgerNavHref, LedgerPage, Txn } from "./ledger/types";
import type { LedgerAgentRequest } from "./ledger/LedgerAgentWorkspace";

const LazyNetWorthPage = lazy(() => loadNetWorthPage().then((mod) => ({ default: mod.NetWorthPage })));

const LazyIncomeStatementPage = lazy(() => loadIncomeStatementPage().then((mod) => ({ default: mod.IncomeStatementPage })));
const LazyInvestmentsPage = lazy(() => loadInvestmentsPage().then((mod) => ({ default: mod.InvestmentsPage })));

const LazyDashboardPage = lazy(() => loadDashboardPage().then((mod) => ({ default: mod.DashboardPage })));
const LazyBQLQueryPage = lazy(() => loadBQLQueryPage().then((mod) => ({ default: mod.BQLQueryPage })));

const LazyLedgerAgentWorkspace = lazy(() => loadLedgerAgentWorkspace().then((mod) => ({ default: mod.LedgerAgentWorkspace })));

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

const MemoNetWorthPage = memo(function NetWorthPage(props: ComponentProps<typeof LazyNetWorthPage>) {
  const { t } = useTranslation();
  return <Suspense fallback={<section className="border-b border-line bg-panel p-6 text-sm text-stone">{t("ledgerApp.preparingNetWorth")}</section>}><LazyNetWorthPage {...props} /></Suspense>;
});

const MemoInvestmentsPage = memo(function InvestmentsPage(props: ComponentProps<typeof LazyInvestmentsPage>) {
  const { t } = useTranslation();
  return <Suspense fallback={<section className="card p-6 text-sm text-stone">{t("ledgerApp.preparingInvestments")}</section>}><LazyInvestmentsPage {...props} /></Suspense>;
});

const MemoIncomeStatementPage = memo(function IncomeStatementPage(props: ComponentProps<typeof LazyIncomeStatementPage>) {
  const { t } = useTranslation();
  return <Suspense fallback={<section className="card p-6 text-sm text-stone">{t("ledgerApp.preparingIncomeStatement")}</section>}><LazyIncomeStatementPage {...props} /></Suspense>;
});

const MemoDashboardPage = memo(function DashboardPage(props: ComponentProps<typeof LazyDashboardPage>) {
  const { t } = useTranslation();
  return <Suspense fallback={<section className="border-b border-line bg-panel p-6 text-sm text-stone">{t("ledgerApp.preparingDashboard")}</section>}><LazyDashboardPage {...props} /></Suspense>;
});

const MemoBQLQueryPage = memo(function BQLQueryPage(props: ComponentProps<typeof LazyBQLQueryPage>) {
  const { t } = useTranslation();
  return <Suspense fallback={<section className="border-b border-line bg-panel p-6 text-sm text-stone">{t("ledgerApp.preparingQuery")}</section>}><LazyBQLQueryPage {...props} /></Suspense>;
});

function AgentPageLoading() {
  const { t } = useTranslation();
  const desktopViewport = useDesktopViewport();
  const loading = <section className={`ledger-agent-page flex min-h-0 min-w-0 max-w-full items-center justify-center overflow-hidden bg-paper ${desktopViewport ? "h-dvh" : "fixed inset-0 z-40 h-dvh"}`} aria-busy="true" aria-label={t("appShell.agentLoadingLabel")}>
      <div className="flex items-center gap-3 text-sm text-stone">
        <Bot className="h-5 w-5 animate-pulse text-brand" />
        <span>{t("appShell.agentLoading")}</span>
      </div>
    </section>;
  return desktopViewport ? loading : createPortal(loading, document.body);
}

function LedgerAgentWorkspace(props: ComponentProps<typeof LazyLedgerAgentWorkspace>) {
  return <Suspense fallback={props.presentation === "page" ? <AgentPageLoading /> : null}><LazyLedgerAgentWorkspace {...props} /></Suspense>;
}

function RouteFallback({ label }: { label: string }) {
  return <section className="card p-6 text-sm text-stone">{label}</section>;
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

const TRANSACTION_QUICK_VIEWS = [
  { id: "food", labelKey: "transactions.quickViewFood", labelDetailKey: "transactions.quickViewFoodDetail", category: "Expenses:Food", mode: "prefix" as const },
  { id: "unknown", labelKey: "transactions.quickViewUnknown", labelDetailKey: "transactions.quickViewUnknownDetail", category: "Expenses:Unknown", mode: "exact" as const },
  { id: "reimburse", labelKey: "transactions.quickViewReimburse", labelDetailKey: "transactions.quickViewReimburseDetail", search: "报销" },
];

function isTypingTarget(target: EventTarget | null) {
  const element = target instanceof HTMLElement ? target : null;
  if (!element) return false;
  return ["INPUT", "TEXTAREA", "SELECT"].includes(element.tagName) || element.isContentEditable;
}

export function LedgerApp({ page: pageProp }: { page?: LedgerPage }) {
  const { t, i18n } = useTranslation();
  const router = useBrowserRouter();
  const { pathname, search } = useBrowserLocation();
  const searchParams = useMemo(() => new URLSearchParams(search), [search]);
  const [isRoutePending, startRouteTransition] = useTransition();
  const [authed, setAuthed] = useState<boolean | null>(() => readInitialLedgerAuthState());
  const [instanceSetup, setInstanceSetup] = useState<"checking" | "required" | "ready">("checking");
  const activeApiEndpointIdRef = useRef(readApiEndpointSettings().activeId);
  const [password, setPassword] = useState("");
  const { toast, showToast, clearToast } = useToast();
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
  const page = pageProp ?? pageFromPathname(pathname, privacySettings.homePage);
  const [timeRange, setTimeRange] = useState<TimeRange>(() => makeTimeRange(page === "home" ? "year" : "month"));
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
  const [serverSearchTxns, setServerSearchTxns] = useState<Txn[] | null>(null);
  const [serverSearchLoading, setServerSearchLoading] = useState(false);
  const [serverSearchError, setServerSearchError] = useState("");
  const [quickActionsOpen, setQuickActionsOpen] = useState(false);
  const [conflictOperationId, setConflictOperationId] = useState<string | null>(null);
  const [commandOpen, setCommandOpen] = useState(false);
  const [agentOpen, setAgentOpen] = useState(false);
  const [agentRequest, setAgentRequest] = useState<LedgerAgentRequest | null>(null);
  const [agentBQLQuery, setAgentBQLQuery] = useState<{ id: number; query: string } | null>(null);
  const [indexInfo, setIndexInfo] = useState<LedgerIndexInfo | null>(null);
  const [onboardingState, setOnboardingState] = useState<"checking" | "uninitialized" | "ready">("checking");
  const [onboardingCreating, setOnboardingCreating] = useState(false);
  const [onboardingWaiting, setOnboardingWaiting] = useState(false);
  const [onboardingError, setOnboardingError] = useState("");
  const [onboardingGitSHA, setOnboardingGitSHA] = useState("");
  const [creditSummaryVisible, setCreditSummaryVisible] = useState(true);
  const [passkeyRegistered, setPasskeyRegistered] = useState<boolean | null>(null);
  const [quickUnlockEnabled, setQuickUnlockEnabled] = useState(() => hasQuickLedgerUnlock());
  const [quickUnlockMode, setQuickUnlockMode] = useState<QuickUnlockMode>(() => getQuickLedgerUnlockMode());
  const [showUnlockModal, setShowUnlockModal] = useState(false);
  const [unlocking, setUnlocking] = useState(false);
  const [mobileTabHrefs, setMobileTabHrefs] = useState<LedgerNavHref[]>(defaultMobileTabHrefs);
  useEffect(() => {
    let cancelled = false;
    void fetchJson<{ setupRequired?: boolean }>("/api/setup/status", { cache: "no-store" }, undefined, { kind: "health" })
      .then((status) => { if (!cancelled) setInstanceSetup(status.setupRequired ? "required" : "ready"); })
      .catch(() => { if (!cancelled) setInstanceSetup("ready"); });
    return () => { cancelled = true; };
  }, []);
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

  const handleServerSensitiveLocked = useCallback(() => {
    sessionStorage.removeItem("ledger_unlocked");
    setUnlocked(false);
  }, [setUnlocked]);

  useEffect(() => {
    const handleLockedWrite = () => {
      handleServerSensitiveLocked();
      setShowUnlockModal(true);
    };
    window.addEventListener(apiSensitiveDataLockedEvent, handleLockedWrite);
    return () => window.removeEventListener(apiSensitiveDataLockedEvent, handleLockedWrite);
  }, [handleServerSensitiveLocked]);

  const handleSensitiveLocked = useCallback(() => {
    sessionStorage.setItem("ledger_locked_at", String(Date.now()));
    handleServerSensitiveLocked();
  }, [handleServerSensitiveLocked]);
  const toggleNetWorthVisible = useCallback(() => setNetWorthVisible((value) => !value), []);
  const toggleIncomeStatementVisible = useCallback(() => setIncomeStatementVisible((value) => !value), []);
  const openAgentFromQuery = useCallback((prompt: string) => openAgent(prompt, true), []);

  const lockSensitive = useCallback(async () => {
    handleSensitiveLocked();
    try {
      await apiFetch("/api/auth/lock", { method: "POST" }, { kind: "auth" });
    } catch {
      showToast("error", t("ledgerApp.lockedLocallyHidden"));
    }
  }, [handleSensitiveLocked, showToast]);
  const {
    summary,
    comparisons,
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
    refreshLedger,
  } = useLedgerData({
    timeRange,
    unlocked,
    valuationCurrency,
    onSensitiveUnlockChange: setUnlocked,
    onAuthChange: setAuthed,
    onPasskeyRegistered: setPasskeyRegistered,
    showToast,
  });

  const { login, loginWithPassword, preparePasskeyLogin, loginWithPasskey, loginWithQuickUnlock, registerPasskey } = useLedgerAuth({
    password,
    setPassword,
    setAuthed,
    setUnlocked,
    setPasskeyRegistered,
    load,
    showToast,
    clearToast,
  });

  useEffect(() => {
    if (!authed) {
      setOnboardingState("checking");
      setOnboardingWaiting(false);
      setOnboardingGitSHA("");
      return;
    }
    let cancelled = false;
    void fetchJson<{ state?: string }>("/api/onboarding", undefined, undefined, { kind: "read" }).then((result) => {
      if (!cancelled) setOnboardingState(result.state === "uninitialized" ? "uninitialized" : "ready");
    }).catch(() => { if (!cancelled) setOnboardingState("ready"); });
    return () => { cancelled = true; };
  }, [authed]);

  const initializeOnboarding = useCallback(async (payload: OnboardingPayload) => {
    setOnboardingCreating(true); setOnboardingError("");
    try {
      const result = await fetchJson<{ gitSHA?: string }>("/api/onboarding/initialize", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(payload) }, undefined, { kind: "write" });
      setOnboardingGitSHA(result.gitSHA ?? "");
      setOnboardingWaiting(true);
    } catch (error) {
      setOnboardingError(error instanceof Error ? error.message : t("ledgerApp.cannotCreateLedger"));
    } finally { setOnboardingCreating(false); }
  }, [t]);

  useEffect(() => {
    if (!onboardingWaiting) return;
    let cancelled = false;
    const poll = async () => {
      const info = await fetchLedgerIndexInfo();
      if (cancelled || !info) return;
      setIndexInfo(info);
      if (info.error) { setOnboardingError(info.error); setOnboardingWaiting(false); return; }
      if (info.active && (!onboardingGitSHA || info.gitSHA === onboardingGitSHA)) {
        setOnboardingWaiting(false); setOnboardingState("ready"); void load(true);
      }
    };
    void poll();
    const timer = window.setInterval(() => { void poll(); }, 2000);
    return () => { cancelled = true; window.clearInterval(timer); };
  }, [load, onboardingGitSHA, onboardingWaiting]);

  const unlockPasskeySensitive = async () => {
    setUnlocking(true);
    try {
      await loginWithPasskey();
    } finally {
      setUnlocking(false);
    }
  };

  useEffect(() => {
    if (!online || !hasPasskey || unlocked) return;
    void preparePasskeyLogin().catch(() => {
      // The click path retries and reports a useful error if preloading fails.
    });
  }, [hasPasskey, online, showUnlockModal, unlocked]);

  useEffect(() => {
    const handleEndpointChange = () => {
      const activeId = readApiEndpointSettings().activeId;
      if (activeId === activeApiEndpointIdRef.current) return;
      activeApiEndpointIdRef.current = activeId;
      sessionStorage.removeItem("ledger_unlocked");
      setUnlocked(false);
      setPasskeyRegistered(null);
      setAuthed(null);
      void load(true).catch((error) => {
        showToast("error", error instanceof Error ? error.message : t("ledgerApp.switchBackendFailed"));
      });
    };
    window.addEventListener(apiEndpointSettingsChangeEvent, handleEndpointChange);
    return () => window.removeEventListener(apiEndpointSettingsChangeEvent, handleEndpointChange);
  }, [load, setUnlocked, showToast]);

  const { pendingOperations, pendingWriteCount, pendingWriteSummary, enqueuePendingWrites, enqueueTransactionUpdate, enqueueTransactionDelete, syncPendingWrites, syncingPendingWrites, discardPendingOperation } = usePendingLedgerWrites({ load, showToast, ledgerVersion });
  const pendingConflict = useMemo(() => pendingOperations.find((operation) => operation.id === conflictOperationId && operation.status === "conflict") ?? null, [conflictOperationId, pendingOperations]);
  const { nl, setNl, previews, parseStatus, parseMessage, appendStatus, entryOpen, setEntryOpen, manual, setManual, parseNl, previewManualEntry, removePreview, appendPreviews, appendEntry } = useEntryActions({ load, showToast, enqueuePendingWrites });
  const { updateTransaction, deleteTransaction, reverseTransaction, reconcileAccount } = useLedgerMutations({ appendEntry, load, showToast, enqueuePendingWrites, enqueueTransactionUpdate, enqueueTransactionDelete });
  const { accountLabelMap, accountPageAccounts, expenseAccounts, incomeAccounts, paymentAccounts, visibleBalances, netWorthChart } = useLedgerDerivedData({ summary, accounts, balances, accountBalances, netWorthRows, page, valuationCurrency });
  const dataValuationCurrency = summary?.currency ?? incomeStatement?.valuationCurrency ?? valuationCurrency;
  const incomeStatementCurrency = incomeStatement?.valuationCurrency ?? dataValuationCurrency;
  const projectedTxns = useMemo(() => applyPendingLedgerOperations(txns, pendingOperations, timeRange), [pendingOperations, timeRange, txns]);
  const transactionDslQuery = txnSearchQuery.trim();
  const transactionServerSearchActive = Boolean(transactionDslQuery);
  const transactionListTxns = useMemo(() => applyPendingLedgerOperations(transactionServerSearchActive ? (serverSearchTxns ?? []) : txns, pendingOperations, timeRange), [pendingOperations, serverSearchTxns, timeRange, transactionServerSearchActive, txns]);
  const detailAccount = page === "accounts" ? accountFromPathname(pathname) : null;
  useSwipeBack({ enabled: Boolean(detailAccount), onBack: () => { void pushPreloadedRoute("/accounts"); } });

  useEffect(() => {
    if (page !== "transactions" || !transactionDslQuery || !authed) {
      setServerSearchTxns(null);
      setServerSearchLoading(false);
      setServerSearchError("");
      return;
    }
    const controller = new AbortController();
    const params = new URLSearchParams(timeRangeToParams(timeRange));
    params.set("q", transactionDslQuery);
    setServerSearchLoading(true);
    setServerSearchError("");
    void fetchJson<{ transactions: Txn[] }>(`/api/ledger/transactions?${params.toString()}`, { signal: controller.signal }, undefined, { kind: "read" })
      .then((payload) => {
        if (controller.signal.aborted) return;
        setServerSearchTxns(payload.transactions ?? []);
      })
      .catch((error) => {
        if (controller.signal.aborted) return;
        setServerSearchTxns([]);
        setServerSearchError(error instanceof Error ? error.message : t("ledgerApp.queryFailed"));
      })
      .finally(() => {
        if (!controller.signal.aborted) setServerSearchLoading(false);
      });
    return () => controller.abort();
  }, [authed, page, timeRange, transactionDslQuery, unlocked]);

  function pushPreloadedRoute(href: string, options?: { scroll?: boolean }) {
    const preload = preloadLedgerRoute(href);
    const navigate = () => {
      startRouteTransition(() => {
        router.push(href, options);
      });
    };
    if (!preload) {
      navigate();
      return Promise.resolve();
    }
    return preload.finally(navigate).then(() => undefined);
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

  async function enableQuickUnlock(secret: string, mode: QuickUnlockMode) {
    await enableQuickLedgerUnlock(secret, mode);
    setQuickUnlockEnabled(true);
    setQuickUnlockMode(mode);
    showToast("success", t("ledgerApp.quickUnlockEnabled"));
  }

  async function disableQuickUnlock() {
    await revokeQuickLedgerUnlock();
    setQuickUnlockEnabled(false);
    setQuickUnlockMode(getQuickLedgerUnlockMode());
    showToast("success", t("ledgerApp.quickUnlockDisabled"));
  }

  const searchKey = searchParams.toString();
  const shortcutAction = searchParams.get("action");

  useEffect(() => {
    const rawQuery = page === "transactions"
      ? txnSearchQuery
      : page === "dashboard"
        ? searchParams.get("q") ?? ""
        : "";
    const range = queryDateRange(rawQuery);
    if (!range) return;
    if (range.start === timeRange.start && range.end === timeRange.end) return;
    setTimeRange({ start: range.start, end: range.end, preset: "custom" });
  }, [page, searchParams, timeRange.end, timeRange.start, txnSearchQuery]);

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
      openAgent();
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
    void pushPreloadedRoute(`/transactions?${params.toString()}`);
  }

  function openTransactionsHref(href: string) {
    void pushPreloadedRoute(href);
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
    void pushPreloadedRoute(query ? `/transactions?${query}` : "/transactions");
  }

  function focusTransactionSearch() {
    if (page !== "transactions") {
      void pushPreloadedRoute("/transactions").then(() => {
        window.setTimeout(() => document.getElementById("transaction-search-input")?.focus(), 80);
      });
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
      if ((event.metaKey || event.ctrlKey) && event.shiftKey && event.key.toLowerCase() === "u") {
        if (!authed || unlocked) return;
        event.preventDefault();
        if (online) setShowUnlockModal(true);
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
        const currentHeader = pageHeader(page, timeRange, t);
        const delta = event.key === "ArrowLeft" ? -1 : 1;
        if (!currentHeader.monthScoped || !canNavigateTimeRange(timeRange, delta)) return;
        event.preventDefault();
        setTimeRange(navigateTimeRange(timeRange, delta));
      }
    };
    window.addEventListener("keydown", handleKeyDown);
    return () => window.removeEventListener("keydown", handleKeyDown);
  }, [authed, online, page, router, timeRange, unlocked]);

  if (instanceSetup === "checking") return <AppSkeleton />;
  if (instanceSetup === "required") return <InstanceSetupPage onComplete={() => { setAuthed(false); setInstanceSetup("ready"); }} />;
  if (authed === null && !online && hasKnownLedgerAuthentication()) return <AppSkeleton />;
  if (searchParams.get("prototype") === "onboarding") return <OnboardingPrototype />;
  if (authed === null && !online) return <LoginScreen password={password} setPassword={setPassword} passkeyRegistered={hasPasskey} passkeyLoading={unlocking} toastText={toast?.text ?? t("auth.offlineColdStart")} onLogin={login} onPasskeyLogin={() => { void unlockPasskeySensitive(); }} />;
  if (authed === null) return <AppSkeleton />;
  if (!authed) return <LoginScreen password={password} setPassword={setPassword} passkeyRegistered={hasPasskey} passkeyLoading={unlocking} toastText={toast?.text} onLogin={login} onPasskeyLogin={() => { void unlockPasskeySensitive(); }} />;
  if (onboardingState === "checking") return <AppSkeleton />;
  if (onboardingState === "uninitialized") return <OnboardingPrototype onCreate={initializeOnboarding} creating={onboardingCreating} waiting={onboardingWaiting} error={onboardingError} />;

  const sensitiveMessage = toast?.kind === "error" ? toast.text : "";
  const headerSensitiveUnlockAvailable = shouldOfferHeaderSensitiveUnlock({
    online,
    unlocked,
  });
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
  const unlockPasswordSensitive = async (inputPassword: string) => {
    setUnlocking(true);
    try {
      await loginWithPassword(inputPassword);
      setShowUnlockModal(false);
    } catch {
      // Error handled by loginWithPassword
    } finally {
      setUnlocking(false);
    }
  };
  const unlockOnlineSensitive = () => {
    setShowUnlockModal(true);
  };
  const handleHeaderUnlockSensitive = () => {
    unlockOnlineSensitive();
  };
  const requireSensitiveUnlock = (title?: string, description?: string) => (
    <SensitiveUnlockPanel
      title={title}
      description={description}
      message={sensitiveMessage}
      offline={!online}
      quickUnlockEnabled={quickUnlockEnabled}
      quickUnlockMode={quickUnlockMode}
      passkeyRegistered={hasPasskey}
      onQuickUnlock={(secret) => { void unlockQuickSensitive(secret); }}
      onUnlock={() => { void unlockPasskeySensitive(); }}
      onPasswordUnlock={(inputPassword) => { void unlockPasswordSensitive(inputPassword); }}
      unlocking={unlocking}
    />
  );
  const header = pageHeader(page, timeRange, t);
  const canShowTimeControls = header.monthScoped;
  const canNavigatePrevious = canShowTimeControls && canNavigateTimeRange(timeRange, -1);
  const canNavigateNext = canShowTimeControls && canNavigateTimeRange(timeRange, 1);

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

  function openAgent(prompt?: string, autoSubmit = false) {
    void loadLedgerAgentWorkspace();
    setAgentRequest({ id: Date.now(), prompt, autoSubmit });
    void pushPreloadedRoute("/agent");
  }

  function applyAgentBQL(query: string) {
    setAgentBQLQuery({ id: Date.now(), query });
    void pushPreloadedRoute("/query");
  }

  function openQuickActions() {
    void loadQuickActionsSheet();
    setQuickActionsOpen(true);
  }

  function openImportPage() {
    void pushPreloadedRoute("/imports");
  }

  function openReconcilePage() {
    void pushPreloadedRoute("/reconcile");
    if (!unlocked) unlockOnlineSensitive();
  }

  const offlineWriteMessage = t("ledgerApp.offlineWriteWarning");
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
    { id: "new-entry", label: t("ledgerApp.newManualEntry"), detail: t("ledgerApp.newManualEntryDetail"), shortcut: "N", keywords: ["entry", "transaction"], run: openManualEntry },
    { id: "ai-entry", label: t("ledgerApp.agent"), detail: t("ledgerApp.agentDetail"), keywords: ["ai", "agent", "chat"], run: () => openAgent() },
    ...(!unlocked && online ? [{ id: "unlock-sensitive", label: t("ledgerApp.unlockSensitive"), detail: t("ledgerApp.unlockSensitiveDetail"), shortcut: "⌘/Ctrl ⇧ U", keywords: ["unlock", "password", "privacy"], run: unlockOnlineSensitive }] : []),
    { id: "search-transactions", label: t("ledgerApp.searchTransactions"), detail: t("ledgerApp.searchTransactionsDetail"), shortcut: "/", keywords: ["transactions", "search"], run: focusTransactionSearch },
    { id: "refresh", label: t("ledgerApp.refreshLedger"), detail: t("ledgerApp.refreshLedgerDetail"), keywords: ["sync", "reload"], run: () => { void refreshLedger(); } },
    { id: "previous-period", label: t("ledgerApp.previousPeriod"), detail: t("ledgerApp.previousPeriodDetail"), shortcut: "Alt ←", keywords: ["period", "month"], run: () => canNavigatePrevious && setTimeRange(navigateTimeRange(timeRange, -1)) },
    { id: "next-period", label: t("ledgerApp.nextPeriod"), detail: t("ledgerApp.nextPeriodDetail"), shortcut: "Alt →", keywords: ["period", "month"], run: () => canNavigateNext && setTimeRange(navigateTimeRange(timeRange, 1)) },
    ...ledgerNavItems.map((item) => ({ id: `nav-${item.href}`, label: t("commands.navigateTo", { label: t(item.labelKey) }), detail: item.href, keywords: ["go", "page"], run: () => { void pushPreloadedRoute(item.href); } })),
    ...TRANSACTION_QUICK_VIEWS.map((view) => ({ id: `view-${view.id}`, label: t(view.labelKey), detail: t(view.labelDetailKey), keywords: ["view", "saved", "transactions"], run: () => applyTransactionQuickView(view) })),
  ];

  return (
    <AppShell
      pathname={pathname}
      onAdd={openQuickActions}
      routePending={isRoutePending}
      sensitiveUnlocked={unlocked}
      passkeyEnabled={hasPasskey}
      sensitiveUnlockAvailable={headerSensitiveUnlockAvailable}
      sensitiveUnlockLabel={t("appShell.unlock")}
      sensitiveUnlockTitle={t("appShell.unlockTitle")}
      onUnlockSensitive={handleHeaderUnlockSensitive}
      onLockSensitive={() => void lockSensitive()}
      onActiveRouteTap={handleActiveRouteTap}
      themeMode={themeMode}
      resolvedTheme={resolvedTheme}
      onThemeModeChange={setThemeMode}
    >
      <Toast toast={toast} onClose={clearToast} />
      {commandOpen && <Suspense fallback={null}><LazyCommandPalette open={commandOpen} actions={commandActions} onOpenChange={setCommandOpen} /></Suspense>}
      {showUnlockModal && !unlocked && createPortal(
        <div className="fixed inset-0 z-[120] bg-[rgba(20,20,19,0.72)] p-3 backdrop-blur-sm sm:p-5 flex items-center justify-center" role="dialog" aria-modal="true" aria-label={t("ledgerApp.quickUnlockModalLabel")} onClick={() => setShowUnlockModal(false)}>
          <div className="w-full max-w-md" onClick={(e) => e.stopPropagation()}>
            <button type="button" className="absolute right-5 top-5 z-10 grid h-10 w-10 place-items-center rounded-lg border border-line bg-panel text-stone hover:bg-tag" onClick={() => setShowUnlockModal(false)} aria-label={t("ledgerApp.close")}><X className="h-5 w-5" /></button>
            <SensitiveUnlockPanel
              title={t("ledgerApp.quickUnlockTitle")}
              description={t("ledgerApp.quickUnlockDescription")}
              message={sensitiveMessage}
              quickUnlockEnabled={quickUnlockEnabled}
              quickUnlockMode={quickUnlockMode}
              passkeyRegistered={hasPasskey}
              onQuickUnlock={(secret) => { void unlockQuickSensitive(secret); }}
              onUnlock={() => { void unlockPasskeySensitive(); }}
              onPasswordUnlock={(inputPassword) => { void unlockPasswordSensitive(inputPassword); }}
              unlocking={unlocking}
              autoFocusInput
              surface="dialog"
            />
          </div>
        </div>,
        document.body
      )}
      {quickActionsOpen && <Suspense fallback={null}><LazyQuickActionsSheet open={quickActionsOpen} refreshing={refreshing || loadingFresh} pendingWriteCount={pendingWriteCount} syncingPendingWrites={syncingPendingWrites} onClose={() => setQuickActionsOpen(false)} onManualEntry={openManualEntry} onAiEntry={() => openAgent()} onImport={openImportPage} onReconcile={openReconcilePage} onRefresh={refreshLedger} onSyncPendingWrites={() => void syncPendingWrites({ userInitiated: true })} /></Suspense>}
      {passkeyStatusLoaded && !hasPasskey && page !== "settings" && <PasskeyBanner onRegister={registerPasskey} />}

      <PullToRefreshSurface refresh={refreshLedger} disabled={refreshing || loadingFresh}>
      <div className="ledger-workspace-frame min-w-0 max-w-full">
      <div className="ledger-workspace-content min-w-0 max-w-full">
      {page !== "agent" && <div className="workspace-context-row min-w-0 max-w-full border-b border-line bg-panel px-3 py-2.5 md:px-4 md:py-3 xl:px-6">
        <div className="flex flex-wrap items-center justify-between gap-3.5">
          <div className="w-full min-w-0 md:w-auto md:flex-1">
            <div className="flex min-w-0 flex-wrap items-baseline gap-x-3 gap-y-1">
              <strong className="block truncate text-sm font-semibold tracking-[-0.015em] text-ink">{header.title}</strong>
              <div className="flex flex-wrap items-center gap-2 text-[11px] text-stone">
              {!online && <span className="inline-flex items-center gap-1 rounded-full bg-tag px-2 py-0.5 text-warm"><WifiOff className="h-3 w-3" /> {t("ledgerApp.offlineMode")}</span>}
              {pendingWriteCount > 0 && <button type="button" className="inline-flex items-center gap-1 rounded-full bg-brand/10 px-2 py-0.5 text-brand disabled:opacity-60" onClick={() => {
                const conflict = pendingOperations.find((operation) => operation.status === "conflict");
                if (conflict) setConflictOperationId(conflict.id);
                else void syncPendingWrites({ userInitiated: true });
              }} disabled={syncingPendingWrites}>{syncingPendingWrites ? t("ledgerApp.syncingWrites") : pendingWriteSummary}</button>}
              <span>{lastSyncedAt ? t("common.syncedAt", { time: new Date(lastSyncedAt).toLocaleTimeString(i18n.language, { hour: "2-digit", minute: "2-digit" }) }) : t("common.pullToRefresh")}</span>
              {indexInfo?.active && indexInfo.gitSHA && <span className="inline-flex items-center gap-1 rounded-full bg-tag px-2 py-0.5 text-tertiary" title={t("ledgerApp.indexSource", { source: indexInfo.source ?? "" })}>{t("ledgerApp.pgIndex", { sha: indexInfo.gitSHA.slice(0, 7) })}</span>}
              {(refreshing || loadingFresh) && <span className="text-brand">{t("ledgerApp.refreshingInBackground")}</span>}
              {unlocked && <button type="button" className="inline-flex items-center gap-1 rounded-full bg-brand/10 px-2 py-0.5 text-brand" onClick={() => void lockSensitive()}>{t("ledgerApp.sensitiveUnlockedRelock")}</button>}
              </div>
            </div>
          </div>
          <div className="workspace-controls flex w-full min-w-0 items-stretch gap-2 md:w-auto md:shrink-0">
            {canShowTimeControls && <div className="workspace-time-control min-w-0 flex-1 md:flex-none"><TimeRangePicker range={timeRange} onChange={setTimeRange} /></div>}
            <button type="button" className={`workspace-agent-trigger grid shrink-0 place-items-center rounded-lg border border-line bg-paper text-brand transition active:scale-95 hover:bg-tag ${canShowTimeControls ? "h-14 w-14 md:h-12 md:w-12" : "h-10 w-10"}`} onClick={() => openAgent()} aria-label={t("appShell.agentLoadingLabel")} title={t("appShell.agentLoadingLabel")}><Bot className="h-5 w-5" /></button>
          </div>
        </div>
      </div>}

      {page === "agent" && <LedgerAgentWorkspace key={activeApiEndpointIdRef.current} presentation="page" request={agentRequest} open context={{ page, path: pathname, start: timeRange.start, end: timeRange.end, valuationCurrency }} onApplyBQL={applyAgentBQL} onNavigate={(path) => { void pushPreloadedRoute(path); }} onChanged={() => load(true)} showToast={showToast} />}
      {page === "home" && <HomePage summary={summary} comparisons={comparisons} timeRange={timeRange} valuationCurrency={dataValuationCurrency} ledgerRevision={ledgerVersion?.version || ledgerVersion?.signature || `${ledgerVersion?.latestMtimeMs ?? 0}:${ledgerVersion?.fileCount ?? 0}`} privacySettings={privacySettings} sensitiveUnlocked={unlocked} expenseAnalytics={incomeStatement?.expenseAnalytics ?? []} onPrivacyChange={updatePrivacySetting} onSensitiveLocked={handleServerSensitiveLocked} />}

      {page === "dashboard" && (unlocked ? <MemoDashboardPage timeRange={timeRange} valuationCurrency={valuationCurrency} visible={netWorthVisible} onToggleVisible={toggleNetWorthVisible} onSensitiveLocked={handleServerSensitiveLocked} onOpenTransactions={openTransactionsHref} /> : requireSensitiveUnlock(t("ledgerApp.dashboardHidden"), t("ledgerApp.dashboardHiddenDetail")))}
      {page === "query" && (unlocked ? <MemoBQLQueryPage valuationCurrency={valuationCurrency} onSensitiveLocked={handleServerSensitiveLocked} onOpenAgent={openAgentFromQuery} agentQuery={agentBQLQuery} /> : requireSensitiveUnlock(t("ledgerApp.queryHidden"), t("ledgerApp.queryHiddenDetail")))}
      {page === "net-worth" && (unlocked ? <MemoNetWorthPage rows={netWorthChart} monthEndRows={monthEndNetWorthRows} windows={netWorthWindows} accountBalances={accountBalances} accounts={accounts} comparisons={comparisons?.totalAssets} valuationCurrency={dataValuationCurrency} visible={netWorthVisible} onToggleVisible={toggleNetWorthVisible} /> : requireSensitiveUnlock(t("ledgerApp.netWorthHidden"), t("ledgerApp.netWorthHiddenDetail")))}
      {page === "investments" && (unlocked ? <MemoInvestmentsPage investments={investments} /> : requireSensitiveUnlock(t("ledgerApp.investmentsHidden"), t("ledgerApp.investmentsHiddenDetail")))}
      {page === "income-statement" && <MemoIncomeStatementPage income={incomeStatement?.income ?? []} expense={incomeStatement?.expense ?? []} expenseAnalytics={incomeStatement?.expenseAnalytics ?? []} topPayees={incomeStatement?.topPayees ?? []} topPaymentAccounts={incomeStatement?.topPaymentAccounts ?? []} totalIncome={incomeStatement?.totalIncome ?? 0} totalExpense={incomeStatement?.totalExpense ?? 0} netIncome={incomeStatement?.netIncome ?? 0} valuationCurrency={incomeStatementCurrency} visible={incomeStatementVisible} sensitiveUnlocked={unlocked} onToggleVisible={toggleIncomeStatementVisible} onUnlockSensitive={unlockOnlineSensitive} onSelectCategory={openCategoryTransactions} />}
      {page === "currencies" && <Suspense fallback={<RouteFallback label={t("ledgerApp.preparingCurrency")} />}><LazyCurrencyPage commodities={commodities} prices={prices} accountBalances={accountBalances} accounts={accounts} valuationCurrency={valuationCurrency} sensitiveUnlocked={unlocked} onUnlockSensitive={unlockOnlineSensitive} onValuationCurrencyChange={(currency) => updatePrivacySetting("valuationCurrency", currency)} /></Suspense>}
      {page === "accounts" && (() => {
        const detailAccount = accountFromPathname(pathname);
        if (detailAccount) return unlocked ? <Suspense fallback={<RouteFallback label={t("ledgerApp.preparingAccountDetail")} />}><LazyAccountDetailPage account={detailAccount} onSensitiveLocked={handleServerSensitiveLocked} /></Suspense> : requireSensitiveUnlock(t("ledgerApp.accountDetailHidden"), t("ledgerApp.accountDetailHiddenDetail"));
        return <Suspense fallback={<RouteFallback label={t("ledgerApp.preparingAccountPanels")} />}><>{unlocked ? <><LazyBalanceGrid rows={visibleBalances} full allVisible={allBalancesVisible} visibleAccountMap={visibleAccountMap} onToggleAll={() => setAllBalancesVisible((value) => !value)} onToggleAccount={(account) => setVisibleAccountMap((current) => ({ ...current, [account]: !(current[account] ?? allBalancesVisible) }))} statuses={accountStatuses} txns={projectedTxns} /><LazyCreditCardPanel cards={creditCards} statuses={accountStatuses} valuationCurrency={dataValuationCurrency} visible={allBalancesVisible} visibleAccountMap={visibleAccountMap} summaryVisible={creditSummaryVisible} onToggleSummaryVisible={() => setCreditSummaryVisible((value) => !value)} onToggleAccount={(account) => setVisibleAccountMap((current) => ({ ...current, [account]: !(current[account] ?? allBalancesVisible) }))} /></> : requireSensitiveUnlock(t("ledgerApp.accountBalancesHidden"), t("ledgerApp.accountBalancesHiddenDetail"))}<LazyAccountManager accounts={unlocked ? accountPageAccounts : accounts} balances={balances} onAdded={() => load(true)} showToast={showToast} onOpenAgent={(prompt) => openAgent(prompt, true)} /></></Suspense>;
      })()}
      {page === "settings" && <Suspense fallback={<RouteFallback label={t("ledgerApp.preparingSettings")} />}><LazySettingsPage settings={privacySettings} commodities={commodities} onChange={updatePrivacySetting} themeMode={themeMode} resolvedTheme={resolvedTheme} onThemeModeChange={setThemeMode} mobileTabHrefs={mobileTabHrefs} onMobileTabHrefsChange={updateMobileTabHrefs} sensitiveUnlocked={unlocked} quickUnlockEnabled={quickUnlockEnabled} quickUnlockMode={quickUnlockMode} onEnableQuickUnlock={enableQuickUnlock} onDisableQuickUnlock={disableQuickUnlock} onRegisterPasskey={registerPasskey} onPasskeyRegisteredChange={setPasskeyRegistered} showToast={showToast} /></Suspense>}
      {page === "imports" && <Suspense fallback={<RouteFallback label={t("ledgerApp.preparingImports")} />}><LazyImportPage onImported={guardedImportRefresh} showToast={showToast} /></Suspense>}
      {page === "editor" && (unlocked ? <Suspense fallback={<RouteFallback label={t("ledgerApp.preparingEditor")} />}><LazyLedgerEditorPage online={online} onSaved={() => { void load(true); }} showToast={showToast} /></Suspense> : requireSensitiveUnlock(t("ledgerApp.editorHidden"), t("ledgerApp.editorHiddenDetail")))}
      {page === "reconcile" && (unlocked ? <Suspense fallback={<RouteFallback label={t("ledgerApp.preparingReconcile")} />}><LazyReconcilePage timeRange={timeRange} rows={reconciliationRows} onSubmit={guardedReconcileAccount} statuses={accountStatuses} /></Suspense> : requireSensitiveUnlock(t("ledgerApp.reconcileHidden"), t("ledgerApp.reconcileHiddenDetail")))}
      {page === "transactions" && <TransactionQuickViews views={TRANSACTION_QUICK_VIEWS} onSelect={applyTransactionQuickView} />}
      {page === "transactions" && (
        <Suspense fallback={<RouteFallback label={t("ledgerApp.preparingTransactions")} />}>
          <LazyTransactionList
            txns={transactionListTxns}
            accounts={accounts}
            searchable={page === "transactions"}
            categoryQuery={page === "transactions" ? txnCategoryQuery : ""}
            setCategoryQuery={page === "transactions" ? setTxnCategoryQuery : undefined}
            metadataQuery={page === "transactions" ? txnMetadataQuery : ""}
            setMetadataQuery={page === "transactions" ? setTxnMetadataQuery : undefined}
            searchQuery={page === "transactions" ? txnSearchQuery : ""}
            setSearchQuery={page === "transactions" ? setTxnSearchQuery : undefined}
            serverFilteredSearch={transactionServerSearchActive}
            serverSearchLoading={serverSearchLoading}
            serverSearchError={serverSearchError}
            matchMode={page === "transactions" ? categoryMatchMode : "prefix"}
            setMatchMode={page === "transactions" ? setCategoryMatchMode : undefined}
            viewMode={txnViewMode}
            setViewMode={setTxnViewMode}
            onUpdate={guardedUpdateTransaction}
            onDelete={guardedDeleteTransaction}
            onReverse={guardedReverseTransaction}
            showToast={showToast}
          />
        </Suspense>
      )}
      </div>

      {page !== "agent" && <LedgerAgentWorkspace
        key={activeApiEndpointIdRef.current}
        request={null}
        open={agentOpen}
        onOpenChange={setAgentOpen}
        context={{ page, path: pathname, start: timeRange.start, end: timeRange.end, valuationCurrency }}
        onApplyBQL={applyAgentBQL}
        onNavigate={(path) => { void pushPreloadedRoute(path); }}
        onChanged={() => load(true)}
        showToast={showToast}
      />}
      </div>
      </PullToRefreshSurface>

      {entryOpen && <Suspense fallback={null}><LazyEntryModal onClose={() => setEntryOpen(false)}><LazyEntryPanel nl={nl} setNl={setNl} onParse={parseNl} manual={manual} setManual={setManual} onPreviewManual={previewManualEntry} previews={previews} onRemovePreview={removePreview} onAppendPreviews={guardedAppendPreviews} parseStatus={parseStatus} parseMessage={parseMessage} appendStatus={appendStatus} expenseAccounts={expenseAccounts} incomeAccounts={incomeAccounts} paymentAccounts={paymentAccounts} accountLabels={accountLabelMap} /></LazyEntryModal></Suspense>}
      <AlertDialog open={Boolean(pendingConflict)} onOpenChange={(open) => !open && setConflictOperationId(null)}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>{t("ledgerApp.conflictTitle")}</AlertDialogTitle>
            <AlertDialogDescription>
              {t("ledgerApp.conflictDescription")}
            </AlertDialogDescription>
          </AlertDialogHeader>
          {pendingConflict && <p className="rounded-lg bg-tag px-3 py-2 text-sm text-warm">
            {pendingConflict.kind === "append" ? t("ledgerApp.conflictAppend") : pendingConflict.kind === "update-transaction" ? t("ledgerApp.conflictUpdate", { source: `${pendingConflict.source.file}:${pendingConflict.source.line}` }) : t("ledgerApp.conflictDelete", { source: `${pendingConflict.source.file}:${pendingConflict.source.line}` })}
          </p>}
          <AlertDialogFooter>
            <AlertDialogCancel>{t("ledgerApp.keepLocalChange")}</AlertDialogCancel>
            <AlertDialogAction className="bg-destructive text-white hover:bg-destructive/90" onClick={() => {
              if (!pendingConflict) return;
              discardPendingOperation(pendingConflict.id);
              setConflictOperationId(null);
              showToast("info", t("ledgerApp.discardedLocalChange"));
            }}>{t("ledgerApp.discardLocalChange")}</AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </AppShell>
  );
}

function PullRefreshIndicator({ state, distance, refreshing }: { state: "idle" | "pull" | "release" | "refreshing"; distance: number; refreshing: boolean }) {
  const { t } = useTranslation();
  if (state === "idle" && !refreshing) return null;
  const label = refreshing || state === "refreshing" ? t("ledgerApp.refreshingNow") : state === "release" ? t("ledgerApp.releaseToRefresh") : t("ledgerApp.pullToRefresh");
  const top = Math.max(12, Math.min(76, distance));
  return <div className="pointer-events-none fixed left-1/2 z-50 -translate-x-1/2 rounded-full border border-line bg-panel/95 px-3 py-1.5 text-xs text-olive shadow-sm backdrop-blur" style={{ top: `calc(${top}px + env(safe-area-inset-top))` }}><RefreshCw className={`mr-1 inline h-3.5 w-3.5 text-brand ${refreshing || state === "refreshing" ? "animate-spin" : ""}`} />{label}</div>;
}

// PullToRefreshSurface owns the pull-gesture state (pullDistance, start Y,
// refreshingByGesture) so that every touchmove during a pull re-renders only
// this wrapper and the indicator, never the whole LedgerApp tree or the page
// content. The children element stays referentially stable across gesture
// updates, so React does not re-render it while the user is pulling.
function PullToRefreshSurface({ refresh, disabled, children }: { refresh: () => void | Promise<void>; disabled: boolean; children: ReactNode }) {
  const { handleTouchStart, handleTouchMove, handleTouchEnd, pullDistance, pullState } = usePullToRefresh(refresh, disabled);
  return <>
    <PullRefreshIndicator state={pullState} distance={pullDistance} refreshing={disabled} />
    <div
      className={`app-page-transition app-pull-surface min-w-0 max-w-full [overflow-x:clip] ${pullDistance > 0 ? "app-pull-surface-active" : ""}`}
      style={pullDistance > 0 ? { transform: `translate3d(0, ${Math.min(34, pullDistance * 0.28)}px, 0)` } : undefined}
      onTouchStart={handleTouchStart}
      onTouchMove={handleTouchMove}
      onTouchEnd={handleTouchEnd}
      onTouchCancel={handleTouchEnd}
    >
      {children}
    </div>
  </>;
}

function TransactionQuickViews({ views, onSelect }: { views: typeof TRANSACTION_QUICK_VIEWS; onSelect: (view: (typeof TRANSACTION_QUICK_VIEWS)[number]) => void }) {
  const { t } = useTranslation();
  return (
    <section className="hidden min-h-12 items-center justify-between gap-3 border-b border-line bg-tag px-3 py-2 lg:flex md:px-4">
      <div>
        <div className="text-xs font-medium text-ink">{t("ledgerApp.commonViews")}</div>
        <div className="mt-0.5 text-[10px] text-stone">{t("ledgerApp.commonViewsHint")}</div>
      </div>
      <div className="flex flex-wrap justify-end gap-2">
        {views.map((view) => (
          <button key={view.id} type="button" className="h-7 rounded-md border border-line bg-panel px-2.5 text-xs text-warm hover:bg-tag" onClick={() => onSelect(view)} title={t(view.labelDetailKey)}>
            {t(view.labelKey)}
          </button>
        ))}
      </div>
    </section>
  );
}

function pageHeader(page: LedgerPage, range: TimeRange, t: (key: string, options?: Record<string, unknown>) => string) {
  const label = formatTimeRangeLabel(range);
  const isMonthScoped = page !== "agent" && page !== "accounts" && page !== "settings" && page !== "imports" && page !== "editor" && page !== "currencies" && page !== "investments" && page !== "query";
  const headers: Record<LedgerPage, { eyebrow: string; title: string }> = {
    agent: { eyebrow: "ledger agent", title: t("ledgerApp.pageAgent") },
    home: { eyebrow: "financial overview", title: t("ledgerApp.pageHome") },
    dashboard: { eyebrow: "income and spending analysis", title: t("ledgerApp.pageDashboard", { label }) },
    query: { eyebrow: "ledger query", title: t("ledgerApp.pageQuery") },
    transactions: { eyebrow: "transactions", title: t("ledgerApp.pageTransactions", { label }) },
    imports: { eyebrow: "statement import", title: t("ledgerApp.pageImports") },
    editor: { eyebrow: "ledger editor", title: t("ledgerApp.pageEditor") },
    reconcile: { eyebrow: "reconcile period", title: t("ledgerApp.pageReconcile", { label }) },
    accounts: { eyebrow: "account book", title: t("ledgerApp.pageAccounts") },
    "net-worth": { eyebrow: "balance sheet", title: t("ledgerApp.pageNetWorth", { label }) },
    investments: { eyebrow: "securities", title: t("ledgerApp.pageInvestments") },
    "income-statement": { eyebrow: "income statement", title: t("ledgerApp.pageIncomeStatement", { label }) },
    currencies: { eyebrow: "currencies and fx", title: t("ledgerApp.pageCurrencies") },
    settings: { eyebrow: "preferences", title: t("ledgerApp.pageSettings") },
  };
  return { ...headers[page], monthScoped: isMonthScoped };
}
