"use client";

import dynamic from "next/dynamic";
import { usePathname, useRouter, useSearchParams } from "next/navigation";
import { useCallback, useEffect, useState, useTransition } from "react";
import { RefreshCw, WifiOff } from "lucide-react";
import { AppShell } from "./AppShell";
import { makeTimeRange, navigateTimeRange, formatTimeRangeLabel } from "@/lib/timeRange";
import type { TimeRange, TimePreset } from "@/lib/timeRange";
import { defaultMobileTabHrefs, readMobileTabHrefs, writeMobileTabHrefs } from "./ledger/storage";
import { useEntryActions } from "./ledger/hooks/useEntryActions";
import { useGitStatus } from "./ledger/hooks/useGitStatus";
import { useLedgerAuth } from "./ledger/hooks/useLedgerAuth";
import { useLedgerData } from "./ledger/hooks/useLedgerData";
import { useLedgerDerivedData } from "./ledger/hooks/useLedgerDerivedData";
import { useLedgerLock } from "./ledger/hooks/useLedgerLock";
import { useLedgerMutations } from "./ledger/hooks/useLedgerMutations";
import { usePrivacySettings } from "./ledger/hooks/usePrivacySettings";
import { useNetworkStatus } from "./ledger/hooks/useNetworkStatus";
import { usePullToRefresh } from "./ledger/hooks/usePullToRefresh";
import { usePendingLedgerWrites } from "./ledger/hooks/usePendingLedgerWrites";
import { useRouteScrollMemory } from "./ledger/hooks/useRouteScrollMemory";
import { useSwipeBack } from "./ledger/hooks/useSwipeBack";
import { useThemeMode } from "./ledger/hooks/useThemeMode";
import { useToast } from "./ledger/hooks/useToast";
import { AppSkeleton, LoginScreen, PasskeyBanner, SensitiveUnlockPanel } from "./ledger/AuthScreens";
import { AiBookkeepingChat } from "./ledger/AiBookkeepingChat";
import { EntryModal, EntryPanel } from "./ledger/EntryModal";
import { GitSaveModal } from "./ledger/GitSaveModal";
import { HomePage } from "./ledger/HomePage";
import { QuickActionsSheet } from "./ledger/QuickActionsSheet";
import { ImportPage } from "./ledger/ImportPage";
import { Toast } from "./ledger/shared";
import { AccountManager, BalanceAssertionForm, BalanceGrid, BudgetPanel, CreditCardPanel } from "./ledger/AccountPanels";
import { AccountDetailPage } from "./ledger/AccountDetailPage";

import { ReconcilePage } from "./ledger/ReconcilePage";
import { SettingsPage } from "./ledger/SettingsPage";
import { TransactionList } from "./ledger/TransactionList";
import { haptic } from "./ledger/haptics";
import type { LedgerNavHref, LedgerPage } from "./ledger/types";

const NetWorthPage = dynamic(() => import("./ledger/NetWorthPage").then((mod) => mod.NetWorthPage), {
  loading: () => <section className="card p-6 text-sm text-stone">正在准备净资产图表…</section>,
});

const IncomeStatementPage = dynamic(() => import("./ledger/IncomeStatementPage").then((mod) => mod.IncomeStatementPage), {
  loading: () => <section className="card p-6 text-sm text-stone">正在准备损益分析…</section>,
});

function pageFromPathname(pathname: string): LedgerPage {
  if (pathname.startsWith("/net-worth")) return "net-worth";
  if (pathname.startsWith("/transactions")) return "transactions";
  if (pathname.startsWith("/budgets")) return "budgets";
  if (pathname.startsWith("/imports")) return "imports";
  if (pathname.startsWith("/reconcile")) return "reconcile";
  if (pathname.startsWith("/settings")) return "settings";
  if (pathname.startsWith("/income-statement")) return "income-statement";
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
];

function readSessionAuthed(): boolean | null {
  if (typeof window === "undefined") return null;
  return sessionStorage.getItem("ledger_authed") === "1" ? true : null;
}

export function LedgerApp({ page: pageProp }: { page?: LedgerPage }) {
  const router = useRouter();
  const pathname = usePathname();
  const searchParams = useSearchParams();
  const [isRoutePending, startRouteTransition] = useTransition();
  const page = pageProp ?? pageFromPathname(pathname);
  const [authed, setAuthed] = useState<boolean | null>(() => readSessionAuthed());
  const [password, setPassword] = useState("");
  const [timeRange, setTimeRange] = useState<TimeRange>(() => makeTimeRange("month"));
  const [customStart, setCustomStart] = useState(timeRange.start);
  const [customEnd, setCustomEnd] = useState(timeRange.end);
  const { toast, setToast, showToast } = useToast();
  const online = useNetworkStatus();
  const { scrollToTop } = useRouteScrollMemory(pathname);
  const { themeMode, resolvedTheme, setThemeMode } = useThemeMode();
  const { gitDirty, changedFileCount, gitChanges, gitStatusLoading, gitCommitting, refreshGitStatus, gitCommit } = useGitStatus(showToast);
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
  const initialCategoryQuery = searchParams.get("category") ?? "";
  const initialMetadataQuery = searchParams.get("metadata") ?? "";
  const initialSearchQuery = searchParams.get("q") ?? "";
  const initialMatchMode = searchParams.get("mode") === "exact" ? "exact" : "prefix";
  const [txnCategoryQuery, setTxnCategoryQuery] = useState(initialCategoryQuery);
  const [txnMetadataQuery, setTxnMetadataQuery] = useState(initialMetadataQuery);
  const [txnSearchQuery, setTxnSearchQuery] = useState(initialSearchQuery);
  const [categoryMatchMode, setCategoryMatchMode] = useState<"exact" | "prefix">(initialMatchMode);
  const [txnViewMode, setTxnViewMode] = useState<"compact" | "full">("compact");
  const [gitSaveOpen, setGitSaveOpen] = useState(false);
  const [quickActionsOpen, setQuickActionsOpen] = useState(false);
  const [aiOpenSignal, setAiOpenSignal] = useState(0);
  const [creditSummaryVisible, setCreditSummaryVisible] = useState(true);
  const [passkeyRegistered, setPasskeyRegistered] = useState<boolean | null>(null);
  const [mobileTabHrefs, setMobileTabHrefs] = useState<LedgerNavHref[]>(defaultMobileTabHrefs);
  const hasPasskey = passkeyRegistered === true;
  const passkeyStatusLoaded = passkeyRegistered !== null;
  const { unlocked, setUnlocked } = useLedgerLock({ passkeyRegistered: hasPasskey, authed });
  useEffect(() => {
    if (unlocked) revealAllAmounts();
  }, [revealAllAmounts, unlocked]);

  const handleSensitiveLocked = useCallback(() => {
    sessionStorage.removeItem("ledger_unlocked");
    sessionStorage.setItem("ledger_locked_at", String(Date.now()));
    setUnlocked(false);
  }, [setUnlocked]);
  const {
    summary,
    balances,
    txns,
    budgetRows,
    netWorthRows,
    reconciliationRows,
    accounts,
    incomeStatement,
    accountStatuses,
    monthEndNetWorthRows,
    netWorthWindows,
    creditCards,
    loadingFresh,
    refreshing,
    lastSyncedAt,
    load,
    refreshLedger,
  } = useLedgerData({
    timeRange,
    unlocked,
    onSensitiveLocked: handleSensitiveLocked,
    onAuthChange: setAuthed,
    onPasskeyRegistered: setPasskeyRegistered,
    onGitStatusRefresh: refreshGitStatus,
    showToast,
  });

  const { login, loginWithPasskey, registerPasskey } = useLedgerAuth({
    password,
    setPassword,
    setAuthed,
    setUnlocked,
    setPasskeyRegistered,
    load,
    showToast,
    clearToast: () => setToast(null),
  });

  const { pendingWriteCount, pendingWriteSummary, enqueuePendingWrites, syncPendingWrites, syncingPendingWrites } = usePendingLedgerWrites({ load, refreshGitStatus, showToast });
  const { nl, setNl, previews, parseStatus, parseMessage, appendStatus, entryOpen, setEntryOpen, manual, setManual, parseNl, previewManualEntry, removePreview, appendPreviews, appendEntry } = useEntryActions({ load, refreshGitStatus, showToast, enqueuePendingWrites });
  const { assertion, setAssertion, appendAssertion, updateTransaction, deleteTransaction, reverseTransaction, reconcileAccount } = useLedgerMutations({ appendEntry, load, refreshGitStatus, showToast, enqueuePendingWrites });
  const { accountLabelMap, balanceAccounts, expenseAccounts, incomeAccounts, paymentAccounts, visibleBalances, netWorthChart } = useLedgerDerivedData({ summary, accounts, balances, netWorthRows, page });
  const { handleTouchStart, handleTouchMove, handleTouchEnd, pullDistance, pullState } = usePullToRefresh(refreshLedger, refreshing || loadingFresh);
  const detailAccount = page === "accounts" ? accountFromPathname(pathname) : null;
  useSwipeBack({ enabled: Boolean(detailAccount), onBack: () => router.push("/accounts") });

  function setPreset(preset: TimePreset) {
    if (preset === "custom") {
      const range: TimeRange = { start: customStart, end: customEnd, preset: "custom" };
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
  }, [categoryMatchMode, page, pathname, router, searchKey, searchParams, txnCategoryQuery, txnMetadataQuery, txnSearchQuery]);

  useEffect(() => {
    if (!authed || !shortcutAction) return;
    haptic(8);
    if (shortcutAction === "quick-entry" || shortcutAction === "new-entry") setEntryOpen(true);
    if (shortcutAction === "ai-entry") setAiOpenSignal((value) => value + 1);
    if (shortcutAction === "quick-actions") setQuickActionsOpen(true);
    if (shortcutAction === "sync-pending") void syncPendingWrites();

    const params = new URLSearchParams(searchParams.toString());
    params.delete("action");
    const query = params.toString();
    router.replace(query ? `${pathname}?${query}` : pathname, { scroll: false });
  }, [authed, pathname, router, searchParams, shortcutAction, syncPendingWrites]);

  function openCategoryTransactions(account: string, mode: "exact" | "prefix" = "prefix") {
    setTxnCategoryQuery(account);
    setCategoryMatchMode(mode);
    const params = new URLSearchParams();
    params.set("category", account);
    if (mode === "exact") params.set("mode", "exact");
    startRouteTransition(() => {
      router.push(`/transactions?${params.toString()}`);
    });
  }

  if (authed === null) return <AppSkeleton />;
  if (!authed) return <LoginScreen password={password} setPassword={setPassword} passkeyRegistered={hasPasskey} toastText={toast?.text} onLogin={login} onPasskeyLogin={loginWithPasskey} />;

  const unlockedPrivacySettings = unlocked ? { ...privacySettings, showHomeSummaryAmounts: true } : privacySettings;
  const sensitiveMessage = toast?.kind === "error" ? toast.text : "";
  const requireSensitiveUnlock = (title?: string, description?: string) => (
    <SensitiveUnlockPanel title={title} description={description} message={sensitiveMessage} onUnlock={loginWithPasskey} />
  );
  const header = pageHeader(page, timeRange);
  const canShowTimeControls = header.monthScoped;
  const canNavigate = canShowTimeControls && timeRange.preset !== "all" && timeRange.preset !== "custom";

  async function openGitSave() {
    setGitSaveOpen(true);
    await refreshGitStatus();
  }

  function handleActiveRouteTap() {
    if (window.scrollY > 8) {
      scrollToTop(pathname);
      return;
    }
    void refreshLedger();
  }

  function openManualEntry() {
    setEntryOpen(true);
  }

  function openAiEntry() {
    setAiOpenSignal((value) => value + 1);
  }

  function openImportPage() {
    router.push("/imports");
  }

  function openBalanceAssertion() {
    router.push("/accounts");
    if (!unlocked) void loginWithPasskey();
    window.setTimeout(() => document.getElementById("balance-assertion-form")?.scrollIntoView({ behavior: "smooth", block: "center" }), 180);
  }

  const offlineWriteMessage = "当前离线，写入操作会失败，请联网后再试。";
  const guardOnline = () => {
    if (online) return true;
    showToast("error", offlineWriteMessage);
    return false;
  };

  async function commitGitChanges(message: string) {
    if (!guardOnline()) return;
    await gitCommit(message);
    setGitSaveOpen(false);
  }

  const guardedAppendPreviews = () => { appendPreviews(); };
  const guardedAppendAssertion = () => { appendAssertion(); };
  const guardedUpdateTransaction = (...args: Parameters<typeof updateTransaction>) => { if (guardOnline()) updateTransaction(...args); };
  const guardedDeleteTransaction = (...args: Parameters<typeof deleteTransaction>) => { if (guardOnline()) deleteTransaction(...args); };
  const guardedReverseTransaction = (...args: Parameters<typeof reverseTransaction>) => { if (guardOnline()) reverseTransaction(...args); };
  const guardedReconcileAccount = (...args: Parameters<typeof reconcileAccount>) => { if (guardOnline()) reconcileAccount(...args); };
  const guardedImportRefresh = () => {
    if (!guardOnline()) return;
    load(true);
    refreshGitStatus();
  };

  return (
    <AppShell
      pathname={pathname}
      onGit={openGitSave}
      onAdd={() => setQuickActionsOpen(true)}
      gitDirty={gitDirty}
      changedFileCount={changedFileCount}
      routePending={isRoutePending}
      sensitiveUnlocked={unlocked}
      passkeyEnabled={hasPasskey}
      onUnlockSensitive={loginWithPasskey}
      onActiveRouteTap={handleActiveRouteTap}
    >
      <Toast toast={toast} />
      <GitSaveModal open={gitSaveOpen} changes={gitChanges} changedFileCount={changedFileCount} loading={gitStatusLoading} committing={gitCommitting} onRefresh={refreshGitStatus} onClose={() => setGitSaveOpen(false)} onCommit={commitGitChanges} />
      <QuickActionsSheet open={quickActionsOpen} gitDirty={gitDirty} changedFileCount={changedFileCount} refreshing={refreshing || loadingFresh} pendingWriteCount={pendingWriteCount} syncingPendingWrites={syncingPendingWrites} onClose={() => setQuickActionsOpen(false)} onManualEntry={openManualEntry} onAiEntry={openAiEntry} onImport={openImportPage} onBalanceAssertion={openBalanceAssertion} onGitSave={openGitSave} onRefresh={refreshLedger} onSyncPendingWrites={syncPendingWrites} />
      <PullRefreshIndicator state={pullState} distance={pullDistance} refreshing={refreshing} />
      {passkeyStatusLoaded && !hasPasskey && <PasskeyBanner onRegister={registerPasskey} />}

      <div
        key={pathname}
        className={`app-page-transition app-pull-surface ${pullDistance > 0 ? "app-pull-surface-active" : ""}`}
        style={pullDistance > 0 ? { transform: `translate3d(0, ${Math.min(34, pullDistance * 0.28)}px, 0)` } : undefined}
        onTouchStart={handleTouchStart}
        onTouchMove={handleTouchMove}
        onTouchEnd={handleTouchEnd}
        onTouchCancel={handleTouchEnd}
      >
      {/* ── 时间范围选择器 ── */}
      <div className="mb-6">
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
              {(refreshing || loadingFresh) && <span className="text-brand">后台同步中…</span>}
              {unlocked && <button type="button" className="inline-flex items-center gap-1 rounded-full bg-brand/10 px-2 py-0.5 text-brand" onClick={handleSensitiveLocked}>敏感数据已解锁 · 重新隐藏</button>}
            </div>
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
          <div className="mt-3 flex flex-wrap items-center gap-2">
            <div className="flex overflow-hidden rounded-xl border border-line">
              {TIME_PRESETS.map((p) => (
                <button
                  key={p.key}
                  className={`px-3 py-1.5 text-sm transition-colors ${timeRange.preset === p.key ? "bg-brand text-paper" : "bg-panel text-warm hover:bg-tag"}`}
                  onClick={() => setPreset(p.key)}
                >
                  {p.label}
                </button>
              ))}
            </div>

            {/* 自定义范围：date input */}
            {timeRange.preset === "custom" && (
              <div className="flex items-center gap-2">
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

      {page === "home" && <HomePage summary={summary} privacySettings={unlockedPrivacySettings} sensitiveUnlocked={unlocked} creditCards={creditCards} expenseAnalytics={incomeStatement?.expenseAnalytics ?? []} budgetRows={budgetRows} accountStatuses={accountStatuses} onPrivacyChange={updatePrivacySetting} onSelectCategory={openCategoryTransactions} />}

      {page === "net-worth" && (unlocked ? <NetWorthPage rows={netWorthChart} monthEndRows={monthEndNetWorthRows} windows={netWorthWindows} creditCards={creditCards} accountStatuses={accountStatuses} balances={balances} accounts={accounts} incomeStatement={incomeStatement} visible={netWorthVisible} onToggleVisible={() => setNetWorthVisible((value) => !value)} /> : requireSensitiveUnlock("净资产已隐藏", "此页会展示净资产、账户余额和资产配置，需要使用 Face ID / Passkey 后查看。"))}
      {page === "income-statement" && <IncomeStatementPage income={incomeStatement?.income ?? []} expense={incomeStatement?.expense ?? []} expenseAnalytics={incomeStatement?.expenseAnalytics ?? []} topPayees={incomeStatement?.topPayees ?? []} topPaymentAccounts={incomeStatement?.topPaymentAccounts ?? []} creditCards={creditCards} totalIncome={incomeStatement?.totalIncome ?? 0} totalExpense={incomeStatement?.totalExpense ?? 0} netIncome={incomeStatement?.netIncome ?? 0} visible={incomeStatementVisible} sensitiveUnlocked={unlocked} onToggleVisible={() => setIncomeStatementVisible((value) => !value)} onUnlockSensitive={loginWithPasskey} onSelectCategory={openCategoryTransactions} />}
      {page === "accounts" && (() => { const detailAccount = accountFromPathname(pathname); if (detailAccount) return unlocked ? <AccountDetailPage account={detailAccount} onSensitiveLocked={handleSensitiveLocked} /> : requireSensitiveUnlock("账户明细已隐藏", "单个账户详情包含当前余额和账户级流水，需要使用 Face ID / Passkey 后查看。"); return <>{unlocked ? <><BalanceGrid rows={visibleBalances} full allVisible={allBalancesVisible} visibleAccountMap={visibleAccountMap} onToggleAll={() => setAllBalancesVisible((value) => !value)} onToggleAccount={(account) => setVisibleAccountMap((current) => ({ ...current, [account]: !(current[account] ?? allBalancesVisible) }))} statuses={accountStatuses} /><CreditCardPanel cards={creditCards} statuses={accountStatuses} visible={allBalancesVisible} visibleAccountMap={visibleAccountMap} summaryVisible={creditSummaryVisible} onToggleSummaryVisible={() => setCreditSummaryVisible((value) => !value)} onToggleAccount={(account) => setVisibleAccountMap((current) => ({ ...current, [account]: !(current[account] ?? allBalancesVisible) }))} /><BalanceAssertionForm assertion={assertion} setAssertion={setAssertion} onSubmit={guardedAppendAssertion} accounts={balanceAccounts} /></> : requireSensitiveUnlock("账户余额已隐藏", "账户定义可以直接管理；当前余额、余额断言和对账数据需要解锁后查看。")}<AccountManager accounts={accounts} balances={balances} onAdded={() => load(true)} /></>; })()}
      {page === "settings" && <SettingsPage settings={privacySettings} onChange={updatePrivacySetting} themeMode={themeMode} resolvedTheme={resolvedTheme} onThemeModeChange={setThemeMode} mobileTabHrefs={mobileTabHrefs} onMobileTabHrefsChange={updateMobileTabHrefs} />}
      {page === "budgets" && <BudgetPanel rows={budgetRows} full />}
      {page === "imports" && <ImportPage onImported={guardedImportRefresh} />}
      {page === "reconcile" && (unlocked ? <ReconcilePage timeRange={timeRange} rows={reconciliationRows} onSubmit={guardedReconcileAccount} statuses={accountStatuses} /> : requireSensitiveUnlock("对账数据已隐藏", "对账会展示账户余额、余额断言和差额调整，需要使用 Face ID / Passkey 后查看。"))}
      {(page === "home" || page === "transactions") && (
        <TransactionList
          txns={txns}
          accounts={accounts}
          searchable={page === "transactions"}
          categoryQuery={txnCategoryQuery}
          setCategoryQuery={setTxnCategoryQuery}
          metadataQuery={txnMetadataQuery}
          setMetadataQuery={setTxnMetadataQuery}
          searchQuery={txnSearchQuery}
          setSearchQuery={setTxnSearchQuery}
          matchMode={categoryMatchMode}
          setMatchMode={setCategoryMatchMode}
          viewMode={txnViewMode}
          setViewMode={setTxnViewMode}
          onUpdate={guardedUpdateTransaction}
          onDelete={guardedDeleteTransaction}
          onReverse={guardedReverseTransaction}
        />
      )}
      </div>

      <AiBookkeepingChat load={load} refreshGitStatus={refreshGitStatus} showToast={showToast} openSignal={aiOpenSignal} />

      {entryOpen && <EntryModal onClose={() => setEntryOpen(false)}><EntryPanel nl={nl} setNl={setNl} onParse={parseNl} manual={manual} setManual={setManual} onPreviewManual={previewManualEntry} previews={previews} onRemovePreview={removePreview} onAppendPreviews={guardedAppendPreviews} parseStatus={parseStatus} parseMessage={parseMessage} appendStatus={appendStatus} expenseAccounts={expenseAccounts} incomeAccounts={incomeAccounts} paymentAccounts={paymentAccounts} accountLabels={accountLabelMap} /></EntryModal>}
    </AppShell>
  );
}

function PullRefreshIndicator({ state, distance, refreshing }: { state: "idle" | "pull" | "release" | "refreshing"; distance: number; refreshing: boolean }) {
  if (state === "idle" && !refreshing) return null;
  const label = refreshing || state === "refreshing" ? "正在刷新…" : state === "release" ? "松开刷新" : "下拉刷新";
  const top = Math.max(12, Math.min(76, distance));
  return <div className="pointer-events-none fixed left-1/2 z-50 -translate-x-1/2 rounded-full border border-line bg-panel/95 px-3 py-1.5 text-xs text-olive shadow-sm backdrop-blur" style={{ top: `calc(${top}px + env(safe-area-inset-top))` }}><RefreshCw className={`mr-1 inline h-3.5 w-3.5 text-brand ${refreshing || state === "refreshing" ? "animate-spin" : ""}`} />{label}</div>;
}

function pageHeader(page: LedgerPage, range: TimeRange) {
  const label = formatTimeRangeLabel(range);
  const isMonthScoped = page !== "accounts" && page !== "net-worth" && page !== "settings" && page !== "imports";
  const headers: Record<LedgerPage, { eyebrow: string; title: string }> = {
    home: { eyebrow: "monthly overview", title: `${label} 总览` },
    transactions: { eyebrow: "transactions", title: `${label} 流水` },
    budgets: { eyebrow: "budget period", title: `${label} 预算` },
    imports: { eyebrow: "statement import", title: "账单导入" },
    reconcile: { eyebrow: "reconcile period", title: `${label} 对账` },
    accounts: { eyebrow: "account book", title: "账户与余额" },
    "net-worth": { eyebrow: "net worth", title: "净资产" },
    "income-statement": { eyebrow: "income statement", title: `${label} 损益表` },
    settings: { eyebrow: "preferences", title: "设置" },
  };
  return { ...headers[page], monthScoped: isMonthScoped };
}
