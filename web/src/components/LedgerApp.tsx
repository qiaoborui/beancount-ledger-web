"use client";

import { usePathname } from "next/navigation";
import { useState } from "react";
import { RefreshCw } from "lucide-react";
import { AppShell } from "./AppShell";
import { makeTimeRange, navigateTimeRange, formatTimeRangeLabel } from "@/lib/timeRange";
import type { TimeRange, TimePreset } from "@/lib/timeRange";
import { useClientPathname } from "./ledger/hooks/useClientPathname";
import { useEntryActions } from "./ledger/hooks/useEntryActions";
import { useGitStatus } from "./ledger/hooks/useGitStatus";
import { useLedgerAuth } from "./ledger/hooks/useLedgerAuth";
import { useLedgerData } from "./ledger/hooks/useLedgerData";
import { useLedgerDerivedData } from "./ledger/hooks/useLedgerDerivedData";
import { useLedgerLock } from "./ledger/hooks/useLedgerLock";
import { useLedgerMutations } from "./ledger/hooks/useLedgerMutations";
import { usePrivacySettings } from "./ledger/hooks/usePrivacySettings";
import { usePullToRefresh } from "./ledger/hooks/usePullToRefresh";
import { useToast } from "./ledger/hooks/useToast";
import { AppSkeleton, LoginScreen, PasskeyBanner, UnlockScreen } from "./ledger/AuthScreens";
import { AiBookkeepingChat } from "./ledger/AiBookkeepingChat";
import { EntryModal, EntryPanel } from "./ledger/EntryModal";
import { GitSaveModal } from "./ledger/GitSaveModal";
import { HomePage } from "./ledger/HomePage";
import { IncomeStatementPage } from "./ledger/IncomeStatementPage";
import { Toast } from "./ledger/shared";
import { AccountManager, BalanceAssertionForm, BalanceGrid, BudgetPanel } from "./ledger/AccountPanels";
import { AccountDetailPage } from "./ledger/AccountDetailPage";
import { NetWorthPage } from "./ledger/NetWorthPage";
import { ReconcilePage } from "./ledger/ReconcilePage";
import { SettingsPage } from "./ledger/SettingsPage";
import { TransactionList } from "./ledger/TransactionList";
import type { LedgerPage } from "./ledger/types";

function pageFromPathname(pathname: string): LedgerPage {
  if (pathname.startsWith("/net-worth")) return "net-worth";
  if (pathname.startsWith("/transactions")) return "transactions";
  if (pathname.startsWith("/budgets")) return "budgets";
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

export function LedgerApp({ page: pageProp }: { page?: LedgerPage }) {
  const initialPathname = usePathname();
  const pathname = useClientPathname(initialPathname);
  const page = pageProp ?? pageFromPathname(pathname);
  const [authed, setAuthed] = useState<boolean | null>(() => typeof window !== "undefined" && sessionStorage.getItem("ledger_authed") === "1" ? true : null);
  const [password, setPassword] = useState("");
  const [timeRange, setTimeRange] = useState<TimeRange>(() => makeTimeRange("month"));
  const [customStart, setCustomStart] = useState(timeRange.start);
  const [customEnd, setCustomEnd] = useState(timeRange.end);
  const { toast, setToast, showToast } = useToast();
  const { gitDirty, changedFileCount, gitChanges, gitStatusLoading, gitCommitting, refreshGitStatus, gitCommit } = useGitStatus(showToast);
  const {
    privacySettings,
    updatePrivacySetting,
    allBalancesVisible,
    setAllBalancesVisible,
    netWorthVisible,
    setNetWorthVisible,
    incomeStatementVisible,
    setIncomeStatementVisible,
    visibleAccountMap,
    setVisibleAccountMap,
  } = usePrivacySettings();
  const [txnCategoryQuery, setTxnCategoryQuery] = useState("");
  const [txnMetadataQuery, setTxnMetadataQuery] = useState("");
  const [txnSearchQuery, setTxnSearchQuery] = useState("");
  const [categoryMatchMode, setCategoryMatchMode] = useState<"exact" | "prefix">("prefix");
  const [txnViewMode, setTxnViewMode] = useState<"compact" | "full">("compact");
  const [gitSaveOpen, setGitSaveOpen] = useState(false);
  const [passkeyRegistered, setPasskeyRegistered] = useState<boolean | null>(null);
  const hasPasskey = passkeyRegistered === true;
  const passkeyStatusLoaded = passkeyRegistered !== null;
  const { unlocked, setUnlocked } = useLedgerLock({ passkeyRegistered: hasPasskey, authed });
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
    loadingFresh,
    refreshing,
    lastSyncedAt,
    load,
    refreshLedger,
  } = useLedgerData({
    timeRange,
    unlocked,
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

  const { nl, setNl, previews, parseStatus, parseMessage, appendStatus, entryOpen, setEntryOpen, manual, setManual, parseNl, previewManualEntry, removePreview, appendPreviews, appendEntry } = useEntryActions({ load, refreshGitStatus, showToast });
  const { assertion, setAssertion, appendAssertion, updateTransaction, deleteTransaction, reverseTransaction, reconcileAccount } = useLedgerMutations({ appendEntry, load, refreshGitStatus, showToast });
  const { chart, accountLabelMap, balanceAccounts, expenseAccounts, incomeAccounts, paymentAccounts, visibleBalances, netWorthChart } = useLedgerDerivedData({ summary, accounts, balances, netWorthRows, page });
  const { handleTouchStart, handleTouchEnd } = usePullToRefresh(refreshLedger);

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

  if (authed === null) return <AppSkeleton />;
  if (!authed) return <LoginScreen password={password} setPassword={setPassword} passkeyRegistered={hasPasskey} toastText={toast?.text} onLogin={login} onPasskeyLogin={loginWithPasskey} />;

  if (hasPasskey && !unlocked) return <><Toast toast={toast} /><UnlockScreen message={toast?.kind === "error" ? toast.text : ""} onUnlock={loginWithPasskey} /></>;

  const header = pageHeader(page, timeRange);
  const canNavigate = timeRange.preset !== "all" && timeRange.preset !== "custom";

  async function openGitSave() {
    setGitSaveOpen(true);
    await refreshGitStatus();
  }

  async function commitGitChanges(message: string) {
    await gitCommit(message);
    setGitSaveOpen(false);
  }

  return (
    <AppShell pathname={pathname} onGit={openGitSave} onAdd={() => setEntryOpen(true)} gitDirty={gitDirty} changedFileCount={changedFileCount}>
      <Toast toast={toast} />
      <GitSaveModal open={gitSaveOpen} changes={gitChanges} changedFileCount={changedFileCount} loading={gitStatusLoading} committing={gitCommitting} onRefresh={refreshGitStatus} onClose={() => setGitSaveOpen(false)} onCommit={commitGitChanges} />
      {passkeyStatusLoaded && !hasPasskey && <PasskeyBanner onRegister={registerPasskey} />}

      {/* ── 时间范围选择器 ── */}
      <div className="mb-6" onTouchStart={handleTouchStart} onTouchEnd={handleTouchEnd}>
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
            <div className="mt-1 text-xs text-stone">{lastSyncedAt ? `本地优先 · ${new Date(lastSyncedAt).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })} 已同步` : "下拉可刷新"}</div>
          </div>
          <div className="flex items-center gap-2">
            <button className="rounded-xl border border-line bg-panel px-3 py-2 text-warm" onClick={refreshLedger} disabled={refreshing || loadingFresh}>
              <RefreshCw className={`inline h-4 w-4 text-brand ${refreshing || loadingFresh ? "animate-spin" : ""}`} /> <span className="hidden sm:inline">刷新</span>
            </button>
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
        <div className="mt-3 flex flex-wrap items-center gap-2">
          <div className="flex rounded-xl border border-line overflow-hidden">
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
              <span className="text-stone text-sm">~</span>
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
      </div>

      {page === "home" && <HomePage summary={summary} chart={chart} privacySettings={privacySettings} onPrivacyChange={updatePrivacySetting} />}

      {page === "net-worth" && <NetWorthPage rows={netWorthChart} balances={balances} accounts={accounts} incomeStatement={incomeStatement} visible={netWorthVisible} onToggleVisible={() => setNetWorthVisible((value) => !value)} />}
      {page === "income-statement" && <IncomeStatementPage income={incomeStatement?.income ?? []} expense={incomeStatement?.expense ?? []} totalIncome={incomeStatement?.totalIncome ?? 0} totalExpense={incomeStatement?.totalExpense ?? 0} netIncome={incomeStatement?.netIncome ?? 0} visible={incomeStatementVisible} onToggleVisible={() => setIncomeStatementVisible((value) => !value)} onSelectCategory={(account) => { setTxnCategoryQuery(account); window.history.pushState(null, "", "/transactions"); }} />}
      {page === "accounts" && (() => { const detailAccount = accountFromPathname(pathname); if (detailAccount) return <AccountDetailPage account={detailAccount} />; return <><BalanceGrid rows={visibleBalances} full allVisible={allBalancesVisible} visibleAccountMap={visibleAccountMap} onToggleAll={() => setAllBalancesVisible((value) => !value)} onToggleAccount={(account) => setVisibleAccountMap((current) => ({ ...current, [account]: !(current[account] ?? allBalancesVisible) }))} statuses={accountStatuses} /><AccountManager accounts={accounts} balances={balances} onAdded={() => load(true)} /><BalanceAssertionForm assertion={assertion} setAssertion={setAssertion} onSubmit={appendAssertion} accounts={balanceAccounts} /></>; })()}
      {page === "settings" && <SettingsPage settings={privacySettings} onChange={updatePrivacySetting} />}
      {page === "budgets" && <BudgetPanel rows={budgetRows} full />}
      {page === "reconcile" && <ReconcilePage timeRange={timeRange} rows={reconciliationRows} onSubmit={reconcileAccount} statuses={accountStatuses} />}
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
          onUpdate={updateTransaction}
          onDelete={deleteTransaction}
          onReverse={reverseTransaction}
        />
      )}

      <AiBookkeepingChat load={load} refreshGitStatus={refreshGitStatus} showToast={showToast} />

      {entryOpen && <EntryModal onClose={() => setEntryOpen(false)}><EntryPanel nl={nl} setNl={setNl} onParse={parseNl} manual={manual} setManual={setManual} onPreviewManual={previewManualEntry} previews={previews} onRemovePreview={removePreview} onAppendPreviews={appendPreviews} parseStatus={parseStatus} parseMessage={parseMessage} appendStatus={appendStatus} expenseAccounts={expenseAccounts} incomeAccounts={incomeAccounts} paymentAccounts={paymentAccounts} accountLabels={accountLabelMap} /></EntryModal>}
    </AppShell>
  );
}

function pageHeader(page: LedgerPage, range: TimeRange) {
  const label = formatTimeRangeLabel(range);
  const isMonthScoped = page !== "accounts" && page !== "net-worth" && page !== "settings";
  const headers: Record<LedgerPage, { eyebrow: string; title: string }> = {
    home: { eyebrow: "monthly overview", title: `${label} 总览` },
    transactions: { eyebrow: "transactions", title: `${label} 流水` },
    budgets: { eyebrow: "budget period", title: `${label} 预算` },
    reconcile: { eyebrow: "reconcile period", title: `${label} 对账` },
    accounts: { eyebrow: "account book", title: "账户与余额" },
    "net-worth": { eyebrow: "net worth", title: "净资产" },
    "income-statement": { eyebrow: "income statement", title: `${label} 损益表` },
    settings: { eyebrow: "preferences", title: "设置" },
  };
  return { ...headers[page], monthScoped: isMonthScoped };
}
